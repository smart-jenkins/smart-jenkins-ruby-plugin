require 'rubygems'
require 'sinatra/base'
require 'jenkins/rack'
require 'erb'
require 'json'
require 'singleton'
require 'jruby/synchronized'
require 'socket'

module SmartJenkins
  def computers
    Java.jenkins.model.Jenkins.instance.computers
  end

  def master
    computers[0]
  end

  def slaves
    computers[1..-1]
  end

  def slave(item)
    Java.jenkins.model.Jenkins.instance.getComputer(item.is_a?(String) ? item : item.name)
  end

  def jobs
    Java.jenkins.model.Jenkins.instance.getAllItems(Java.hudson.model.AbstractProject.java_class)
  end

  def job(item)
    Java.jenkins.model.Jenkins.instance.getItemByFullName(item.is_a?(String) ? item : item.full_name, Java.hudson.model.AbstractProject.java_class)
  end

  module Constants
    # Item types
    ITEM_TYPE_COMPUTER = 'computer'
    ITEM_TYPE_JOB = 'job'

    # Configuration
    ENABLE = 'enable'
    TIME_SLOT = 'time_slot'
    VIEW = 'view'
    JOB_FILTER = 'job_fltr'
    SLAVE_FILTER = 'slave_fltr'
    FONT_SIZE = 'font_size'
    TAB_TYPE = 'tab'

    # Job configuration
    LAST_BLOCKED = 'last_blck'
    LAST_SCHEDULED = 'last_schd'
    NEXT_SCHEDULED = 'next_schd'

    # Computer configuration
    OPERATION = 'op'
    OS = 'os'
    HOST = 'host'
    MAC_ADDRESS = 'mac'
    LAST_BUILD = 'last_bld'

    # Computer operation
    ON = 'ON'
    OFF = 'OFF'

    # Request Parameter Name
    ENABLE_SUFFIX = "_enable"
    SCHEDULE_SUFFIX = "_schedule"

    # Commands
    SHUTDOWN_WINDOWS = '"cmd shutdown -s -t 1".execute()'
    SHUTDOWN_UNIX = '"shutdown -h now".execute()'
  end

  class ItemManager
    include Singleton
    include Constants

    def item_type
      'item'
    end

    def init(items)
      items.each { |item|
        create item
      }
    end

    def config(*item)
      case item.size
      when 0
        Configuration.instance.config(item_type)
      when 1
        Configuration.instance.config(item_type, item[0].is_a?(String) ? item[0] : item[0].name)
      end
    end

    def default_config
      Hash.new
    end

    def create(item)
      config = Configuration.instance.config(item_type, item.is_a?(String) ? item : item.name)
      config.merge! default_config if config.size == 0
    end

    def remove(item)
      Configuration.instance.delete(item_type, item.is_a?(String) ? item : item.name)
    end
  end

  class ComputerManager < ItemManager
    def item_type
      ITEM_TYPE_COMPUTER
    end

    def default_config
      {
        ENABLE => false,
        OPERATION => ON,
        OS => '',
        HOST => '',
        MAC_ADDRESS => ''
      }
    end

    def update_info(slave)
      config = config(slave)
      if slave.online?
        host = slave.host_name
        begin
          addr = Java.java.net.InetAddress.getByName(host)
          ni = Java.java.net.NetworkInterface.getByInetAddress(addr)
          mac = bytes2mac(ni.hardware_address) if ni
        rescue
          p $!
        end
        config[OPERATION] = OFF
        config[OS] = slave.os_description.to_s if slave.respond_to? :os_description
        config[HOST] = host.to_s
        config[MAC_ADDRESS] = mac.to_s
      else
        config[OPERATION] = ON
      end
    end

    private

    def bytes2mac(bytes)
      if bytes && bytes.size == 6
        mac = ''
        bytes.each { |byte|
          mac << sprintf('%02x', byte) << ':'
        }
        mac[0..-2]
      end
    end
  end

  class JobManager < ItemManager
    def item_type
      ITEM_TYPE_JOB
    end

    def default_config
      {
        ENABLE => false,
        LAST_BLOCKED => 0,
        LAST_SCHEDULED => 0,
        NEXT_SCHEDULED => 0
      }
    end

    def events_json(jobs)
      sb = "({'events':["
      jobs.each { |job|
        json = to_event_json(job)
        sb << json << ',' if json && !json.empty?
        json = TimeLine.event_json(job.name)
        sb << json << ',' if json && !json.empty?
      }
      sb[-1] = "" if sb[-1] == ','
      sb << "]})"
    end

    def trigger(job)
      sb = ""
      scm_trigger = job.getTrigger(Java.hudson.triggers.SCMTrigger)
      timer_trigger = job.getTrigger(Java.hudson.triggers.TimerTrigger)
      if scm_trigger
        if timer_trigger
          sb << "SCM&nbsp;&nbsp;&nbsp;: " << scm_trigger.spec
        else
          sb << "SCM : " << scm_trigger.spec
        end
      end
      if timer_trigger
        sb << "<BR>" if scm_trigger
        sb << "Timer : " << timer_trigger.spec
      end
      sb
    end

    def update(job_name, enable_string, schedule_string)
      conf = config(job_name)
      updated = false
      if schedule_string
        if enable_string
          updated = updated || !conf[ENABLE]
          conf[ENABLE] = true
        else
          updated = updated || conf[ENABLE]
          conf[ENABLE] = false
        end
        schedule_updated = false
        if schedule_string && !schedule_string.empty?
          time = Utils.parse_date_string(schedule_string).time
          if time != conf[NEXT_SCHEDULED]
            conf[NEXT_SCHEDULED] = time
            schedule_updated = true
          end
        else
          schedule_updated = (conf[NEXT_SCHEDULED] == -1 ? false : true)
          conf[NEXT_SCHEDULED] = -1
        end
        updated = updated || schedule_updated
      end
      updated
    end

    private

    def to_event_json(job)
      sb = ""
      job.builds.new_builds.each { |run|
        sb << "{'start':'" << Utils.format_date(run.time) << "'"
        sb << ",'end':'" << Utils.format_date(run.time.time + (run.duration < 1000 ? 1000 : run.duration)) << "'"
        sb << ",'title':'" << job.name << "(" << run.display_name << ")'"
        sb << ",'description':'" << run.result.to_s << "'"
        sb << ",'durationEvent':true},"
      }
      sb[-1] = "" unless sb.empty?
      sb
    end
  end

  class Configuration
    include Singleton
    include Constants

    DEFAULT_CONFIG = {
      ENABLE => false,
      TIME_SLOT => '',
      VIEW => nil,
      JOB_FILTER => '',
      SLAVE_FILTER => '',
      FONT_SIZE => 'S',
      TAB_TYPE => 0
    }

    def initialize
      @config_file = Java.jenkins.model.Jenkins.getInstance.root_dir.absolute_path + '/smart-jenkins.config'
      @config = nil
      begin
        if File.exists? @config_file
          @config = JSON.parse(File.read(@config_file))
        end
      rescue
        p $!
      ensure
        @config = Hash[DEFAULT_CONFIG] unless @config
      end
      TimeSlot.instance.set_time_slot(@config[TIME_SLOT], false)
      @config.extend JRuby::Synchronized
    end

    def config(*keys)
      value = @config
      keys.each { |key|
        value[key] = Hash.new unless value[key]
        value = value[key]
      }
      value
    end

    def [](*keys)
      config(*keys[0, keys.size - 1])[keys[-1]]
    end

    def []=(key, value)
      if key.is_a? Array
        config[*key[0, key.size - 1]][key[-1]] = value
      else
        @config[key] = value
      end
    end

    def delete(*keys)
      config[*keys[0, keys.size - 1]].delete keys[-1]
    end

    def save
      File.open(@config_file, "w") { |file|
        file.write @config.to_json
      }
    end
  end

  class TimeSlot
    include Singleton

    START = 0
    END_ = 1
    TIME_ZONE_OFFSET = Java.java.util.TimeZone.getDefault.raw_offset
    MAX_TIME = 24 * 60 * 60 * 1000
    ALL_DAYS_OF_WEEK = 0x007f
    HOUR_IN_MILLISECONDS = 60 * 60 * 1000
    DAY_IN_MILLISECONDS = 24 * HOUR_IN_MILLISECONDS

    def initialize
      @time_slot_string = ''
      @time_slot = Array.new
    end

    def enable(enable)
      if enable
        set_time_slot(@time_slot_string, false)
      else
        @time_slot = null
      end
    end

    def set_time_slot(time_slot_string, check_same)
      return false unless time_slot_string
      trimed_time_slot_string = time_slot_string.gsub(' ', '')
      return false if check_same && trimed_time_slot_string == @time_slot_string
      @time_slot_string = trimed_time_slot_string
      @time_slot = Array.new
      unless @time_slot_string.empty?
        items = @time_slot_string.split(',')
        items.each { |item|
          @time_slot << TimeSlotItem.new(item)
        }
      end
      true
    end

    def decorator_json
      current_time = Time.now.to_i * 1000
      return to_decorator_json( \
          current_time - 7 * DAY_IN_MILLISECONDS \
          , current_time + 7 * DAY_IN_MILLISECONDS \
          , "#B7FF00" \
          , 30 \
          , nil \
          , nil \
          , "t-highlight1" \
          , false)
    end

    def to_decorator_json(from_date, to_date, color, opacity, start_label, end_label, css_class, in_front)
      sb = "["
      if @time_slot
        from = TimeSlot.start_of_day(from_date)
        to = TimeSlot.start_of_day(to_date)
        from.step(to, DAY_IN_MILLISECONDS) { |i|
          @time_slot.each { |item|
            json = item.to_decorator_json(i, color, opacity, start_label, end_label, css_class, in_front)
            if json && !json.empty?
              sb << json << ","
            end
          }
        }
      end
      sb << "new Timeline.PointHighlightDecorator({date:'"
      sb <<	Utils.format_date(Time.now.to_i * 1000)
      sb << "',color:'#FF0000',opacity:50,width:1})]"
    end

    def value
      @time_slot_string
    end

    def next_time(type)
      nxt = -1
      current_time = Time.now.to_i * 1000
      @time_slot.each { |item|
        tmp = item.next2(type, current_time)
        if tmp > 0
          if nxt < 0
            nxt = tmp
          else
            nxt = (tmp < nxt ? tmp : nxt)
          end
        end
      }
      nxt
    end

    def can_build(time)
      @time_slot.each { |item|
        if item.check(time)
          return true
        end
      }
      return false
    end

    def self.start_of_day(time)
      time - (time + TIME_ZONE_OFFSET) % DAY_IN_MILLISECONDS
    end

    class TimeSlotItem
      def initialize(cron)
        @dates = Array.new
        @timetable = Array.new
        @day_of_week = 0
        items = cron.split('@', 2)
        set_date_and_week items[0]
        set_time items[1]
      end

      def check(time)
        if check_date(time)
          start_of_day = TimeSlot.start_of_day(time)
          offset = time - start_of_day
          @timetable.each { |t|
            if offset >= t[START] && offset <= t[END_]
              return true
            end
          }
        end
        false
      end

      def next2(type, time)
        return 0 if @timetable.size == 0 \
          && @timetable[0][START] == 0 \
          && @timetable[0][END_] == MAX_TIME
        start_of_day = TimeSlot.start_of_day(time)
        next1 = next1(type, time)
        day = 1
        while next1 == -1 && day <= 7
          next1 = next1(type, start_of_day + day * MAX_TIME)
          day += 1
        end
        next1 = next1(type, next1 + 1) if type == END_ && next1 % MAX_TIME == 0
        next1
      end

      def next1(type, time)
        if check_date(time)
          start_of_day = TimeSlot.start_of_day(time)
          offset = time - start_of_day
          @timetable.each { |t|
            if t[type] >= offset
              return start_of_day + t[START]
            end
          }
        end
        -1
      end

      def to_decorator_json(time, color, opacity, start_label, end_label, css_class, in_front)
        return nil unless check_date(time)
        is_color_set = color && !color.empty?
        is_opacity_set = opacity >= 0
        is_start_label_set = start_label && !start_label.empty?
        is_end_label_set = end_label && !end_label.empty?
        is_css_class_set = css_class && !css_class.empty?
        sb = ""
        @timetable.each { |t|
          sb << "new Timeline.SpanHighlightDecorator({"
          sb << "startDate:'" << Utils.format_date(time + t[START]) << "',"
          sb << "endDate:'" << Utils.format_date(time + t[END_]) << "'"
          sb << ",color:'" << color << "'" if is_color_set
          sb << ",opacity:" << opacity.to_s if is_opacity_set
          sb << ",startLabel:'" << start_label << "'" if is_start_label_set
          sb << ",endLabel:'" << end_label << "'" if is_end_label_set
          sb << ",cssClass:'" << css_class << "'" if is_css_class_set
          sb << ",inFront:true" if in_front
          sb << "}),"
        }
        sb[-1] = "" if sb.length > 0
        sb
      end

      def set_date_and_week(cron)
        items = cron.split('|')
        items.each { |item|
          if item == '*'
            @dates << [0, 0]
            @day_of_week = ALL_DAYS_OF_WEEK
            return
          elsif item.include?('/')
            date_items = item.split('-')
            start_date = Utils.parse_date_string(date_items[0]).time
            if date_items.length == 2
              end_date = Utils.parse_date_string(date_items[1]).time
              @dates << [start_date, end_date + MAX_TIME]
            else
              @dates << [start_date, start_date + MAX_TIME]
            end
          else
            weekday_items = item.split('-')
            start_weekday = weekday_items[0].to_i
            if weekday_items.length == 2
              end_weekday = weekday_items[1].to_i
              start_weekday.upto(end_weekday) { |i|
                @day_of_week |= 1 << (i == 0 ? 6 : i - 1)
              }
            else
              @day_of_week |= 1 << (start_weekday == 0 ? 6 : start_weekday - 1)
            end
          end
        }
      end

      def set_time(cron)
        if cron == '*'
          @timetable << [0, MAX_TIME]
          return
        end
        time_items = cron.split('|')
        tmp = Array.new
        time_items.each { |time_item|
          tmp << parse_time_slot_string(time_item)
        }
        tmp = merge(tmp)
        tmp.each { |time_item|
          @timetable << time_item
        }
      end

      def check_date(time)
        day = Utils.day_of_week(time)
        return true if ((@day_of_week >> (day - 1)) & 1) != 0
        @dates.each { |date|
          if time >= date[START] && time <= date[END_]
            return true
          end
        }
        false
      end

      def parse_time_slot_string(time_slot_string)
        time_slot = Array.new
        items = time_slot_string.strip.split('-', 2)
        if items.length == 1
          time_slot[START] = parse_time_string(items[0])
          time_slot[START] = time_slot[START] < 0 ? 0 : time_slot[START]
          time_slot[END_] = time_slot[START] + HOUR_IN_MILLISECONDS
          time_slot[END_] = time_slot[END_] > MAX_TIME ? MAX_TIME : time_slot[END_]
        elsif items.length == 2
          time_slot[START] = parse_time_string(items[0])
          time_slot[START] = time_slot[START] < 0 ? 0 : time_slot[START]
          time_slot[END_] = parse_time_string(items[1])
          time_slot[END_] = time_slot[END_] < 0 ? MAX_TIME : time_slot[END_]
        end
        time_slot
      end

      def parse_time_string(time_string)
        return -1 if time_string.empty?
        time = 0
        milliseconds = 60 * 60 * 1000
        items = time_string.split(':')
        items.each { |item|
          time += milliseconds * item.to_i
          milliseconds /= 60
        }
        time > MAX_TIME ? MAX_TIME : time
      end

      def merge(time_slot)
        list = []
        start = []
        end_ = []
        time_slot.length.times {
          start << -1
          end_ << -1
        }
        idx = 0
        time_slot.each { |ts|
          start[idx] = ts[START]
          end_[idx] = ts[END_]
          idx += 1
          if ts[START] > ts[END_]
            start[idx] = 0
            end_[idx] = MAX_TIME
            idx += 1
          end
        }
        start.sort!
        end_.sort!
        start_idx = 0
        end_idx = 0
        while start_idx < start.length && start[start_idx] < 0
          start_idx += 1
        end
        while end_idx < end_.length && end_[end_idx] < 0
          end_idx += 1
        end
        return [0, MAX_TIME] if start_idx >= start.length || end_idx >= end_.length
        list_idx = 0
        list << [start[start_idx], end_[end_idx]]
        start_idx += 1
        end_idx += 1
        while start_idx < start.length && end_idx < end_.length
          if start[start_idx] <= end_[end_idx - 1]
            list[list_idx][END_] = end_[end_idx];
          else
            list_idx += 1
            list << [start[start_idx], end_[end_idx]]
          end
          start_idx += 1
          end_idx += 1
        end
        list
      end
    end
  end

  module TimeLine
    TIME_ERROR = 5000
    module EventType
      Normal = 0
      Blocked = 1
      Scheduled = 2
    end

    @@events = Hash.new

    def self.add_event(job_name, start, end_, title, description, type)
      list = @@events[job_name]
      unless list
        list = Array.new
        @@events[job_name] = list
      end
      event = Event.new(start, end_, title, description, type)
      list.reject! { |e|
        e.type == event.type && e.start == event.start && e.end_ == event.end_
      }
      list << event
    end

    def self.remove_event1(job_name, start, end_, type)
      list = @@events[job_name]
      return unless list
      list.reject! { |e|
        e.type == type \
          && (e.start - start).abs <= TIME_ERROR \
          && (e.end_ - end_).abs <= TIME_ERROR
      }
    end

    def self.remove_event(job_name, type)
      list = @@events[job_name]
      return unless list
      list.reject! { |e|
        e.type == type
      }
    end

    def self.remove_event_all(job_name, type)
      list = @@events[job_name]
      return unless list
      list.reject! { |e|
        e.type == type
      }
    end

    def self.event_json(job_name)
      sb = ""
      list = @@events[job_name]
      if list
        list.each { |event|
          sb << event.to_json << ','
        }
      end
      sb[-1] = "" unless sb.empty?
      sb
    end

    class Event
      def initialize(start, end_, title, description, type)
        @start = start
        @end_ = end_
        @title = title
        @description = description
        @type = type
        @root_url = Java.jenkins.model.Jenkins.getInstance.root_url
      end

      attr_reader :start, :end_, :type

      def to_json
        sb = "{"
        sb << "'start':'" << Utils.format_date(@start) << "'"
        if @end_ >= @start
          sb << ",'end':'" << Utils.format_date(@end_) << "'" << ",'durationEvent':true"
        else
          sb << ",'durationEvent':false"
        end
        sb << ",'title':'" << @title << "'" if @title
        sb << ",'description':'" << @description << "'" if @description
        case @type
        when EventType::Blocked
          sb << ",'icon':'" << @root_url << "sj/timeline_2.3.0/timeline_js/images/dark-red-circle.png'"
        when EventType::Scheduled
          sb << ",'icon':'" << @root_url << "sj/timeline_2.3.0/timeline_js/images/dark-blue-circle.png'"
        end
        sb << "}"
      end
    end
  end

  module Utils
    @@df = Java.java.text.DateFormat.getDateTimeInstance

    class << Utils
      include Constants

      def format_date(date)
        if date.is_a?(Java.java.util.Date)
          return @@df.format(date)
        else
          if date > 0
            return @@df.format(Java.java.util.Date.new(date))
          else
            return ''
          end
        end
      end

      def parse_date_string(date_string)
        begin
          if date_string.include?(':')
            return @@df.parse(date_string)
          else
            return @@df.parse(date_string + " 00:00:00")
          end
        rescue
          p $!
          return nil
        end
      end

      def day_of_week(time)
        calendar = Java.java.util.Calendar.getInstance
        calendar.time_in_millis = time
        day = calendar.get(Java.java.util.Calendar::DAY_OF_WEEK) - 1
        day == 0 ? 7 : day
      end

      def startup(slave_name)
        mac_addr = ComputerManager.instance.config(slave_name)[MAC_ADDRESS]
        wakeonlan(mac_addr) unless mac_addr.empty?
      end

      def wakeonlan(mac_addr)
        sock = UDPSocket.open
        sock.setsockopt(Socket::SOL_SOCKET, Socket::SO_BROADCAST, 1)
        magic = (0xff.chr) * 6 + (mac_addr.split(/:/).pack("H*H*H*H*H*H*")) * 16
        sock.send(magic, 0, '255.255.255.255', "discard")
        sock.close
      end

      def shutdown(slave_name)
        com_manager = ComputerManager.instance
        master_host_name = com_manager.config('')[HOST]
        host_name = com_manager.config(slave_name)[HOST]
        return if host_name == master_host_name
        slave = slave(slave_name)
        command = case com_manager.config(slave_name)[OS]
        when /Windows/i
          SHUTDOWN_WINDOWS
        when /Unix/i
          SHUTDOWN_UNIX
        end
        Java.hudson.util.RemotingDiagnostics.executeGroovy(command, slave.channel)
      end
    end
  end

  module SmartJenkinsCause
    attr_accessor :time
  end

  class Scheduler
    include Singleton
    include SmartJenkinsCause

    def initialize
      @build_tasks = Hash.new
    end

    def schedule(job, time)
      if time > 0
        task = @build_tasks[job.name]
        task.cancel if task
        task = BuildTask.new
        task.job = job
        @build_tasks[job.name] = task
        Java.hudson.triggers.Trigger.timer.schedule(task, Java.java.util.Date.new(time))
      end
    end

    def remove(job)
      task = @build_tasks[job.name]
      if task
        task.cancel
        @build_tasks.delete(job.name)
      end
    end

    def run(job)
      cause = Java.hudson.model.Cause::UserIdCause.new
      cause.extend SmartJenkinsCause
      cause.time = Time.now.to_i * 1000
      job.scheduleBuild(0, cause)
    end

    def on_job_name_changed(old_name, new_name)
      if @build_tasks.key?(old_name)
        @build_tasks[new_name] = @build_tasks[old_name]
      end
    end

    def on_job_deleted(job_name)
      if @build_tasks.key?(job_name)
        @build_tasks[job_name].cancel
        @build_tasks.delete(job_name)
      end
    end
  end

  class BuildTask < Java.hudson.triggers.SafeTimerTask
    include SmartJenkinsCause

    def initialize
      super
      @job = nil
    end
    attr_writer :job

    def doRun
      cause = Java.hudson.model.Cause::UserIdCause.new
      cause.extend SmartJenkinsCause
      cause.time = Time.now.to_i * 1000
      @job.scheduleBuild(0, cause)
    end
  end
end

class SmartJenkinsItemListener < Jenkins::Model::Listeners::ItemListener
  include SmartJenkins
  include SmartJenkins::Constants

	def on_loaded
    JobManager.instance.init jobs
    Configuration.instance.save
    return unless Configuration.instance[ENABLE]
    job_manager = JobManager.instance
		current_time = Time.now.to_i * 1000
    jobs.each { |job|
      name = job.name
      config = job_manager.config(name)
      next unless config[ENABLE]
      if config[NEXT_SCHEDULED] >= current_time
        Scheduler.instance.schedule(job, config[NEXT_SCHEDULED])
        TimeLine.add_event(name, config[NEXT_SCHEDULED], -1, name, "Scheduled", TimeLine::EventType::Scheduled)
      else
        config[NEXT_SCHEDULED] = -1
      end
    }
    Configuration.instance.save
  end

	def on_created(item)
    if item.is_a?(Jenkins::Model::Job)
      JobManager.instance.create item.native
      Configuration.instance.save
    end
  end

	def on_deleted(item)
		if item.is_a?(Jenkins::Model::Job)
      JobManager.instance.remove item.native
      Configuration.instance.save
    end
  end

	def on_renamed(item, old_name, new_name)
		if item.is_a?(Jenkins::Model::Job)
      config = JobManager.instance.config old_name
      native = item.native
      JobManager.instance.remove old_name
      JobManager.instance.create native
      native.sj_config.merge! config
      Configuration.instance.save
    end
  end
end

class SmartJenkinsComputerListener < Jenkins::Slaves::ComputerListener
  include SmartJenkins

  @@initialized = false

  def on_configuration_change
    cm = ComputerManager.instance
    unless @@initialized
      @@initialized = true
      cm.init computers
      computers.each { |com|
        cm.update_info com
      }
    end
    config = cm.config
    names = Array.new
    slaves.each { |slave|
      name = slave.name
      unless slave.node
        cm.remove slave
      else
        if defined?(slave.sj_config)
          unless config.key? name
            c = slave.sj_config
            cm.create slave
            slave.sj_config.merge! c
          end
        else
          cm.create slave
        end
      end
      names << name
    }
    config.reject! { |key, value|
      !names.include? key
    }
    Configuration.instance.save
  end

  def on_online(computer, task_listener)
    ComputerManager.instance.update_info computer.native
    Configuration.instance.save
  end

  def on_offline(computer)
    ComputerManager.instance.update_info computer.native
    Configuration.instance.save
  end
end

class SmartJenkinsWidget < Java.hudson.widgets.Widget
  include Java.hudson.model.RootAction
  include SmartJenkins
  include SmartJenkins::Constants

  def getIconFileName
    nil
  end

  def getDisplayName
    'Smart Jenkins'
  end

  def getUrlName
    'sj'
  end

  def initialize
    super
    @action = SmartJenkinsAction.new(self)
    @jenkins = Java.jenkins.model.Jenkins.instance
    @config = Configuration.instance
    @job_manager = JobManager.instance
    @computer_manager = ComputerManager.instance
    @time_slot = TimeSlot.instance
  end
  attr_reader :config, :time_slot, :job_manager, :computer_manager

  include Jenkins::RackSupport
  def call(env)
    @action.call(env)
  end

  def view_names
    names = []
    @jenkins.views.each { |view|
      names << view.view_name
    }
    names
  end

  def view_name
    unless @config[VIEW]
      @config[VIEW] = @jenkins.primary_view.view_name
      @config.save
    end
    @config[VIEW]
  end

  def filtered_jobs
    filtered = []
    pattern = /.*/
    pattern = @config[JOB_FILTER].empty? ? /.*/ : Regexp.new(@config[JOB_FILTER])
    @jenkins.get_view(@config[VIEW]).items.each { |job|
      filtered << job if job.name =~ pattern
    }
    filtered
  end

  def job_config(name)
    @job_manager.config(name)
  end

  def job_events_json
    @job_manager.events_json(jobs)
  end

  def filtered_slaves
    filtered = []
    pattern = @config[SLAVE_FILTER].empty? ? /.*/ : Regexp.new(@config[SLAVE_FILTER])
    slaves.each { |slave|
      filtered << slave if slave.name =~ pattern
    }
    filtered
  end

  def computer_config(name)
    @computer_manager.config(name)
  end

  def time_zone_offset
    Java.java.util.Calendar.instance.time_zone.raw_offset / 60.0 / 60.0 / 1000.0
  end

  def current_time
    Utils.format_date(Time.now.to_i * 1000)
  end

  def root_url
    @jenkins.root_url
  end

  def format_date(time_in_millis)
    Utils.format_date time_in_millis
  end

  def do_onoff(slave_name)
    config = @computer_manager.config(slave_name)
    case config[OPERATION]
    when ON
      Utils.startup(slave_name)
    when OFF
      Utils.shutdown(slave_name)
    end
  end
end

class SmartJenkinsAction < Sinatra::Base
  include SmartJenkins
  include SmartJenkins::Constants

  def initialize(widget)
    super
    @root_dir = Dir.pwd
    @widget = widget
  end

  set :public_folder, "#{Dir.pwd}/views/smart-jenkins"

  get '/main' do
    erb :main, :views => "#{@root_dir}/views/smart-jenkins"
  end

  get '/enable' do
    @widget.config[ENABLE] = !@widget.config[ENABLE]
    @widget.config.save
    erb :main, :views => "#{@root_dir}/views/smart-jenkins"
  end

  get '/font_size' do
    font_size = params[:size]
    @widget.config[FONT_SIZE] = font_size
    @widget.config.save
    erb :main, :views => "#{@root_dir}/views/smart-jenkins"
  end

  get '/change_tab' do
    tab = params[:tab].to_i
    if tab >= 0 && tab <= 1 && @widget.config[TAB_TYPE] != tab
      @widget.config[TAB_TYPE] = tab
      @widget.config.save
    end
    erb :main, :views => "#{@root_dir}/views/smart-jenkins"
  end

  get '/onoff' do
    @widget.do_onoff params[:slave]
    ''
  end

  post '/configure_timeslot' do
    time_slot = params[:time_slot]
		@widget.config.save if @widget.time_slot.set_time_slot(time_slot, true)
    erb :main, :views => "#{@root_dir}/views/smart-jenkins"
  end

  post '/configure' do
    config = @widget.config
		if config[TAB_TYPE] == 0
      job_manager = @widget.job_manager
      @widget.filtered_jobs.each { |job|
				name = job.name
        job_conf = job_manager.config(name)
				enable = params[(name + ENABLE_SUFFIX).to_sym]
				schedule = params[(name + SCHEDULE_SUFFIX).to_sym]
				if job_manager.update(name, enable, schedule)
					nxt = job_conf[NEXT_SCHEDULED]
					if nxt > 0
						TimeLine.remove_event(name, TimeLine::EventType::Scheduled)
            TimeLine.add_event(name, nxt, -1, name, "Scheduled", TimeLine::EventType::Scheduled)
            Scheduler.instance.schedule(job, nxt)
					else
						TimeLine.remove_event(name, TimeLine::EventType::Scheduled)
						Scheduler.instance.remove(job)
          end
        end
			}
			config.save
		elsif config[TAB_TYPE] == 1
      com_manager = @widget.computer_manager
      @widget.filtered_slaves.each { |slave|
				name = slave.name
        com_conf = com_manager.config(name)
				enable = params[(name + ENABLE_SUFFIX).to_sym]
				if !enable && com_conf[ENABLE]
					com_conf[ENABLE] = false
        elsif enable && !com_conf[ENABLE]
          com_conf[ENABLE] = true
        end
			}
			config.save
    end
    erb :main, :views => "#{@root_dir}/views/smart-jenkins"
  end

  post '/filter' do
    filter = params['filter']
    view_name = params['view_name']
    config = @widget.config
    if config[TAB_TYPE] == 0
      config[VIEW] = view_name if view_name && !view_name.empty?
      config[JOB_FILTER] = filter if filter
    elsif config[TAB_TYPE] == 1
      config[SLAVE_FILTER] = filter if filter
    end
    config.save
    erb :main, :views => "#{@root_dir}/views/smart-jenkins"
  end

  get '/refresh' do
    config = @widget.computer_manager.config
    slaves.each { |slave|
      op = slave.online? ? OFF : ON
      unless config[slave.name][OPERATION] == op
        @widget.computer_manager.update_info(slave)
      end
    }
    config.to_json
  end
end

class SmartJenkinsQueueDecisionHandler < Jenkins::Model::Queue::QueueDecisionHandler
  include SmartJenkins
  include SmartJenkins::Constants

	def should_schedule(p, actions)
    config = Configuration.instance
		return true if !config[ENABLE]
		name = p.name
		job_conf = JobManager.instance.config(name)
		return true unless job_conf
		actions.each { |action|
			if action.is_a?(Java.hudson.model.CauseAction)
				causes = action.causes
				causes.each { |cause|
					if cause.is_a?(Java.hudson.model.Cause::UserIdCause) && defined?(cause.time)
						time = cause.time
						TimeLine.remove_event1(name, time, -1, TimeLine::EventType::Scheduled)
						job_conf[LAST_SCHEDULED] = time
						job_conf[NEXT_SCHEDULED] = -1
						config.save
						return true
          end
				}
      end
		}
		time_slot = TimeSlot.instance
		current_time = Time.now.to_i * 1000
		time_slot_next_start = time_slot.next_time(TimeSlot::START)
		job_next_start = job_conf[NEXT_SCHEDULED]
		next_start = -1
		if time_slot_next_start > 0
			next_start = (job_next_start > 0 ? [time_slot_next_start, job_next_start].min : time_slot_next_start)
		else
			next_start = job_next_start > 0 ? job_next_start : -1
    end
		return true if time_slot.can_build(current_time)
		if job_conf[ENABLE]
			if (job_conf[NEXT_SCHEDULED] - current_time).abs <= TimeLine::TIME_ERROR
				job_conf[LAST_SCHEDULED] = current_time
				job_conf[NEXT_SCHEDULED] = -1
				config.save
				TimeLine.remove_event(name, TimeLine::EventType::Scheduled)
				return true
			else
				block = true
				slaves.each { |slave|
          com_conf = ComputerManager.instance.config(slave.name)
					if !com_conf[ENABLE]
						if can_take(slave.node, p)
							block = false
							break
            end
          end
				}
				if block
					job_conf[LAST_BLOCKED] = current_time
					job_conf[NEXT_SCHEDULED] = next_start
					config.save
					TimeLine.add_event(name, current_time, -1, name, "Blocked", TimeLine::EventType::Blocked)
					TimeLine.add_event(name, job_conf[NEXT_SCHEDULED], -1, name, "Scheduled", TimeLine::EventType::Scheduled)
					return false
				else
					return true
        end
      end
		else
			return true
    end
  end

	def can_take(node, p)
    true
  end
end

class SmartJenkinsSlaveController < Jenkins::Model::PeriodicWork
  include SmartJenkins
  include SmartJenkins::Constants

  DEFAULT_INITIAL_DELAY = 1000 * 60
  DEFAULT_PERIOD = 1000 * 30
  DEFAULT_OFF_TIME = 1000 * 60 * 10

  @@period = DEFAULT_PERIOD
  @@off_time = DEFAULT_OFF_TIME

  def self.period
    @@period
  end

  def self.period=(p)
    @@period = p
  end

  def self.off_time
    @@off_time
  end

  def self.off_time=(t)
    @@off_time = t
  end

  def initialize
    @ok = false
  end

  def recurrence_period
    @@period
  end

  def initial_delay
    DEFAULT_INITIAL_DELAY
  end

  def do_run
    return unless Configuration.instance[ENABLE]
    computer_manager = ComputerManager.instance
    begin
    current_time = Time.now.to_i * 1000
    can_build = TimeSlot.instance.can_build(current_time)
    if can_build
      nodes = Hash.new
      Java.jenkins.model.Jenkins.getInstance.queue.items.each { |item|
        label = item.assigned_label
        if label
          label.nodes.each { |node|
            nodes[node.node_name] = node
          }
        end
      }
      nodes.each { |name, node|
        slave = slave(name)
        if slave && slave.offline? && computer_manager.config(name)[ENABLE]
          Utils.startup(name)
        end
      }
    end

    names = Array.new
    slaves.each { |slave|
      slave_conf = computer_manager.config(slave.name)
      if slave.online? && slave.idle?
        last_build = slave.builds.last_build
        next unless last_build
        if last_build.hasnt_started_yet || last_build.building?
          slave_conf[LAST_BUILD] = -1
          next
        end
        slave_conf[LAST_BUILD] = last_build.time_in_millis + last_build.duration
        if Time.now.to_i * 1000 - slave_conf[LAST_BUILD] > DEFAULT_OFF_TIME
          node = slave.node
          if node
            labels = node.assigned_labels
            do_shutdown = true
            labels.each { |label|
              label.tied_jobs.each { |job|
                triggers = job.triggers
                if triggers
                  triggers.each_value { |trigger|
                    cron = Java.hudson.scheduler.CronTabList.create(trigger.spec)
                    cal = Java.java.util.GregorianCalendar.new
                    while cal.time_in_millis - current_time <= DEFAULT_OFF_TIME * 2
                      if cron.check(cal)
                        do_shutdown = false
                        break
                      end
                      cal.add(Java.java.util.Calendar::MINUTE, 1)
                    end
                  }
                end
                break unless do_shutdown
              }
              break unless do_shutdown
            }
          end
          names << slave.name if do_shutdown
        end
      end
    }
    names.each { |name|
      Utils.shutdown(name)
    }

    if @ok != can_build
      if @ok
        names = Array.new
        slaves.each { |slave|
          if slave.online? && computer_manager.config(slave.name)[ENABLE] && slave.idle?
            names << slave.name
          end
        }
        names.each { |name|
          Utils.shutdown(names)
        }
      end
      @ok = can_build
    end
    rescue
      p $!
    end
  end
end

module SmartJenkinsViewManager
  def self.set_view(instance)
    root = FileUtils.pwd + '/views/'
    path = root + instance.getClass.getName.gsub(/[.$]/, '/')
    FileUtils.mkdir_p path
    FileUtils.cp_r Dir.glob(root + '/' + instance.class.name + '/*'), path
  end
end

Jenkins::Plugin.instance.register_extension(SmartJenkinsItemListener)
Jenkins::Plugin.instance.register_extension(SmartJenkinsSlaveController)
Jenkins::Plugin.instance.register_extension(SmartJenkinsComputerListener)
Jenkins::Plugin.instance.register_extension(SmartJenkinsQueueDecisionHandler)
widget = SmartJenkinsWidget.new
SmartJenkinsViewManager.set_view widget
Jenkins::Plugin.instance.peer.addExtension widget
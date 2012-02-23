
Jenkins::Plugin::Specification.new do |plugin|
  plugin.name = 'smart-jenkins-ruby'
  plugin.version = '0.0.1'
  plugin.description = 'Smart Jenkins Ruby'
  plugin.url = ''

  plugin.depends_on 'ruby-runtime', '0.3'
  plugin.depends_on 'git', '1.1.11'
end

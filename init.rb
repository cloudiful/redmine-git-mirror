# frozen_string_literal: true

require_relative 'lib/redmine_git_mirror'

Redmine::Plugin.register :redmine_git_mirror do
  name 'Redmine Git Mirror plugin'
  description 'Clones and fetches allowed remote Git repositories into a local mirror and registers a native Redmine Git repository.'
  version '0.2.1'
  requires_redmine version_or_higher: '7.0.0'

  settings default: {
    'allowed_hosts' => '',
    'mirror_root' => '',
    'api_key' => ''
  }

  menu :admin_menu, :redmine_git_mirror_settings,
       { controller: 'redmine_git_mirror/settings', action: 'edit' },
       caption: 'Git mirrors',
       icon: 'git-mirror',
       plugin: :redmine_git_mirror,
       html: { class: 'icon icon-git-mirror' }
end

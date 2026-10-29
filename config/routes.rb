# frozen_string_literal: true

scope = '/sys/redmine_git_mirror'
scope_format = { format: :json }

post "#{scope}/projects/:project_id/repository",
     to: 'redmine_git_mirror/repository#create',
     defaults: scope_format,
     constraints: { project_id: /\d+/ }

get "#{scope}/projects/:project_id/repository",
    to: 'redmine_git_mirror/repository#show',
    defaults: scope_format,
    constraints: { project_id: /\d+/ }

get "#{scope}/projects/:project_id/repository/:identifier",
    to: 'redmine_git_mirror/repository#show',
    defaults: scope_format,
    constraints: { project_id: /\d+/, identifier: /[a-zA-Z0-9_-]+/ }

settings_scope = '/redmine_git_mirror/settings'

# Named helpers so generated URLs follow RAILS_RELATIVE_URL_ROOT.
get settings_scope,
    to: 'redmine_git_mirror/settings#edit',
    as: :redmine_git_mirror_settings

patch settings_scope,
      to: 'redmine_git_mirror/settings#update'

post "#{settings_scope}/rotate_api_key",
     to: 'redmine_git_mirror/settings#rotate_api_key',
     as: :rotate_redmine_git_mirror_api_key

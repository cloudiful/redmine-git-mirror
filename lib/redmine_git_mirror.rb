# frozen_string_literal: true

module RedmineGitMirror
  DEFAULT_ALLOWED_HOSTS = [].freeze
  DEFAULT_MIRROR_ROOT = '/var/lib/redmine/repositories'
  DEFAULT_COMMAND_TIMEOUT = 600
  DEFAULT_API_KEY_ENV = 'REDMINE_GIT_MIRROR_API_KEY'
  DEFAULT_ALLOWED_HOSTS_ENV = 'REDMINE_GIT_MIRROR_ALLOWED_HOSTS'
  DEFAULT_MIRROR_ROOT_ENV = 'REDMINE_GIT_MIRROR_ROOT'
  DEFAULT_TIMEOUT_ENV = 'REDMINE_GIT_MIRROR_TIMEOUT'
  STATUSES = %w[pending cloning ready failed].freeze
end

require_relative 'redmine_git_mirror/config'
require_relative 'redmine_git_mirror/settings_store'
require_relative 'redmine_git_mirror/authenticator'
require_relative 'redmine_git_mirror/url_validator'
require_relative 'redmine_git_mirror/command_runner'
require_relative 'redmine_git_mirror/repository_registrar'
require_relative 'redmine_git_mirror/mirror_service'
require_relative 'redmine_git_mirror/mirror_job_runner'

# MirrorRefreshJob is the ActiveJob wrapper and only loads when
# ActiveJob is available (i.e. inside Rails). The plain-Ruby
# MirrorJobRunner covers all behaviour that is exercised in standalone
# unit tests.
if defined?(ActiveJob::Base)
  require_relative 'redmine_git_mirror/mirror_refresh_job'
end

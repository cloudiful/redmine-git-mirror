# frozen_string_literal: true

# Test helper for the redmine_git_mirror plugin. Supports two modes:
#
#   1. Standalone: when Redmine is not available, the helper sets up a
#      minimal in-memory ActiveRecord schema so the model and service
#      classes can be exercised directly. Controller code is not loaded
#      but the authentication helper is unit-tested directly.
#
#   2. Redmine: when invoked through `rake redmine:plugins:test` the
#      helper loads Redmine's own test_helper and exposes its fixtures.

require 'minitest/autorun'
require 'active_support'
require 'active_support/core_ext/string/strip'
require 'active_support/security_utils'
require 'fileutils'

plugin_root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift(File.join(plugin_root, 'lib'))
# NOTE: app/models and app/controllers are intentionally NOT added to the load
# path. The top-level `redmine_git_mirror.rb` namespace lives in `lib/` and
# defines constants such as STATUSES; if `app/models` is added first,
# `require 'redmine_git_mirror'` resolves to the model file and the
# namespace constants never load.

# Redmine's plugin test task puts the checkout's `test` directory on
# $LOAD_PATH. A plugin can be a real directory under `plugins/` or a symlink
# from elsewhere, so locating Redmine's harness there is reliable while
# deriving the checkout from this file's directory is not (symlinks resolve to
# the plugin's real location). The `config/environment.rb` sibling check keeps
# this file itself from being mistaken for Redmine's helper.
redmine_helper =
  $LOAD_PATH
    .map { |dir| File.expand_path('test_helper.rb', dir) }
    .find { |path| File.file?(path) && File.file?(File.expand_path('../../config/environment.rb', path)) } ||
  File.expand_path('../../../test/test_helper.rb', __dir__)

if File.file?(redmine_helper)
  require redmine_helper
else
  ENV['RAILS_ENV'] ||= 'test'

  require 'active_record'
  begin
    require 'sqlite3'
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
  rescue LoadError
    # SQLite is not available; tests that need a database are skipped below.
  end

  # Stand-in for Rails' ApplicationRecord. Redmine's own models inherit from
  # ActiveRecord::Base, but the plugin model references ApplicationRecord for
  # parity with the rest of the Rails ecosystem.
  unless defined?(ApplicationRecord)
    class ApplicationRecord < ActiveRecord::Base
      self.abstract_class = true
    end
  end

  ActiveRecord::Schema.define do
    create_table :redmine_git_mirrors, force: true do |t|
      t.integer :project_id, null: false
      t.string :remote_url, null: false, limit: 255
      t.string :local_path, null: false, limit: 255
      t.string :identifier, null: false, limit: 100
      t.string :status, null: false, limit: 16, default: 'pending'
      t.text :error_message
      t.timestamps null: false
    end
  end

  # Stub Project so MirrorService can look up by id without booting Redmine.
  class Project < ActiveRecord::Base
    class << self
      attr_accessor :store

      def find(id)
        self.store ||= {}
        record = store[id.to_i]
        raise ActiveRecord::RecordNotFound, "project #{id} not found" unless record

        record
      end

      def stub_record(id, attrs = {})
        self.store ||= {}
        record = Struct.new(:id, :identifier, :name).new(
          id.to_i,
          attrs[:identifier] || "project-#{id}",
          attrs[:name] || "Project #{id}"
        )
        store[id.to_i] = record
      end
    end
  end
end

# Load the plugin namespace first so the model can reference its constants.
require 'redmine_git_mirror'
require 'redmine_git_mirror/config'
require 'redmine_git_mirror/settings_store'
require 'redmine_git_mirror/authenticator'
require 'redmine_git_mirror/url_validator'
require 'redmine_git_mirror/command_runner'
require 'redmine_git_mirror/repository_registrar'
require 'redmine_git_mirror/mirror_service'
require 'redmine_git_mirror/mirror_job_runner'
require_relative File.join('..', 'app', 'models', 'redmine_git_mirror') unless defined?(RedmineGitMirror::Mirror)

module EnvHelpers
  def with_env(values)
    previous = {}
    values.each_pair do |key, value|
      previous[key] = ENV[key]
      ENV[key] = value
    end
    yield
  ensure
    previous.each_pair { |key, value| ENV[key] = value }
  end

  def reset_env!
    %w[
      REDMINE_GIT_MIRROR_API_KEY
      REDMINE_GIT_MIRROR_ALLOWED_HOSTS
      REDMINE_GIT_MIRROR_ROOT
      REDMINE_GIT_MIRROR_TIMEOUT
    ].each { |key| ENV.delete(key) }
  end
end

Minitest::Test.include EnvHelpers

module SkipHelper
  def skip_if(condition, message = 'required dependency missing')
    skip(message) if condition
  end
end

Minitest::Test.include SkipHelper

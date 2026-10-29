# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)

# Exercises the persisted-settings layer of Config: saved-over-ENV
# precedence, API key generation and rotation, input validation, and
# merge-preserving saves. Uses an in-memory store so the tests never
# touch Redmine's Setting table.
class RedmineGitMirrorSettingsTest < Minitest::Test
  class MemoryStore
    attr_reader :data

    def initialize(data = {})
      @data = data
      @writable = true
    end

    def read
      @data.dup
    end

    def write(values)
      return false unless @writable

      values.each_pair { |key, value| @data[key.to_s] = value }
      true
    end

    def make_read_only!
      @writable = false
    end
  end

  def setup
    reset_env!
    @store = MemoryStore.new
    RedmineGitMirror::Config.settings_store = @store
  end

  def teardown
    RedmineGitMirror::Config.reset_settings_store!
    reset_env!
  end

  def test_api_key_prefers_saved_value_over_environment
    @store.write('api_key' => 'saved-key')
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'env-key') do
      assert_equal 'saved-key', RedmineGitMirror::Config.api_key
    end
  end

  def test_api_key_falls_back_to_environment_then_blank
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'env-key') do
      assert_equal 'env-key', RedmineGitMirror::Config.api_key
      assert RedmineGitMirror::Config.api_key_configured?
    end
    assert_equal '', RedmineGitMirror::Config.api_key
    refute RedmineGitMirror::Config.api_key_configured?
  end

  def test_blank_saved_values_fall_back_to_environment
    @store.write('api_key' => '  ', 'allowed_hosts' => '', 'mirror_root' => '')
    with_env(
      'REDMINE_GIT_MIRROR_API_KEY' => 'env-key',
      'REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.a.test',
      'REDMINE_GIT_MIRROR_ROOT' => '/srv/mirrors'
    ) do
      assert_equal 'env-key', RedmineGitMirror::Config.api_key
      assert_equal ['git.a.test'], RedmineGitMirror::Config.allowed_hosts
      assert_equal '/srv/mirrors', RedmineGitMirror::Config.mirror_root
    end
  end

  def test_allowed_hosts_prefers_saved_value_over_environment
    @store.write('allowed_hosts' => 'saved.example.com, other.example.com')
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'env.example.com') do
      assert_equal %w[saved.example.com other.example.com],
                   RedmineGitMirror::Config.allowed_hosts
    end
  end

  def test_allowed_hosts_accepts_saved_array
    @store.write('allowed_hosts' => ['a.example.com', 'b.example.com'])
    assert_equal %w[a.example.com b.example.com],
                 RedmineGitMirror::Config.allowed_hosts
  end

  def test_mirror_root_prefers_saved_value_over_environment
    @store.write('mirror_root' => '/data/mirrors')
    with_env('REDMINE_GIT_MIRROR_ROOT' => '/srv/mirrors') do
      assert_equal '/data/mirrors', RedmineGitMirror::Config.mirror_root
    end
  end

  def test_mirror_root_defaults_without_saved_or_environment
    assert_equal '/var/lib/redmine/repositories', RedmineGitMirror::Config.mirror_root
  end

  def test_ensure_api_key_generates_url_safe_key_and_persists_it
    key = RedmineGitMirror::Config.ensure_api_key!

    assert_match(/\A[A-Za-z0-9\-_]{32,}\z/, key)
    assert_equal key, @store.read['api_key']
    assert RedmineGitMirror::Config.api_key_configured?
    assert_equal key, RedmineGitMirror::Config.ensure_api_key!
  end

  def test_ensure_api_key_returns_environment_key_without_persisting
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'env-key') do
      assert_equal 'env-key', RedmineGitMirror::Config.ensure_api_key!
      assert_nil @store.read['api_key']
    end
  end

  def test_ensure_api_key_returns_blank_when_store_is_unavailable
    @store.make_read_only!
    assert_equal '', RedmineGitMirror::Config.ensure_api_key!
  end

  def test_rotate_api_key_persists_different_key_and_invalidates_old
    old_key = RedmineGitMirror::Config.ensure_api_key!
    assert RedmineGitMirror::Authenticator.authenticated?(old_key)

    new_key = RedmineGitMirror::Config.rotate_api_key!

    refute_equal old_key, new_key
    assert_equal new_key, @store.read['api_key']
    assert RedmineGitMirror::Authenticator.authenticated?(new_key)
    refute RedmineGitMirror::Authenticator.authenticated?(old_key)
  end

  def test_rotate_api_key_overrides_environment_key
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'env-key') do
      new_key = RedmineGitMirror::Config.rotate_api_key!

      refute_equal 'env-key', new_key
      assert_equal new_key, RedmineGitMirror::Config.api_key
      assert RedmineGitMirror::Authenticator.authenticated?(new_key)
      refute RedmineGitMirror::Authenticator.authenticated?('env-key')
    end
  end

  def test_validate_settings_accepts_valid_input_with_normalization
    values, errors = RedmineGitMirror::Config.validate_settings(
      'allowed_hosts' => 'Git.A.Test, git.b.test ',
      'mirror_root' => '/srv/mirrors'
    )

    assert_empty errors
    assert_equal 'git.a.test, git.b.test', values['allowed_hosts']
    assert_equal '/srv/mirrors', values['mirror_root']
    refute values.key?('api_key')
  end

  def test_validate_settings_rejects_blank_hosts
    _values, errors = RedmineGitMirror::Config.validate_settings(
      'allowed_hosts' => ' , ',
      'mirror_root' => '/srv/mirrors'
    )

    assert errors.any? { |message| message.include?('Allowed hosts') }
  end

  def test_validate_settings_rejects_malformed_hosts
    _values, errors = RedmineGitMirror::Config.validate_settings(
      'allowed_hosts' => 'good.example.com, bad host!',
      'mirror_root' => '/srv/mirrors'
    )

    assert errors.any? { |message| message.include?('bad host!') }
  end

  def test_validate_settings_rejects_relative_mirror_root
    _values, errors = RedmineGitMirror::Config.validate_settings(
      'allowed_hosts' => 'git.example.com',
      'mirror_root' => 'relative/path'
    )

    assert errors.any? { |message| message.include?('absolute') }
  end

  def test_validate_settings_rejects_filesystem_root
    _values, errors = RedmineGitMirror::Config.validate_settings(
      'allowed_hosts' => 'git.example.com',
      'mirror_root' => '/'
    )

    assert errors.any? { |message| message.include?('filesystem root') }
  end

  def test_validate_settings_rejects_root_with_null_byte_without_raising
    values, errors = RedmineGitMirror::Config.validate_settings(
      'allowed_hosts' => 'git.example.com',
      'mirror_root' => "/tmp/a\0b"
    )

    assert errors.any? { |message| message.include?('invalid characters') }
    assert_nil values['mirror_root']
  end

  def test_save_settings_merges_and_preserves_api_key
    @store.write('api_key' => 'original-key')
    assert RedmineGitMirror::Config.save_settings('allowed_hosts' => 'git.example.com',
                                                  'mirror_root' => '/srv/mirrors')

    assert_equal 'original-key', @store.read['api_key']
    assert_equal 'git.example.com', @store.read['allowed_hosts']
    assert_equal '/srv/mirrors', @store.read['mirror_root']
  end

  def test_save_settings_normalizes_keys_to_strings
    RedmineGitMirror::Config.save_settings(allowed_hosts: 'git.example.com',
                                           mirror_root: '/srv/mirrors')

    assert_equal 'git.example.com', @store.read['allowed_hosts']
    assert_equal '/srv/mirrors', @store.read['mirror_root']
  end

  # Regression: production eager loading requires every plugin lib file
  # to define the constant Zeitwerk derives from the file basename.
  # Assert that mapping for every plugin lib file the tests load.
  def test_lib_files_define_the_constant_derived_from_their_basename
    loaded = $LOADED_FEATURES.filter_map do |path|
      next unless path.end_with?('.rb')

      dir = File.dirname(path)
      next unless dir.end_with?('/lib/redmine_git_mirror')

      File.basename(path, '.rb')
    end

    assert_includes loaded, 'settings_store'

    mismatched = loaded.uniq.sort.reject do |basename|
      RedmineGitMirror.const_defined?(camelize(basename), false)
    end

    assert_empty mismatched,
                 'lib/redmine_git_mirror files must define the constant Zeitwerk derives ' \
                 "from the basename for eager loading; mismatched: #{mismatched.join(', ')}"
  end

  def test_default_settings_store_is_the_zeitwerk_named_class
    RedmineGitMirror::Config.reset_settings_store!
    assert_instance_of RedmineGitMirror::SettingsStore,
                       RedmineGitMirror::Config.settings_store
  ensure
    RedmineGitMirror::Config.reset_settings_store!
  end

  private

  def camelize(basename)
    basename.split('_').map(&:capitalize).join
  end
end

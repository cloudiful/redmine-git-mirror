# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)

class RedmineGitMirrorConfigTest < Minitest::Test
  def teardown
    reset_env!
  end

  def test_api_key_defaults_to_blank
    assert_equal '', RedmineGitMirror::Config.api_key
    refute RedmineGitMirror::Config.api_key_configured?
  end

  def test_api_key_reads_environment
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'super-secret-value') do
      assert_equal 'super-secret-value', RedmineGitMirror::Config.api_key
      assert RedmineGitMirror::Config.api_key_configured?
    end
  end

  def test_allowed_hosts_defaults_to_empty
    assert_equal [], RedmineGitMirror::Config.allowed_hosts
  end

  def test_url_validation_fails_closed_without_configured_hosts
    assert_empty RedmineGitMirror::Config.allowed_hosts

    result = RedmineGitMirror::UrlValidator.validate('https://git.example.com/acme/widgets.git')

    refute result.ok?
    assert_match(/allow list is empty/i, result.error)
  end

  def test_explicit_allowed_hosts_accept_matching_url
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.example.com') do
      result = RedmineGitMirror::UrlValidator.validate('https://git.example.com/acme/widgets.git')

      assert result.ok?, result.error
      assert_equal 'git.example.com', result.parsed.host
    end
  end

  def test_url_validation_rejects_unlisted_host
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.other.example/acme/widgets.git',
      allowed_hosts: ['git.example.com']
    )

    refute result.ok?
    assert_match(/not in the allow list/, result.error)
  end

  def test_allowed_hosts_parses_comma_separated_environment
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.a.test,git.b.test , git.c.test') do
      assert_equal ['git.a.test', 'git.b.test', 'git.c.test'], RedmineGitMirror::Config.allowed_hosts
    end
  end

  def test_mirror_root_defaults_to_redmine_path
    assert_equal '/var/lib/redmine/repositories', RedmineGitMirror::Config.mirror_root
  end

  def test_mirror_root_reads_environment
    with_env('REDMINE_GIT_MIRROR_ROOT' => '/srv/mirrors') do
      assert_equal '/srv/mirrors', RedmineGitMirror::Config.mirror_root
    end
  end

  def test_command_timeout_defaults_to_600_seconds
    assert_equal 600, RedmineGitMirror::Config.command_timeout
  end

  def test_command_timeout_reads_environment
    with_env('REDMINE_GIT_MIRROR_TIMEOUT' => '120') do
      assert_equal 120, RedmineGitMirror::Config.command_timeout
    end
  end

  def test_command_timeout_falls_back_to_default_for_invalid_input
    with_env('REDMINE_GIT_MIRROR_TIMEOUT' => 'not-a-number') do
      assert_equal 600, RedmineGitMirror::Config.command_timeout
    end
  end

  def test_secure_compare_accepts_matching_keys
    assert RedmineGitMirror::Config.secure_compare('abc123', 'abc123')
  end

  def test_secure_compare_rejects_non_matching_keys
    refute RedmineGitMirror::Config.secure_compare('abc123', 'abc124')
    refute RedmineGitMirror::Config.secure_compare('abc123', 'abcdef')
  end

  def test_secure_compare_rejects_blank_provided_key
    refute RedmineGitMirror::Config.secure_compare('', 'abc123')
    refute RedmineGitMirror::Config.secure_compare(nil, 'abc123')
  end

  def test_secure_compare_rejects_blank_expected_key
    refute RedmineGitMirror::Config.secure_compare('abc123', '')
    refute RedmineGitMirror::Config.secure_compare('abc123', nil)
  end
end

# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)

# Exercises the controller's authentication contract without booting Redmine.
# Loads the controller source directly and runs the authenticate! method in a
# minimal ActionController stub. The full request/response cycle is covered
# inside Redmine's test environment via `rake redmine:plugins:test`.
class RedmineGitMirrorAuthenticatorTest < Minitest::Test
  def teardown
    reset_env!
  end

  def test_authenticates_when_provided_key_matches
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'secret-key') do
      assert RedmineGitMirror::Authenticator.authenticated?('secret-key')
    end
  end

  def test_rejects_when_provided_key_is_blank
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'secret-key') do
      refute RedmineGitMirror::Authenticator.authenticated?(nil)
      refute RedmineGitMirror::Authenticator.authenticated?('')
    end
  end

  def test_rejects_when_expected_key_is_blank
    with_env('REDMINE_GIT_MIRROR_API_KEY' => '') do
      refute RedmineGitMirror::Authenticator.authenticated?('something')
    end
  end

  def test_rejects_when_keys_differ
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'secret-key') do
      refute RedmineGitMirror::Authenticator.authenticated?('Secret-key')
      refute RedmineGitMirror::Authenticator.authenticated?('other')
      refute RedmineGitMirror::Authenticator.authenticated?('secret-keyx')
    end
  end

  def test_authenticator_never_includes_key_in_returned_value
    with_env('REDMINE_GIT_MIRROR_API_KEY' => 'very-secret-value') do
      result = RedmineGitMirror::Authenticator.authenticated?('very-secret-value')
      assert_includes [true, false], result
      refute_equal 'very-secret-value', result
    end
  end
end

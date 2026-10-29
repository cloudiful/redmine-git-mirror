# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)

class RedmineGitMirrorUrlValidatorTest < Minitest::Test
  ALLOWED = ['git.example.com'].freeze

  def teardown
    reset_env!
  end

  def test_accepts_https_url_with_owner_repo
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'git.example.com', result.parsed.host
    assert_equal 'acme', result.parsed.owner
    assert_equal 'widgets', result.parsed.repo
    assert_equal 'https', result.parsed.scheme
  end

  def test_accepts_https_url_without_dot_git_suffix
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/widgets',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'widgets', result.parsed.repo
  end

  def test_accepts_scp_style_ssh_url
    result = RedmineGitMirror::UrlValidator.validate(
      'git@git.example.com:acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'git.example.com', result.parsed.host
    assert_equal 'git', result.parsed.user
    assert_equal 'acme', result.parsed.owner
    assert_equal 'widgets', result.parsed.repo
    assert_equal 'git@git.example.com:acme/widgets.git', result.parsed.to_s
  end

  def test_accepts_ssh_scheme_url_and_canonicalizes_to_scp_style
    result = RedmineGitMirror::UrlValidator.validate(
      'ssh://git@git.example.com/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'ssh', result.parsed.scheme
    assert_equal 'git', result.parsed.user
    assert_equal 'git@git.example.com:acme/widgets.git', result.parsed.to_s
  end

  def test_accepts_ssh_url_with_non_default_port_and_retains_it
    url = 'ssh://git@git.example.com:2222/acme/widgets.git'
    result = RedmineGitMirror::UrlValidator.validate(url, allowed_hosts: ALLOWED)
    assert result.ok?, result.error
    assert_equal 2222, result.parsed.port
    assert_equal url, result.parsed.to_s
  end

  def test_ssh_non_default_port_round_trips_through_validate
    url = 'ssh://GIT@Git.Example.Com:2222/Acme/Widgets.GIT'
    first = RedmineGitMirror::UrlValidator.validate(url, allowed_hosts: ALLOWED)
    assert first.ok?, first.error
    second = RedmineGitMirror::UrlValidator.validate(first.parsed.to_s, allowed_hosts: ALLOWED)
    assert second.ok?, second.error
    assert_equal first.parsed.to_s, second.parsed.to_s
    assert_equal 2222, second.parsed.port
    assert_equal 'ssh://git@git.example.com:2222/acme/widgets.git', second.parsed.to_s
  end

  def test_explicit_default_port_canonicalizes_to_scp_style
    result = RedmineGitMirror::UrlValidator.validate(
      'ssh://git@git.example.com:22/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'git@git.example.com:acme/widgets.git', result.parsed.to_s
  end

  def test_port_bearing_url_keeps_identifier_and_relative_path
    result = RedmineGitMirror::UrlValidator.validate(
      'ssh://git@git.example.com:2222/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'acme_widgets', result.parsed.mirror_identifier
    assert_equal 'acme/widgets.git', result.parsed.relative_path
  end

  def test_rejects_out_of_range_ssh_port
    result = RedmineGitMirror::UrlValidator.validate(
      'ssh://git@git.example.com:99999/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/port/i, result.error)
  end

  def test_rejects_invalid_ssh_port_cleanly
    result = RedmineGitMirror::UrlValidator.validate(
      'ssh://git@git.example.com:notaport/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert result.error.is_a?(String)
  end

  def test_ssh_user_is_lowercased_on_canonical_form
    result = RedmineGitMirror::UrlValidator.validate(
      'GIT@git.example.com:acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'git', result.parsed.user
    assert_equal 'git@git.example.com:acme/widgets.git', result.parsed.to_s
  end

  def test_https_user_is_nil_and_canonical_form_has_no_user
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_nil result.parsed.user
    assert_equal 'https://git.example.com/acme/widgets.git', result.parsed.to_s
  end

  def test_ssh_url_round_trips_through_validate
    canonical = 'git@git.example.com:acme/widgets.git'
    first = RedmineGitMirror::UrlValidator.validate(canonical, allowed_hosts: ALLOWED)
    assert first.ok?, first.error
    second = RedmineGitMirror::UrlValidator.validate(first.parsed.to_s, allowed_hosts: ALLOWED)
    assert second.ok?, second.error
    assert_equal first.parsed.to_s, second.parsed.to_s
    assert_equal 'git', second.parsed.user
    assert_equal 'git.example.com', second.parsed.host
  end

  def test_uppercase_https_url_canonicalizes_to_lowercase
    result = RedmineGitMirror::UrlValidator.validate(
      'HTTPS://Git.Example.Com/Acme/Widgets.GIT',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_equal 'https://git.example.com/acme/widgets.git', result.parsed.to_s
  end

  def test_scp_and_ssh_url_forms_canonicalize_to_same_remote_url
    scp = RedmineGitMirror::UrlValidator.validate(
      'git@git.example.com:acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    ssh_form = RedmineGitMirror::UrlValidator.validate(
      'ssh://git@git.example.com/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    assert scp.ok?, scp.error
    assert ssh_form.ok?, ssh_form.error
    assert_equal scp.parsed.to_s, ssh_form.parsed.to_s
  end

  def test_rejects_host_not_in_allow_list
    result = RedmineGitMirror::UrlValidator.validate(
      'https://malicious.example.com/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/not in the allow list/, result.error)
  end

  def test_rejects_embedded_credentials_in_https
    result = RedmineGitMirror::UrlValidator.validate(
      'https://user:pass@git.example.com/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/must not include a username or password/, result.error)
  end

  def test_rejects_query_string
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/widgets.git?ref=main',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/query string/, result.error)
  end

  def test_rejects_fragment
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/widgets.git#fragment',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/fragment/, result.error)
  end

  def test_rejects_path_traversal
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/../etc/passwd',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/forbidden|invalid/, result.error)
  end

  def test_rejects_shell_metacharacters
    [
      'https://git.example.com/acme/widgets;rm -rf.git',
      'https://git.example.com/acme/$(touch pwned).git',
      'https://git.example.com/acme/`id`.git',
      'https://git.example.com/acme/widgets.git|whoami'
    ].each do |bad|
      result = RedmineGitMirror::UrlValidator.validate(bad, allowed_hosts: ALLOWED)
      refute result.ok?, "should reject #{bad.inspect}"
    end
  end

  def test_rejects_unsupported_scheme
    result = RedmineGitMirror::UrlValidator.validate(
      'ftp://git.example.com/acme/widgets.git',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/Unsupported URL scheme/, result.error)
  end

  def test_rejects_url_with_extra_path_segments
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/widgets/extra',
      allowed_hosts: ALLOWED
    )
    refute result.ok?
    assert_match(/owner\/repo/, result.error)
  end

  def test_rejects_blank_url
    result = RedmineGitMirror::UrlValidator.validate('', allowed_hosts: ALLOWED)
    refute result.ok?
    assert_match(/empty/, result.error)
  end

  def test_rejects_when_allow_list_is_empty
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/acme/widgets.git',
      allowed_hosts: []
    )
    refute result.ok?
    assert_match(/allow list is empty/i, result.error)
  end

  def test_uses_environment_allowed_hosts_when_not_overridden
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.example.org,git.evil.example.org') do
      result = RedmineGitMirror::UrlValidator.validate(
        'https://git.example.org/acme/widgets.git'
      )
      assert result.ok?, result.error
    end
  end

  def test_parsed_identifier_is_safe_for_redmine
    result = RedmineGitMirror::UrlValidator.validate(
      'https://git.example.com/Acme_Org/Some-Repo.git',
      allowed_hosts: ALLOWED
    )
    assert result.ok?, result.error
    assert_match(/\A(?!\d+$)[a-z0-9\-_]*\z/, result.parsed.mirror_identifier)
    assert_equal 'acme_org_some-repo', result.parsed.mirror_identifier
  end
end

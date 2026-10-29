# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)

class RedmineGitMirrorModelTest < Minitest::Test
  def setup
    skip_unless_active_record!
    RedmineGitMirror::Mirror.delete_all
  end

  def teardown
    if defined?(RedmineGitMirror::Mirror) && RedmineGitMirror::Mirror.table_exists?
      RedmineGitMirror::Mirror.delete_all
    end
    reset_env!
  end

  def test_remote_url_is_canonicalized_on_save
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.example.com') do
      mirror = RedmineGitMirror::Mirror.new(
        project_id: 7,
        remote_url: 'HTTPS://Git.Example.Com/Acme/Widgets.GIT',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets',
        status: 'pending'
      )
      assert mirror.save, mirror.errors.full_messages.join(', ')
      assert_equal 'https://git.example.com/acme/widgets.git', mirror.remote_url
    end
  end

  def test_remote_url_lowercases_ssh_user
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.example.com') do
      mirror = RedmineGitMirror::Mirror.new(
        project_id: 7,
        remote_url: 'Git@Git.Example.Com:Acme/Widgets.git',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets',
        status: 'pending'
      )
      assert mirror.save, mirror.errors.full_messages.join(', ')
      assert_equal 'git@git.example.com:acme/widgets.git', mirror.remote_url
    end
  end

  def test_two_urls_with_same_canonical_form_are_rejected_as_duplicates
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.example.com') do
      RedmineGitMirror::Mirror.create!(
        project_id: 7,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets_first',
        status: 'pending'
      )

      duplicate = RedmineGitMirror::Mirror.new(
        project_id: 7,
        remote_url: 'HTTPS://Git.Example.Com/Acme/Widgets.GIT',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets_second',
        status: 'pending'
      )

      refute duplicate.save, 'expected canonical duplicate to be rejected'
      assert_includes duplicate.errors[:remote_url].join(' '), 'taken'
    end
  end

  def test_ssh_scp_and_ssh_scheme_forms_canonicalize_to_same_url
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.example.com') do
      scp = RedmineGitMirror::Mirror.create!(
        project_id: 7,
        remote_url: 'git@git.example.com:acme/widgets.git',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets',
        status: 'pending'
      )
      assert_equal 'git@git.example.com:acme/widgets.git', scp.remote_url

      ssh_form = RedmineGitMirror::Mirror.new(
        project_id: 7,
        remote_url: 'ssh://git@git.example.com/acme/widgets.git',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets_other',
        status: 'pending'
      )
      refute ssh_form.save, 'expected ssh:// form to canonicalize to scp-style and be rejected as duplicate'
    end
  end

  def test_remote_url_validation_is_case_sensitive_after_canonicalization
    with_env('REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => 'git.example.com') do
      first = RedmineGitMirror::Mirror.create!(
        project_id: 7,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets',
        status: 'pending'
      )
      # Even a manual "different case" canonical form should be rejected
      # once normalized; the case_sensitive index has already been kept in
      # sync with the canonical form.
      second = RedmineGitMirror::Mirror.new(
        project_id: 7,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: '/var/lib/redmine/repositories/7/acme__widgets.git',
        identifier: 'mirror_7_acme_widgets_other',
        status: 'pending'
      )
      refute second.valid?
      assert_includes second.errors[:remote_url].join(' '), 'taken'
      assert first.persisted?
    end
  end

  private

  def skip_unless_active_record!
    return if defined?(RedmineGitMirror::Mirror) && RedmineGitMirror::Mirror.table_exists?

    skip 'ActiveRecord schema not available in this environment'
  end
end

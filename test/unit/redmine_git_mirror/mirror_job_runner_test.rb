# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)
require 'ostruct'
require 'tmpdir'
require 'fileutils'

class RedmineGitMirrorMirrorJobRunnerTest < Minitest::Test
  def setup
    skip_unless_active_record!
    RedmineGitMirror::Mirror.delete_all
    Project.store = nil
    Project.stub_record(42, identifier: 'my-project')
    ENV['REDMINE_GIT_MIRROR_ALLOWED_HOSTS'] = 'git.example.com'
    @tmpdir = Dir.mktmpdir('redmine-git-mirror-job-runner-test')
  end

  def teardown
    if defined?(RedmineGitMirror::Mirror) && RedmineGitMirror::Mirror.table_exists?
      RedmineGitMirror::Mirror.delete_all
    end
    Project.store = nil
    reset_env!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  # The job runner re-raises after persisting 'failed' so Sidekiq can
  # apply its own retry policy. This test exercises the actual lock
  # path with a failing command runner and asserts the failure state is
  # visible to a fresh database read.
  def test_failing_clone_persists_failed_state_outside_the_rolled_back_lock
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      mirror = RedmineGitMirror::Mirror.create!(
        project_id: 42,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: File.join(@tmpdir, '42', 'acme__widgets.git'),
        identifier: 'mirror_42_acme_widgets',
        status: 'pending'
      )

      runner = RedmineGitMirror::MirrorJobRunner.new(
        mirror_class: RedmineGitMirror::Mirror,
        service_class: failing_service_class(message: 'fatal: unable to clone')
      )

      # The runner must re-raise so Sidekiq sees the failure and can retry.
      err = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
        runner.perform(mirror.id)
      end
      assert_match(/unable to clone/, err.message)

      # A fresh database read (no in-memory transaction state) must show
      # the persisted failure. The with_lock transaction would have
      # rolled back any 'failed' save the service attempted; this proves
      # the runner recorded it outside the lock.
      reloaded = RedmineGitMirror::Mirror.find(mirror.id)
      assert_equal 'failed', reloaded.status
      assert_match(/unable to clone/, reloaded.error_message.to_s)
    end
  end

  def test_failing_fetch_persists_failed_state_outside_the_rolled_back_lock
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      mirror_root = @tmpdir
      local_path = File.join(mirror_root, '42', 'acme__widgets.git')
      FileUtils.mkdir_p(File.join(local_path, 'refs', 'heads'))
      File.write(File.join(local_path, 'HEAD'), "ref: refs/heads/main\n")
      File.write(File.join(local_path, 'refs', 'heads', 'main'),
                 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n")

      mirror = RedmineGitMirror::Mirror.create!(
        project_id: 42,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: local_path,
        identifier: 'mirror_42_acme_widgets',
        status: 'ready'
      )

      runner = RedmineGitMirror::MirrorJobRunner.new(
        mirror_class: RedmineGitMirror::Mirror,
        service_class: failing_service_class(message: 'fatal: unable to fetch')
      )

      assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
        runner.perform(mirror.id)
      end

      reloaded = RedmineGitMirror::Mirror.find(mirror.id)
      assert_equal 'failed', reloaded.status
      assert_match(/unable to fetch/, reloaded.error_message.to_s)
    end
  end

  def test_successful_clone_persists_ready_state
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      mirror = RedmineGitMirror::Mirror.create!(
        project_id: 42,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: File.join(@tmpdir, '42', 'acme__widgets.git'),
        identifier: 'mirror_42_acme_widgets',
        status: 'pending'
      )

      runner = RedmineGitMirror::MirrorJobRunner.new(
        mirror_class: RedmineGitMirror::Mirror,
        service_class: stub_service_class
      )

      runner.perform(mirror.id)

      reloaded = RedmineGitMirror::Mirror.find(mirror.id)
      assert_equal 'ready', reloaded.status
      assert_nil reloaded.error_message
    end
  end

  def test_missing_mirror_returns_silently
    runner = RedmineGitMirror::MirrorJobRunner.new(
      mirror_class: RedmineGitMirror::Mirror,
      service_class: stub_service_class
    )
    # Should not raise; missing mirror is a no-op for the worker.
    assert_nil runner.perform(99_999_999)
  end

  private

  def skip_unless_active_record!
    return if defined?(RedmineGitMirror::Mirror) && RedmineGitMirror::Mirror.table_exists?

    skip 'ActiveRecord schema not available in this environment'
  end

  # A service class whose perform_clone / perform_fetch always raise
  # CommandFailed. The runner's job is to capture that failure outside
  # the lock transaction.
  def failing_service_class(message:)
    Class.new do
      define_method(:perform_clone) do |_mirror|
        raise RedmineGitMirror::CommandRunner::CommandFailed.new(message, nil)
      end

      define_method(:perform_fetch) do |_mirror|
        raise RedmineGitMirror::CommandRunner::CommandFailed.new(message, nil)
      end
    end
  end

  # A service class that pretends to clone and fetch successfully.
  def stub_service_class
    Class.new do
      define_method(:perform_clone) do |mirror|
        mirror.update_columns(status: 'ready', error_message: nil, updated_at: Time.now.utc)
      end

      define_method(:perform_fetch) do |mirror|
        mirror.update_columns(status: 'ready', error_message: nil, updated_at: Time.now.utc)
      end
    end
  end
end

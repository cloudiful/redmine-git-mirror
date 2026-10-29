# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)
require 'ostruct'
require 'tmpdir'
require 'fileutils'

class RedmineGitMirrorMirrorServiceTest < Minitest::Test
  def setup
    skip_unless_active_record!
    RedmineGitMirror::Mirror.delete_all
    Project.store = nil
    Project.stub_record(42, identifier: 'my-project')
    ENV['REDMINE_GIT_MIRROR_ALLOWED_HOSTS'] = 'git.example.com'
    @tmpdir = Dir.mktmpdir('redmine-git-mirror-test')
  end

  def teardown
    if defined?(RedmineGitMirror::Mirror) && RedmineGitMirror::Mirror.table_exists?
      RedmineGitMirror::Mirror.delete_all
    end
    Project.store = nil
    reset_env!
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.directory?(@tmpdir)
  end

  def test_register_creates_mirror_with_pending_status
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      mirror = service.register(
        project: stub_project,
        raw_url: 'https://git.example.com/acme/widgets.git'
      )

      assert_equal 42, mirror.project_id
      assert_equal 'pending', mirror.status
      assert_match(%r{\A#{Regexp.escape(@tmpdir)}/42/acme__widgets\.git\z}, mirror.local_path)
      refute_nil mirror.identifier
    end
  end

  def test_register_rejects_url_outside_allow_list
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      error = assert_raises(ArgumentError) do
        service.register(
          project: stub_project,
          raw_url: 'https://malicious.example.com/acme/widgets.git'
        )
      end
      assert_match(/allow list/, error.message)
    end
  end

  def test_register_fails_closed_when_no_hosts_are_configured
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir, 'REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => '') do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      error = assert_raises(ArgumentError) do
        service.register(
          project: stub_project,
          raw_url: 'https://git.example.com/acme/widgets.git'
        )
      end
      assert_match(/allow list is empty/i, error.message)
    end
  end

  def test_queued_fetch_runs_before_post_fetch_validation_with_no_hosts
    mirror = RedmineGitMirror::Mirror.create!(
      project_id: 42,
      remote_url: 'https://git.example.com/acme/widgets.git',
      local_path: File.join(@tmpdir, '42', 'acme__widgets.git'),
      identifier: 'mirror_42_acme_widgets',
      status: 'pending'
    )
    fetched = []
    runner = stub_runner(success: true)
    original_fetch = runner.method(:fetch)
    runner.define_singleton_method(:fetch) do |path|
      fetched << path
      original_fetch.call(path)
    end

    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir, 'REDMINE_GIT_MIRROR_ALLOWED_HOSTS' => '') do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: runner,
        repository_registrar: stub_registrar
      )

      error = assert_raises(RedmineGitMirror::MirrorService::InvalidStoredRemoteUrl) do
        service.perform_fetch(mirror)
      end
      assert_match(/not valid/, error.message)
    end

    assert_equal [mirror.local_path], fetched
    assert_equal 'failed', mirror.reload.status
  end

  def test_register_computes_path_inside_root
    with_env('REDMINE_GIT_MIRROR_ROOT' => '/srv/mirrors') do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      mirror = service.register(
        project: stub_project,
        raw_url: 'git@git.example.com:acme/widgets.git'
      )

      assert_match(%r{\A/srv/mirrors/42/acme__widgets\.git\z}, mirror.local_path)
      assert File.expand_path(mirror.local_path).start_with?(File.expand_path('/srv/mirrors') + '/')
    end
  end

  def test_perform_clone_transitions_to_ready_and_registers_repo
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      transitions = []
      registrar = Class.new do
        define_method(:upsert) do |project:, parsed:, local_path:, identifier: nil|
          Struct.new(:project, :local_path, :identifier).new(project, local_path, identifier || parsed.mirror_identifier)
        end
      end.new
      runner = stub_runner(success: true)

      service = RedmineGitMirror::MirrorService.new(
        command_runner: runner,
        repository_registrar: registrar
      )

      mirror = service.register(
        project: stub_project,
        raw_url: 'https://git.example.com/acme/widgets.git'
      )
      transitions << mirror.status

      # Wrap the mirror so we observe each transition inside the
      # service. `register` already wrote 'pending'; `perform_clone`
      # should write 'cloning' and then 'ready' before returning.
      original_save = mirror.method(:save!)
      mirror.define_singleton_method(:save!) do
        transitions << status
        original_save.call
      end

      service.perform_clone(mirror)

      mirror.reload
      assert_equal 'ready', mirror.status
      assert_nil mirror.error_message
      assert_includes transitions, 'pending'
      assert_includes transitions, 'cloning'
      assert_includes transitions, 'ready'
    end
  end

  def test_perform_clone_records_failure_and_keeps_status_failed
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      runner = stub_runner(success: false, message: 'unable to clone')
      service = RedmineGitMirror::MirrorService.new(
        command_runner: runner,
        repository_registrar: stub_registrar
      )

      mirror = service.register(
        project: stub_project,
        raw_url: 'https://git.example.com/acme/widgets.git'
      )

      assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
        service.perform_clone(mirror)
      end

      mirror.reload
      assert_equal 'failed', mirror.status
      assert_match(/unable to clone/, mirror.error_message)
    end
  end

  def test_perform_fetch_failure_keeps_status_failed_without_deleting_mirror
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      mirror_root = @tmpdir
      local_path = File.join(mirror_root, '42', 'acme__widgets.git')
      # Create a representative ready-mirror directory layout on disk:
      # <local>/HEAD, <local>/refs/heads/main, <local>/packed-refs.
      FileUtils.mkdir_p(File.join(local_path, 'refs', 'heads'))
      FileUtils.mkdir_p(File.join(local_path, 'refs', 'tags'))
      head_content = "ref: refs/heads/main\n"
      File.write(File.join(local_path, 'HEAD'), head_content)
      File.write(File.join(local_path, 'refs', 'heads', 'main'),
                 "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n")
      File.write(File.join(local_path, 'packed-refs'), '')
      head_before = File.read(File.join(local_path, 'HEAD'))
      ref_before = File.read(File.join(local_path, 'refs', 'heads', 'main'))

      existing_mirror = RedmineGitMirror::Mirror.create!(
        project_id: 42,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: local_path,
        identifier: 'mirror_42_acme_widgets',
        status: 'ready'
      )

      runner = stub_runner(success: false, message: 'fetch failed')
      service = RedmineGitMirror::MirrorService.new(
        command_runner: runner,
        repository_registrar: stub_registrar
      )

      assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
        service.perform_fetch(existing_mirror)
      end

      existing_mirror.reload
      assert_equal 'failed', existing_mirror.status
      refute_nil existing_mirror.error_message
      # Mirror directory and its refs must remain on disk; fetch failure
      # does not delete a previously healthy mirror.
      assert File.directory?(local_path), 'mirror directory should remain'
      assert File.directory?(File.join(local_path, 'refs', 'heads')),
             'refs/heads should remain'
      assert File.exist?(File.join(local_path, 'HEAD')), 'HEAD should remain'
      assert File.exist?(File.join(local_path, 'refs', 'heads', 'main')),
             'refs/heads/main should remain'
      assert_equal head_before, File.read(File.join(local_path, 'HEAD'))
      assert_equal ref_before, File.read(File.join(local_path, 'refs', 'heads', 'main'))
    end
  end

  def test_register_returns_existing_mirror_for_same_deterministic_identity
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      first = service.register(
        project: stub_project,
        raw_url: 'https://git.example.com/acme/widgets.git'
      )
      second = service.register(
        project: stub_project,
        raw_url: 'https://git.example.com/acme/widgets.git'
      )

      assert_equal first.id, second.id
      assert_equal first.identifier, second.identifier
      assert_equal first.local_path, second.local_path
    end
  end

  def test_register_preserves_ssh_user_in_stored_remote_url
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      mirror = service.register(
        project: stub_project,
        raw_url: 'git@git.example.com:acme/widgets.git'
      )

      assert_equal 'git@git.example.com:acme/widgets.git', mirror.remote_url

      # The stored remote_url must round-trip through UrlValidator and
      # yield the same ParsedUrl so that perform_clone can revalidate it.
      result = RedmineGitMirror::UrlValidator.validate(mirror.remote_url)
      assert result.ok?, result.error
      assert_equal 'git', result.parsed.user
      assert_equal 'git.example.com', result.parsed.host
      assert_equal 'acme', result.parsed.owner
      assert_equal 'widgets', result.parsed.repo
    end
  end

  def test_register_native_repository_raises_on_corrupt_remote_url
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      existing_mirror = RedmineGitMirror::Mirror.create!(
        project_id: 42,
        remote_url: 'git@git.example.com:acme/widgets.git',
        local_path: File.join(@tmpdir, '42', 'acme__widgets.git'),
        identifier: 'mirror_42_acme_widgets',
        status: 'ready'
      )

      # Simulate corruption (e.g. a manual SQL update) so that
      # revalidation produces a nil parsed. The service must surface
      # this instead of silently passing nil to the registrar.
      existing_mirror.update_column(:remote_url, 'not a valid url')

      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      assert_raises(RedmineGitMirror::MirrorService::InvalidStoredRemoteUrl) do
        service.send(:register_native_repository, existing_mirror)
      end
    end
  end

  def test_register_native_repository_uses_canonical_parsed_for_ssh
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      captured = []
      registrar = Class.new do
        define_method(:upsert) do |project:, parsed:, local_path:, identifier: nil|
          captured << parsed
          Struct.new(:project, :local_path, :identifier).new(project, local_path, identifier || parsed.mirror_identifier)
        end
      end.new

      existing_mirror = RedmineGitMirror::Mirror.create!(
        project_id: 42,
        remote_url: 'git@git.example.com:acme/widgets.git',
        local_path: File.join(@tmpdir, '42', 'acme__widgets.git'),
        identifier: 'mirror_42_acme_widgets',
        status: 'ready'
      )

      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: registrar
      )

      service.send(:register_native_repository, existing_mirror)

      assert_equal 1, captured.size
      parsed = captured.first
      refute_nil parsed
      assert_equal 'git', parsed.user
      assert_equal 'git.example.com', parsed.host
      assert_equal 'acme', parsed.owner
      assert_equal 'widgets', parsed.repo
    end
  end

  def test_status_payload_does_not_include_secrets
    with_env('REDMINE_GIT_MIRROR_ROOT' => @tmpdir) do
      service = RedmineGitMirror::MirrorService.new(
        command_runner: stub_runner(success: true),
        repository_registrar: stub_registrar
      )

      mirror = service.register(
        project: stub_project,
        raw_url: 'https://git.example.com/acme/widgets.git'
      )
      payload = service.status_payload(mirror)

      refute payload.key?(:api_key)
      refute payload.key?(:password)
      refute payload.key?(:token)
      payload.each_value do |v|
        if v.is_a?(String)
          refute_match(/REDMINE_GIT_MIRROR_API_KEY/, v)
        end
      end
    end
  end

  private

  def skip_unless_active_record!
    return if defined?(RedmineGitMirror::Mirror) && RedmineGitMirror::Mirror.table_exists?

    skip 'ActiveRecord schema not available in this environment'
  end

  def stub_project
    Project.find(42)
  end

  def stub_runner(success:, message: '')
    runner = RedmineGitMirror::CommandRunner.new(timeout: 1)
    runner.define_singleton_method(:clone) do |remote_url, target_path|
      raise RedmineGitMirror::CommandRunner::CommandFailed.new(message, nil) unless success

      RedmineGitMirror::CommandRunner::Result.new(
        status: OpenStruct.new(success?: true),
        stdout: '',
        stderr: '',
        timed_out: false
      )
    end
    runner.define_singleton_method(:fetch) do |repo_path|
      raise RedmineGitMirror::CommandRunner::CommandFailed.new(message, nil) unless success

      RedmineGitMirror::CommandRunner::Result.new(
        status: OpenStruct.new(success?: true),
        stdout: '',
        stderr: '',
        timed_out: false
      )
    end
    runner
  end

  def stub_registrar
    Class.new do
      define_method(:upsert) do |project:, parsed:, local_path:, identifier: nil|
        Struct.new(:project, :local_path, :identifier).new(project, local_path, identifier || parsed.mirror_identifier)
      end
    end.new
  end
end

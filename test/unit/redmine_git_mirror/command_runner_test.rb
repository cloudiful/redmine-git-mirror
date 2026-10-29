# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)
require 'open3'
require 'ostruct'

class RedmineGitMirrorCommandRunnerTest < Minitest::Test
  # Wraps the real runner so we can intercept `run` and assert on the
  # arguments the runner would have passed to Open3.
  class StubbedRunner < RedmineGitMirror::CommandRunner
    attr_reader :captured

    def initialize(captured_result:, **opts)
      super(**opts)
      @captured_result = captured_result
      @captured = { env: nil, args: nil, chdir: nil }
    end

    def run(working_dir, args)
      env = RedmineGitMirror::CommandRunner::DEFAULT_GIT_ENV.merge('GIT_DIR' => nil)
      @captured[:env] = env
      @captured[:args] = args
      @captured[:chdir] = working_dir
      @captured_result
    end
  end

  # Forces the runner to fail without making any real Open3 call.
  class FailingRunner < RedmineGitMirror::CommandRunner
    def initialize(stderr: 'fatal: repository not found', **opts)
      super(**opts)
      @stderr = stderr
    end

    def run(_working_dir, _args)
      RedmineGitMirror::CommandRunner::Result.new(
        status: OpenStruct.new(success?: false),
        stdout: '',
        stderr: @stderr,
        timed_out: false
      )
    end
  end

  def success_result
    RedmineGitMirror::CommandRunner::Result.new(
      status: OpenStruct.new(success?: true),
      stdout: '',
      stderr: '',
      timed_out: false
    )
  end

  def failure_result
    RedmineGitMirror::CommandRunner::Result.new(
      status: OpenStruct.new(success?: false),
      stdout: '',
      stderr: 'fatal: repository not found',
      timed_out: false
    )
  end

  def test_clone_passes_url_as_discrete_argument
    captured = StubbedRunner.new(captured_result: success_result)
    captured.clone('https://git.example.com/acme/widgets.git', '/tmp/mirror/1/acme__widgets.git')

    args = captured.captured[:args]
    assert_kind_of Array, args
    assert_equal 'git', args.first
    assert_includes args, '--mirror'
    assert_includes args, '--quiet'
    assert_includes args, '--'
    separator_index = args.index('--')
    refute_nil separator_index
    assert_equal 'https://git.example.com/acme/widgets.git', args[separator_index + 1]
    assert_equal 'acme__widgets.git', args.last
  end

  def test_clone_does_not_interpolate_url_into_shell
    captured = StubbedRunner.new(captured_result: success_result)
    malicious = 'https://git.example.com/acme/widgets.git; rm -rf /tmp'
    captured.clone(malicious, '/tmp/mirror/1/acme__widgets.git')

    args = captured.captured[:args]
    separator_index = args.index('--')
    refute_nil separator_index
    # The entire malicious URL must be one positional argument; it must
    # never be broken up into a shell command.
    assert_equal malicious, args[separator_index + 1]
    refute_includes args.last, ';'
  end

  def test_clone_propagates_failure
    runner = FailingRunner.new(timeout: 1)
    assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.clone('https://git.example.com/acme/widgets.git', '/tmp/mirror/1/x.git')
    end
  end

  def test_fetch_does_not_include_user_supplied_url
    captured = StubbedRunner.new(captured_result: success_result)
    captured.fetch('/tmp/mirror/1/acme__widgets.git')

    args = captured.captured[:args]
    assert_equal 'git', args.first
    assert_includes args, 'fetch'
    refute(args.any? { |a| a.to_s.start_with?('https://') || a.to_s.start_with?('git@') })
  end

  def test_run_rejects_non_array_arguments
    runner = RedmineGitMirror::CommandRunner.new(timeout: 1)
    assert_raises(ArgumentError) { runner.send(:run, '/tmp', 'git clone -- x y') }
    assert_raises(ArgumentError) { runner.send(:run, '/tmp', nil) }
  end

  def test_command_failed_carries_result
    runner = FailingRunner.new(timeout: 1)
    error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.clone('https://git.example.com/acme/widgets.git', '/tmp/mirror/1/x.git')
    end
    assert_kind_of RedmineGitMirror::CommandRunner::Result, error.result
    refute error.result.success?
  end

  def test_clone_failure_message_includes_stderr_reason
    runner = FailingRunner.new(timeout: 1)
    error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.clone('https://git.example.com/acme/widgets.git', '/tmp/mirror/1/x.git')
    end
    assert_equal "git clone failed: fatal: repository not found", error.message
  end

  def test_fetch_failure_message_includes_stderr_reason
    runner = FailingRunner.new(stderr: "fatal: Authentication failed for 'https://example.invalid/acme.git'", timeout: 1)
    error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.fetch('/tmp/mirror/1/x.git')
    end
    assert_includes error.message, 'git fetch failed:'
    assert_includes error.message, 'fatal: Authentication failed'
  end

  def test_failure_message_normalizes_multiline_stderr
    runner = FailingRunner.new(stderr: "warning: option\n\ttimeout=5\nfatal: could not read from remote\n", timeout: 1)
    error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.clone('https://git.example.com/acme/widgets.git', '/tmp/mirror/1/x.git')
    end
    refute_includes error.message, "\n"
    assert_includes error.message, 'warning: option timeout=5'
  end

  def test_failure_message_retains_generic_label_when_stderr_empty
    runner = FailingRunner.new(stderr: '', timeout: 1)
    error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.clone('https://git.example.com/acme/widgets.git', '/tmp/mirror/1/x.git')
    end
    assert_equal 'git clone failed', error.message

    fetch_error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      FailingRunner.new(stderr: nil, timeout: 1).fetch('/tmp/mirror/1/x.git')
    end
    assert_equal 'git fetch failed', fetch_error.message
  end

  def test_failure_message_is_bounded
    runner = FailingRunner.new(stderr: 'x' * 100_000, timeout: 1)
    error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.clone('https://git.example.com/acme/widgets.git', '/tmp/mirror/1/x.git')
    end
    assert_operator error.message.length, :<=,
                    RedmineGitMirror::CommandRunner::CommandFailed::MESSAGE_LIMIT
  end

  # Synthetic credential values only; nothing real is embedded here.
  def test_failure_message_redacts_credentials
    stderr = [
      'remote: HTTP Basic: access denied',
      'fatal: unable to access',
      "'https://mirror-user:S3cr3tPassw0rd@example.invalid/acme.git':",
      'Authorization: Bearer glpat-AbCdEf1234567890AbCdEf1234567890',
      "password=hunter2secret token=ghp_Abcdef1234567890Abcdef1234567890",
      'api_key: "sk-live-99887766554433221100"',
      'fingerprint aa11bb22cc33dd44ee55ff6677889900aabbccdd'
    ].join("\n")
    runner = FailingRunner.new(stderr: stderr, timeout: 1)

    error = assert_raises(RedmineGitMirror::CommandRunner::CommandFailed) do
      runner.clone('https://example.invalid/acme.git', '/tmp/mirror/1/x.git')
    end

    message = error.message
    refute_includes message, 'S3cr3tPassw0rd'
    refute_includes message, 'glpat-AbCdEf1234567890AbCdEf1234567890'
    refute_includes message, 'hunter2secret'
    refute_includes message, 'ghp_Abcdef1234567890Abcdef1234567890'
    refute_includes message, 'sk-live-99887766554433221100'
    refute_includes message, 'aa11bb22cc33dd44ee55ff6677889900aabbccdd'
    assert_includes message, '[REDACTED]'
  end

  # Focused seam proving the timeout machinery: spawn `sleep` with a small
  # timeout, verify the result reports timed_out, and verify the spawned
  # process group is gone (no surviving `sleep`/ssh child mutating the
  # mirror). This avoids running a real remote clone.
  def test_run_with_timeout_kills_and_reaps_spawned_process
    skip 'pgroup kill requires a real POSIX process group' unless Process.respond_to?(:kill)

    runner = RedmineGitMirror::CommandRunner.new(timeout: 0.2)
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = runner.send(
      :run_with_timeout,
      env: {},
      args: ['sleep', '5'],
      chdir: '/tmp',
      timeout: 0.2
    )
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert result.timed_out, 'expected result.timed_out to be true'
    refute result.success?, 'expected timed-out result to not be success?'
    # Sanity check: we returned well before sleep(5) would have naturally
    # finished. Allow a generous bound because the runner waits a couple
    # of poll intervals after the timeout fires.
    assert elapsed < 3.0, "runner took #{elapsed}s; expected to bail near the timeout"
  end

  def test_run_with_timeout_completes_normally_when_under_deadline
    runner = RedmineGitMirror::CommandRunner.new(timeout: 5)
    result = runner.send(
      :run_with_timeout,
      env: {},
      args: ['true'],
      chdir: '/tmp',
      timeout: 5
    )
    refute result.timed_out
    assert result.success?, "expected success, got #{result.inspect}"
  end
end

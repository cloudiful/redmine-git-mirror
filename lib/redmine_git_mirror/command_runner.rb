# frozen_string_literal: true

require 'open3'

module RedmineGitMirror
  # Wraps Open3 with argument arrays and a bounded, process-aware timeout.
  # The command arguments are passed as a discrete array so the user-supplied
  # remote URL is never interpolated into a shell string.
  #
  # On timeout we:
  #   1. Send SIGTERM to the spawned process group (negative pid) so any
  #      descendant `git`/`ssh` child processes are signalled, not just
  #      the immediate `git` process.
  #   2. Wait briefly for the group to exit; if it survives, escalate to
  #      SIGKILL.
  #   3. Reap the process so no zombie is left behind.
  #   4. Drain/close stdin/stdout/stderr to release file descriptors.
  class CommandRunner
    Result = Struct.new(:status, :stdout, :stderr, :timed_out, keyword_init: true) do
      def success?
        !timed_out && status&.success?
      end
    end

    class CommandFailed < StandardError
      attr_reader :result

      # Hard ceiling on the full exception message so Sidekiq logs and the
      # mirror API can never receive unbounded git/ssh output.
      MESSAGE_LIMIT = 2048

      REDACTED = '[REDACTED]'
      private_constant :REDACTED

      def initialize(label, result)
        @result = result
        super(build_message(label, result))
      end

      def build_message(label, result)
        budget = MESSAGE_LIMIT - label.length - 2
        detail = sanitize_stderr(result&.stderr, budget)
        return label if detail.empty?

        "#{label}: #{detail}"
      end
      private :build_message

      # Normalizes whitespace for single-line logging, defensively redacts
      # credential-bearing fragments (the URL validator rejects embedded
      # credentials up front, but git/ssh error text may still echo them),
      # and truncates to the per-message budget.
      def sanitize_stderr(stderr, budget)
        return '' if budget <= 0

        text = redact_credentials(stderr.to_s.scrub)
        text = text.gsub(/\s+/, ' ').strip
        return '' if text.empty?
        return text if text.length <= budget

        "#{text[0, budget - 1]}…"
      end
      private :sanitize_stderr

      def redact_credentials(text)
        text
          # URL userinfo: scheme://user:password@host or scheme://token@host
          .gsub(%r{(\w+://)[^/\s@]+@}, "\\1#{REDACTED}@")
          # Authorization / Proxy-Authorization headers, with or without Bearer.
          .gsub(/((?:proxy-)?authorization\s*:\s*(?:bearer\s+)?)[^\s,;"]+/i, "\\1#{REDACTED}")
          # Common key=value / key: value credential assignments.
          .gsub(
            /\b((?:api[_-]?key|access[_-]?token|auth|key|pass(?:word)?|passwd|pwd|secret|token)\b\s*[=:]\s*)(["']?)\S+\2/i,
            "\\1\\2#{REDACTED}\\2"
          )
          # Bare long hex/base64-ish token values (git object hashes are 40 hex,
          # access tokens are typically longer; 32+ is a safe defensive floor).
          .gsub(/\b[A-Fa-f0-9]{32,}\b/, REDACTED)
          .gsub(/\b[A-Za-z0-9_=-]{64,}\b/, REDACTED)
      end
      private :redact_credentials
    end

    DEFAULT_GIT_ENV = {
      'GIT_TERMINAL_PROMPT' => '0',
      'GIT_ASKPASS' => '/bin/true',
      'LC_ALL' => 'C.UTF-8'
    }.freeze

    def initialize(timeout: nil, env_overrides: {})
      @timeout = (timeout || Config.command_timeout).to_i
      @timeout = 1 if @timeout <= 0
      @env_overrides = env_overrides || {}
    end

    attr_reader :timeout

    # Runs the git command in the given directory. The arguments must be an
    # array of strings and are passed positionally to Open3 so no shell
    # interpolation occurs.
    def run(working_dir, args)
      raise ArgumentError, 'args must be an Array' unless args.is_a?(Array)

      env = DEFAULT_GIT_ENV.merge(@env_overrides)
      run_with_timeout(env: env, args: args, chdir: working_dir, timeout: @timeout)
    end

    def clone(remote_url, target_path)
      result = run(
        File.dirname(target_path),
        [
          'git',
          'clone',
          '--mirror',
          '--quiet',
          '--',
          remote_url.to_s,
          File.basename(target_path)
        ]
      )
      raise CommandFailed.new('git clone failed', result) unless result.success?

      result
    end

    def fetch(repo_path)
      result = run(
        repo_path,
        [
          'git',
          'fetch',
          '--prune',
          '--quiet',
          '--',
          'origin',
          '+refs/heads/*:refs/heads/*',
          '+refs/tags/*:refs/tags/*'
        ]
      )
      raise CommandFailed.new('git fetch failed', result) unless result.success?

      result
    end

    # Internal entry point used by tests to drive the timeout machinery
    # with arbitrary env / args / chdir. Kept public so a focused test
    # can verify kill-and-reap behavior without launching a remote clone.
    def run_with_timeout(env:, args:, chdir:, timeout:)
      stdout_str = +''
      stderr_str = +''
      status = nil
      timed_out = false

      popen_opts = {
        chdir: chdir,
        pgroup: true
      }

      Open3.popen3(env, *args, **popen_opts) do |stdin, stdout, stderr, wait_thr|
        stdin.close

        # Drain output on background threads so the child cannot block on
        # a full pipe buffer. We collect the read so the threads can exit
        # cleanly when the pipes close after we kill the process group.
        stdout_str_local = +''
        stderr_str_local = +''
        stdout_thread = Thread.new { stdout_str_local << stdout.read }
        stderr_thread = Thread.new { stderr_str_local << stderr.read }

        pid = wait_thr.pid
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        poll_interval = 0.05

        loop do
          if wait_thr.join(0).nil?
            # Still running. Check the deadline.
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
              timed_out = true
              terminate_process_group(pid)
              # Wait for the process to actually exit so we can collect
              # the exit status. Bounded so a stuck ssh child cannot
              # hang the worker indefinitely.
              if wait_thr.join(2).nil?
                # Process group still alive; escalate to SIGKILL.
                begin
                  Process.kill('-KILL', pid)
                rescue Errno::ESRCH, Errno::EPERM, RangeError
                  # Already gone; nothing more to do.
                end
              end
              wait_thr.join(5)
              break
            end
            sleep poll_interval
          else
            # wait_thr.join(0) returned non-nil, process exited.
            break
          end
        end

        status = wait_thr.value
        # Close pipes to release FDs even if the child already exited.
        [stdin, stdout, stderr].each do |io|
          io.close unless io.closed?
        rescue IOError, Errno::EPIPE
          nil
        end

        # Threads may still be reading; since pipes are closed they will
        # return promptly with whatever was buffered.
        [stdout_thread, stderr_thread].each do |t|
          t.join(1)
        rescue StandardError
          nil
        end
        stdout_str = stdout_str_local
        stderr_str = stderr_str_local
      end

      Result.new(status: status, stdout: stdout_str, stderr: stderr_str, timed_out: timed_out)
    end

    private

    def terminate_process_group(pid)
      # Negative pid = process group. This is what kills ssh children that
      # git has spawned without each one needing to be tracked.
      Process.kill('-TERM', pid)
    rescue Errno::ESRCH, Errno::EPERM, RangeError
      # Group already gone or no permission; nothing more to do.
      nil
    end
  end
end

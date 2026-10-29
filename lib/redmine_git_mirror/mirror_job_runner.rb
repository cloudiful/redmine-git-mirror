# frozen_string_literal: true

module RedmineGitMirror
  # Encapsulates the per-mirror locked work flow used by
  # MirrorRefreshJob. Pulled out of the job so the lock + failure
  # persistence semantics are testable without booting ActiveJob.
  #
  # Failure persistence deliberately runs outside the row lock: a raised
  # command error inside `mirror.with_lock` rolls back the surrounding
  # transaction, including any `status='failed'` save the service made
  # in its own rescue block. We therefore catch the exception after the
  # block exits and write the failure state with `update_columns`, which
  # runs as its own atomic SQL statement and is not part of any
  # transaction.
  class MirrorJobRunner
    def initialize(mirror_class: RedmineGitMirror::Mirror,
                   service_class: MirrorService)
      @mirror_class = mirror_class
      @service_class = service_class
    end

    def perform(mirror_id)
      mirror = @mirror_class.find_by(id: mirror_id)
      return unless mirror

      run_locked(mirror)
    rescue StandardError => e
      persist_failure_outside_lock(mirror.id, e.message)
      raise
    end

    private

    def run_locked(mirror)
      mirror.with_lock do
        # Re-fetch inside the lock so we always act on the latest
        # committed status. A second worker waiting on the lock will
        # observe the first worker's result via the row.
        fresh = @mirror_class.find(mirror.id)
        service = @service_class.new

        if mirror_already_cloned?(fresh)
          service.perform_fetch(fresh)
        else
          service.perform_clone(fresh)
        end
      end
    end

    def mirror_already_cloned?(mirror)
      return false if mirror.local_path.nil? || mirror.local_path.empty?

      path = mirror.local_path.to_s
      File.directory?(path) && File.directory?(File.join(path, 'refs'))
    end

    def persist_failure_outside_lock(mirror_id, message)
      fresh = @mirror_class.find_by(id: mirror_id)
      return unless fresh

      fresh.update_columns(
        status: 'failed',
        error_message: message.to_s[0, 2000],
        updated_at: current_time
      )
    rescue StandardError
      # Never let failure persistence mask the original error. The
      # original exception is re-raised by the caller; this method is
      # best-effort so the worker still surfaces it to Sidekiq.
      nil
    end

    def current_time
      if defined?(Time) && Time.respond_to?(:current)
        Time.current
      else
        Time.now.utc
      end
    end
  end
end

# frozen_string_literal: true

module RedmineGitMirror
  # Performs the mirror work asynchronously through ActiveJob (Sidekiq).
  # Sidekiq workers receive only the mirror id so the job body is safe to
  # serialize.
  #
  # The actual work runs through MirrorJobRunner so the lock + failure
  # persistence semantics can be exercised in unit tests without booting
  # ActiveJob.
  class MirrorRefreshJob < ActiveJob::Base
    queue_as :default

    def perform(mirror_id)
      MirrorJobRunner.new(mirror_class: RedmineGitMirror::Mirror).perform(mirror_id)
    end
  end
end

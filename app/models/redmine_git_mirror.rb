# frozen_string_literal: true

module RedmineGitMirror
  class Mirror < ApplicationRecord
    self.table_name = 'redmine_git_mirrors'

    STATUSES = %w[pending cloning ready failed].freeze

    belongs_to :project

    # Canonicalization invariant: stored remote_url always round-trips
    # through UrlValidator.validate. UrlValidator canonicalizes scheme,
    # host, user, owner, and repo to lowercase, so two inputs that refer
    # to the same repository serialize identically. With that invariant
    # in place, a case-sensitive uniqueness check is sufficient and
    # matches the underlying database index.
    before_validation :canonicalize_remote_url, if: -> { remote_url.present? }

    validates :project_id, presence: true
    validates :remote_url, presence: true
    validates :local_path, presence: true
    validates :identifier, presence: true,
                          uniqueness: { scope: :project_id, case_sensitive: true },
                          format: { with: /\A(?!\d+$)[a-z0-9\-_]*\z/ }
    validates :status, inclusion: { in: STATUSES }
    validates :remote_url, uniqueness: { scope: :project_id, case_sensitive: true }

    scope :for_project, ->(project_id) { where(project_id: project_id) }

    private

    def canonicalize_remote_url
      parsed = RedmineGitMirror::UrlValidator.canonicalize(remote_url)
      self.remote_url = parsed.to_s if parsed
    end
  end
end

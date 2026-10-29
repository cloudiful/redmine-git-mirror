# frozen_string_literal: true

module RedmineGitMirror
  # Validates the inbound API key without touching the controller framework.
  # Kept separate so the auth contract is testable in isolation and the
  # controller stays free of branching logic.
  class Authenticator
    def self.authenticated?(provided)
      Config.secure_compare(provided.to_s, Config.api_key)
    end
  end
end

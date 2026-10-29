# frozen_string_literal: true

require 'securerandom'

require_relative 'settings_store'

module RedmineGitMirror
  # Reads plugin configuration from saved Redmine plugin settings with
  # legacy environment variables as backwards-compatible fallbacks.
  # Centralized so the controller, the job, the settings UI, and the
  # tests share the same defaults and precedence.
  #
  # Precedence for api_key, allowed_hosts, and mirror_root:
  #   saved plugin setting -> legacy ENV value -> built-in default.
  # A saved (non-blank) UI value always wins over ENV so the settings
  # page stays effective on deployments that still export the old
  # variables. command_timeout remains ENV-only.
  class Config
    # Length in random bytes for generated API keys. 32 bytes (256 bits)
    # encoded with urlsafe_base64 give a 43-character URL-safe key.
    GENERATED_KEY_BYTES = 32

    # Host names are compared case-insensitively by UrlValidator, so
    # saved values are normalized to lowercase on write.
    HOST_PATTERN = /\A[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\z/.freeze

    class << self
      # Test seam: an object responding to `read` (Hash with string
      # keys) and `write(hash)` (true on success). Defaults to the
      # Redmine Setting table; unit tests inject a memory store.
      def settings_store
        @settings_store ||= SettingsStore.new
      end

      attr_writer :settings_store

      def reset_settings_store!
        @settings_store = nil
      end

      def api_key
        saved = stored_value('api_key')
        return saved unless saved.empty?

        ENV[RedmineGitMirror::DEFAULT_API_KEY_ENV].to_s
      end

      def api_key_configured?
        !api_key.empty?
      end

      def allowed_hosts
        saved_list = parse_hosts_list(stored_raw('allowed_hosts'))
        return saved_list unless saved_list.empty?

        raw = ENV[RedmineGitMirror::DEFAULT_ALLOWED_HOSTS_ENV].to_s
        list = parse_hosts_list(raw)
        list.empty? ? RedmineGitMirror::DEFAULT_ALLOWED_HOSTS.dup : list
      end

      def mirror_root
        saved = stored_value('mirror_root')
        return saved unless saved.empty?

        env = ENV[RedmineGitMirror::DEFAULT_MIRROR_ROOT_ENV].to_s.strip
        env.empty? ? RedmineGitMirror::DEFAULT_MIRROR_ROOT : env
      end

      def command_timeout
        raw = ENV[RedmineGitMirror::DEFAULT_TIMEOUT_ENV].to_s.strip
        return RedmineGitMirror::DEFAULT_COMMAND_TIMEOUT if raw.empty?

        Integer(raw, 10)
      rescue ArgumentError
        RedmineGitMirror::DEFAULT_COMMAND_TIMEOUT
      end

      # Returns the effective key, generating and persisting a
      # high-entropy URL-safe key first when nothing is configured
      # (no saved key and no ENV key). Works without any environment
      # variables. Returns '' when persistence is unavailable and no
      # ENV key exists (outside Redmine).
      def ensure_api_key!
        current = api_key
        return current unless current.empty?

        rotate_api_key!
      end

      # Persists a fresh key that differs from the current effective
      # key and returns it. The previous key stops authenticating
      # immediately because reads prefer the saved value. Returns ''
      # when persistence is unavailable.
      def rotate_api_key!
        previous = api_key
        candidate = generate_api_key(previous)
        return '' unless settings_store.write('api_key' => candidate)

        candidate
      end

      def generate_api_key(previous = nil)
        loop do
          candidate = SecureRandom.urlsafe_base64(GENERATED_KEY_BYTES)
          next if candidate.empty?
          next if !previous.nil? && !previous.empty? && candidate == previous

          return candidate
        end
      end

      # Validates raw settings-page input. Returns [values, errors]
      # where values holds the normalized hash to persist and errors
      # holds human-readable messages. Never accepts an api_key field:
      # the key only changes via rotation.
      def validate_settings(input)
        values = {}
        errors = []

        hosts = parse_hosts_list(input['allowed_hosts'] || input[:allowed_hosts])
        if hosts.empty?
          errors << 'Allowed hosts must include at least one host.'
        else
          invalid = hosts.reject { |h| h.match?(HOST_PATTERN) }
          if invalid.empty?
            values['allowed_hosts'] = hosts.join(', ')
          else
            errors << "Allowed hosts contains invalid host names: #{invalid.uniq.join(', ')}."
          end
        end

        root = (input['mirror_root'] || input[:mirror_root]).to_s.strip
        if root.empty?
          errors << 'Mirror root must be an absolute path.'
        elsif !root.start_with?('/')
          errors << 'Mirror root must be an absolute path.'
        elsif root.include?("\0")
          errors << 'Mirror root contains invalid characters.'
        else
          begin
            expanded = File.expand_path(root)
          rescue ArgumentError
            errors << 'Mirror root contains invalid characters.'
          else
            if expanded == '/'
              errors << 'Mirror root must not be the filesystem root.'
            else
              values['mirror_root'] = root
            end
          end
        end

        [values, errors]
      end

      # Merges the given string-keyed values into the persisted plugin
      # settings. Returns true on success, false when persistence is
      # unavailable (outside Redmine).
      def save_settings(values)
        sanitized = values.each_with_object({}) do |(key, value), memo|
          memo[key.to_s] = value.to_s
        end
        settings_store.write(sanitized)
      end

      # Constant-time comparison. Returns false when either side is blank so an
      # unset key never matches an inbound key.
      def secure_compare(provided, expected)
        return false if provided.nil? || provided.empty?
        return false if expected.nil? || expected.empty?

        if defined?(ActiveSupport::SecurityUtils.secure_compare)
          ActiveSupport::SecurityUtils.secure_compare(provided, expected)
        else
          provided_bytes = provided.b
          expected_bytes = expected.b
          return false unless provided_bytes.bytesize == expected_bytes.bytesize

          result = 0
          provided_bytes.each_byte.with_index do |byte, index|
            result |= byte ^ expected_bytes.getbyte(index)
          end
          result.zero?
        end
      end

      private

      # Reads one persisted value as a stripped string. Blank when
      # nothing was saved or the store is unavailable.
      def stored_value(key)
        stored_raw(key).to_s.strip
      rescue StandardError
        ''
      end

      def stored_raw(key)
        raw = settings_store.read
        hash = raw.is_a?(Hash) ? raw : {}
        hash.key?(key.to_s) ? hash[key.to_s] : hash[key.to_sym]
      rescue StandardError
        nil
      end

      # Normalizes a hosts value (String or Array) into a lowercase
      # list. Shared by ENV parsing, saved-value reads, and input
      # validation so all three agree.
      def parse_hosts_list(value)
        parts =
          case value
          when Array then value.flat_map { |v| v.to_s.split(',') }
          else value.to_s.split(',')
          end
        parts.map { |h| h.strip.downcase }.reject(&:empty?)
      end
    end
  end
end

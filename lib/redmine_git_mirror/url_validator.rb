# frozen_string_literal: true

require 'uri'

module RedmineGitMirror
  # Parses and validates a remote Git URL against an allow-list of hosts.
  # Accepted forms:
  #   ssh://<user>@<host>[:port]/owner/repo(.git)
  #   <user>@<host>:owner/repo(.git)
  #   https://<host>/owner/repo(.git)
  #
  # The validator rejects embedded credentials, query strings, fragments,
  # path traversal, and shell metacharacters. It returns a ParsedUrl whose
  # `to_s` produces the canonical remote URL used by `git`. The canonical
  # form downcases scheme, host, user, owner, and repo so two inputs that
  # refer to the same repository always serialize identically.
  #
  # Canonical forms:
  #   https://<host>/<owner>/<repo>.git
  #   <user>@<host>:<owner>/<repo>.git  (SSH, default port)
  #   ssh://<user>@<host>:<port>/<owner>/<repo>.git  (SSH, non-default port;
  #   the port must be preserved because git connects on it and a rewritten
  #   scp-style URL would silently fall back to port 22)
  class UrlValidator
    Result = Struct.new(:ok?, :error, :parsed, keyword_init: true)

    DEFAULT_SSH_PORT = 22

    ParsedUrl = Struct.new(:scheme, :host, :user, :owner, :repo, :port, keyword_init: true) do
      # Canonical remote URL string suitable for `git clone` / stored
      # remote_url. Round-trips through `UrlValidator.validate` to the
      # same ParsedUrl.
      def to_s
        case scheme.to_s
        when 'ssh'
          raise 'SSH parsed url requires a user' if user.nil? || user.empty?

          if port.nil? || port == DEFAULT_SSH_PORT
            "#{user}@#{host}:#{owner}/#{repo}.git"
          else
            "ssh://#{user}@#{host}:#{port}/#{owner}/#{repo}.git"
          end
        when 'https'
          raise 'HTTPS parsed url must not have a user' unless user.nil? || user.empty?

          "https://#{host}/#{owner}/#{repo}.git"
        else
          raise "Unknown parsed url scheme: #{scheme.inspect}"
        end
      end

      # Deterministic identifier used for the mirror record and the native
      # Repository::Git identifier. Matches Redmine's identifier format:
      # lowercase, alphanumeric, dash, underscore only.
      def mirror_identifier
        "#{owner}_#{repo}".gsub(/[^a-z0-9_\-]/, '_')
      end

      def relative_path
        "#{owner}/#{repo}.git"
      end
    end

    # Disallow shell metacharacters, whitespace, backticks, NUL bytes, and the
    # path traversal sequences that could escape the repository root.
    FORBIDDEN_PATH_PATTERN = /[\x00-\x1f\x7f"`$(){}|\\<>\s]|\.\.|@:|@\/|:\/\//.freeze
    PATH_SEGMENT_PATTERN = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze

    def self.validate(raw_url, allowed_hosts: nil)
      allowed = (allowed_hosts || Config.allowed_hosts).map(&:to_s).reject(&:empty?)
      return failure('URL is empty') if raw_url.nil? || raw_url.to_s.strip.empty?
      return failure('Allow list is empty') if allowed.empty?

      text = raw_url.to_s.strip
      return failure('URL contains invalid characters') if text.include?("\u0000")

      if text.match?(/\Ahttps:\/\//i)
        parse_https(text, allowed)
      elsif text.match?(/\Assh:\/\//i)
        parse_ssh_with_scheme(text, allowed)
      elsif text.include?('@') && text.include?(':') && !text.include?('://')
        parse_scp_style(text, allowed)
      else
        failure('Unsupported URL scheme')
      end
    end

    # Returns the canonical ParsedUrl for a valid input, or nil if the
    # input does not validate. Used by the model to canonicalize
    # stored remote URLs before uniqueness checks.
    def self.canonicalize(raw_url, allowed_hosts: nil)
      result = validate(raw_url, allowed_hosts: allowed_hosts)
      result.ok? ? result.parsed : nil
    end

    def self.parse_https(text, allowed)
      uri = URI.parse(text)
      unless uri.scheme == 'https' && uri.host && !uri.host.empty?
        return failure('HTTPS URL must include a host')
      end
      return failure('HTTPS URL must not include a username or password') if uri.user || uri.password
      return failure('HTTPS URL must not include a query string') if uri.query
      return failure('HTTPS URL must not include a fragment') if uri.fragment
      host = canonicalize_host(uri.host)
      return failure("Host '#{uri.host}' is not in the allow list") unless allowed.include?(host) || allowed.include?(uri.host)
      return failure('HTTPS URL must include a path') if uri.path.nil? || uri.path.empty?

      check_path(uri.path, host, user: nil, scheme: 'https')
    rescue URI::InvalidURIError
      failure('Invalid URL')
    end

    def self.parse_ssh_with_scheme(text, allowed)
      uri = URI.parse(text)
      unless uri.scheme == 'ssh' && uri.host && !uri.host.empty?
        return failure('SSH URL must include a host')
      end
      return failure('SSH URL must not include a query string') if uri.query
      return failure('SSH URL must not include a fragment') if uri.fragment
      return failure('SSH URL must not include a password') if uri.password
      host = canonicalize_host(uri.host)
      return failure("Host '#{uri.host}' is not in the allow list") unless allowed.include?(host) || allowed.include?(uri.host)
      return failure('SSH URL must include a path') if uri.path.nil? || uri.path.empty?

      user = canonicalize_user(uri.user.to_s)
      return failure('SSH URL user is required') if user.empty?

      port = uri.port
      return failure('SSH URL port must be between 1 and 65535') if port && (port < 1 || port > 65535)

      check_path(uri.path, host, user: user, scheme: 'ssh', port: uri.port)
    rescue URI::Error
      failure('Invalid URL')
    end

    def self.parse_scp_style(text, allowed)
      match = text.match(/\A(?<user>[A-Za-z0-9._-]+)@(?<host>[A-Za-z0-9.-]+):(?<path>.+)\z/)
      return failure('Invalid SSH-style URL') unless match

      user = canonicalize_user(match[:user])
      host = canonicalize_host(match[:host])
      path = match[:path]

      return failure('SSH URL user is required') if user.empty?
      return failure("Host '#{host}' is not in the allow list") unless allowed.include?(host)

      check_path("/#{path}", host, user: user, scheme: 'ssh', port: nil)
    end

    def self.check_path(path, host, user:, scheme:, port: nil)
      return failure('URL path contains forbidden characters or traversal') if path.match?(FORBIDDEN_PATH_PATTERN)
      return failure('URL path must not start with a slash segment') if path.start_with?('//')

      stripped = path.sub(/\A\//, '').sub(/\.git\z/i, '')
      segments = stripped.split('/').reject(&:empty?)
      return failure('URL path is empty') if segments.empty?

      if segments.size != 2
        return failure('URL path must be owner/repo(.git)')
      end

      owner, repo = segments
      return failure('URL owner segment is invalid') unless owner.match?(PATH_SEGMENT_PATTERN)
      return failure('URL repository segment is invalid') unless repo.match?(PATH_SEGMENT_PATTERN)

      success(scheme: scheme, host: host, user: user, owner: canonicalize_segment(owner), repo: canonicalize_segment(repo), port: port)
    end

    def self.success(scheme:, host:, user:, owner:, repo:, port: nil)
      Result.new(
        ok?: true,
        error: nil,
        parsed: ParsedUrl.new(scheme: scheme, host: host, user: user, owner: owner, repo: repo, port: port)
      )
    end

    def self.failure(message)
      Result.new(ok?: false, error: message, parsed: nil)
    end

    # Canonicalizes the host by lowercasing it. Hosts are case-insensitive
    # in DNS so two URLs that differ only in host case must serialize the
    # same to satisfy uniqueness.
    def self.canonicalize_host(host)
      host.to_s.downcase
    end

    # Canonicalizes the SSH user by lowercasing it. SSH usernames are
    # case-sensitive on the server side but all real Git hosting providers
    # normalize them to a single case. We use lowercase for determinism.
    def self.canonicalize_user(user)
      user.to_s.downcase
    end

    # Canonicalizes owner/repo segments by lowercasing them. Git hosting
    # providers treat these case-insensitively and canonical URLs are
    # always lowercase.
    def self.canonicalize_segment(segment)
      segment.to_s.downcase
    end
  end
end

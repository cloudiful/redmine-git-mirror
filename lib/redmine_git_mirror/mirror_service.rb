# frozen_string_literal: true

require 'fileutils'
require 'shellwords'

module RedmineGitMirror
  # Drives the lifecycle of a single mirror: validate the URL, claim a stable
  # local path inside the configured root, queue the worker, and expose
  # status transitions. The actual git commands live in CommandRunner.
  class MirrorService
    class PathOutsideRoot < StandardError; end
    class ProjectMismatch < StandardError; end
    class InvalidStoredRemoteUrl < StandardError; end

    def initialize(command_runner: CommandRunner.new,
                   repository_registrar: nil,
                   mirror_root: nil,
                   mirror_class: nil,
                   clock: -> { Time.now.utc })
      @command_runner = command_runner
      @mirror_root = (mirror_root || Config.mirror_root).to_s
      @repository_registrar = repository_registrar || RepositoryRegistrar.new(mirror_root: @mirror_root)
      @mirror_class = mirror_class || RedmineGitMirror::Mirror
      @clock = clock
    end

    # Validates the URL, computes the deterministic local path, and returns
    # the mirror record. If the record already exists it is returned and the
    # URL must still match.
    def register(project:, raw_url:)
      project_id = Integer(project.id)
      result = UrlValidator.validate(raw_url, allowed_hosts: Config.allowed_hosts)
      raise ArgumentError, result.error unless result.ok?

      parsed = result.parsed
      identifier = build_identifier(project_id, parsed)
      local_path = path_for(project_id, parsed)
      ensure_inside_root!(local_path)

      mirror = find_or_initialize(project_id: project_id, identifier: identifier)
      mirror.project_id = project_id
      mirror.remote_url = parsed.to_s
      mirror.local_path = local_path
      mirror.identifier = identifier
      mirror.status = 'pending'
      mirror.error_message = nil
      mirror.save!

      mirror
    end

    def find_by_project_and_identifier(project_id, identifier)
      @mirror_class.where(project_id: project_id, identifier: identifier).first
    end

    def find_by_project(project_id)
      @mirror_class.where(project_id: project_id)
    end

    def path_for(project_id, parsed)
      raise ProjectMismatch unless project_id.is_a?(Integer) || project_id.to_s =~ /\A\d+\z/

      pid = Integer(project_id)
      File.join(
        @mirror_root,
        pid.to_s,
        "#{parsed.owner}__#{parsed.repo}.git"
      )
    end

    def ensure_inside_root!(local_path)
      root = File.expand_path(@mirror_root)
      expanded = File.expand_path(local_path.to_s)
      return if expanded == root || expanded.start_with?(root + File::SEPARATOR)

      raise PathOutsideRoot, "Local path #{expanded} is outside mirror root #{root}"
    end

    # Performs the git clone. Used by the worker. Updates status transitions
    # and writes the error message on failure.
    def perform_clone(mirror)
      transition!(mirror, 'cloning')
      ensure_parent_directory(mirror.local_path)
      @command_runner.clone(mirror.remote_url, mirror.local_path)
      transition!(mirror, 'ready')
      register_native_repository(mirror)
      mirror
    rescue StandardError => e
      record_failure(mirror, e.message)
      raise
    end

    # Performs a git fetch. Preserves the prior ready state on failure by
    # leaving the local mirror on disk untouched.
    def perform_fetch(mirror)
      transition!(mirror, 'cloning')
      @command_runner.fetch(mirror.local_path)
      transition!(mirror, 'ready')
      register_native_repository(mirror)
      mirror
    rescue StandardError => e
      record_failure(mirror, e.message)
      raise
    end

    def status_payload(mirror)
      {
        id: mirror.id,
        project_id: mirror.project_id,
        identifier: mirror.identifier,
        status: mirror.status,
        remote_url: mirror.remote_url,
        local_path: mirror.local_path,
        error: mirror.error_message,
        updated_at: mirror.updated_at&.iso8601
      }
    end

    private

    def build_identifier(project_id, parsed)
      suffix = parsed.mirror_identifier
      base = "mirror_#{project_id}_#{suffix}".downcase
      base.gsub(/[^a-z0-9_\-]/, '_')
    end

    def find_or_initialize(project_id:, identifier:)
      @mirror_class.find_or_initialize_by(project_id: project_id, identifier: identifier)
    end

    def transition!(mirror, status)
      mirror.status = status
      mirror.error_message = nil
      mirror.save!
    end

    def record_failure(mirror, message)
      mirror.status = 'failed'
      mirror.error_message = message.to_s[0, 2000]
      mirror.save!
    end

    def ensure_parent_directory(local_path)
      parent = File.dirname(local_path.to_s)
      FileUtils.mkdir_p(parent)
    end

    def register_native_repository(mirror)
      project = Project.find(mirror.project_id)
      parsed = revalidate_parsed(mirror)
      @repository_registrar.upsert(
        project: project,
        parsed: parsed,
        local_path: mirror.local_path
      )
    end

    # Revalidates a stored remote_url and returns the canonical ParsedUrl.
    # Stored URLs are produced by UrlValidator.validate so the only way
    # this can fail is a corruption or manual edit; we raise rather than
    # silently passing nil to the registrar.
    def revalidate_parsed(mirror)
      result = UrlValidator.validate(mirror.remote_url.to_s, allowed_hosts: Config.allowed_hosts)
      unless result.ok?
        raise InvalidStoredRemoteUrl,
              "Stored remote URL for mirror #{mirror.id} is not valid: #{result.error}"
      end

      result.parsed
    end
  end
end

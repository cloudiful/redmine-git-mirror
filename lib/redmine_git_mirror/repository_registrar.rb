# frozen_string_literal: true

require 'fileutils'

module RedmineGitMirror
  # Creates or reuses a native Repository::Git record for a ready mirror.
  # Writes are idempotent: a second call with the same project and parsed URL
  # returns the same record. Conflicting records (same identifier pointing
  # outside the mirror root, or pointing at a different path) raise
  # ConflictingRepository.
  class RepositoryRegistrar
    class ConflictingRepository < StandardError; end
    class InvalidMirrorPath < StandardError; end

    RepositoryFactory = ->(klass, attributes) { klass.new(attributes) }

    def initialize(mirror_root: nil,
                   repository_factory: RepositoryFactory,
                   repository_class: nil)
      @mirror_root = (mirror_root || Config.mirror_root).to_s
      @repository_factory = repository_factory
      @repository_class_override = repository_class
    end

    # Returns a Repository::Git record inside the configured mirror root. The
    # caller passes the parsed URL and the project. The local_path must be
    # already on disk and inside the configured mirror root.
    def upsert(project:, parsed:, local_path:, identifier: nil)
      raise InvalidMirrorPath, 'local_path is required' if local_path.nil? || local_path.to_s.empty?

      resolved_local = expand_local_path(local_path)
      ensure_inside_root!(resolved_local)

      identifier ||= derived_identifier(project, parsed)
      existing = find_existing(project: project, identifier: identifier)

      if existing
        if same_repository_path?(existing, resolved_local)
          existing
        else
          raise ConflictingRepository,
                "Existing repository #{existing.id} points to #{existing.url}"
        end
      else
        create_repository(project: project, identifier: identifier, local_path: resolved_local)
      end
    end

    # Returns a defensive path computation for callers that need the path
    # before the directory exists. This is used by tests and by the
    # controller when constructing the local mirror directory.
    def path_for(project:, parsed:)
      project_segment = Integer(project.id)
      File.join(
        @mirror_root,
        project_segment.to_s,
        "#{parsed.owner}__#{parsed.repo}.git"
      )
    end

    private

    def expand_local_path(local_path)
      File.expand_path(local_path.to_s)
    end

    def ensure_inside_root!(resolved_local)
      root = File.expand_path(@mirror_root)
      unless resolved_local.start_with?(root + File::SEPARATOR) || resolved_local == root
        raise InvalidMirrorPath, "Path #{resolved_local} is outside mirror root #{root}"
      end
    end

    def derived_identifier(project, parsed)
      suffix = parsed.mirror_identifier
      base = "mirror_#{project.id}_#{suffix}".downcase
      base.gsub(/[^a-z0-9_\-]/, '_')
    end

    def find_existing(project:, identifier:)
      scope = repository_class_scope(project)
      scope.find { |r| identifier_matches?(r, identifier) }
    end

    def repository_class_scope(project)
      if @repository_class_override
        @repository_class_override.send(:all_records).select { |r| r.project_id == project.id }
      else
        repository_class.where(project_id: project.id).to_a
      end
    end

    def identifier_matches?(record, identifier)
      if record.respond_to?(:identifier)
        record.identifier.to_s == identifier.to_s
      elsif record.respond_to?(:attributes)
        record.attributes[:identifier].to_s == identifier.to_s
      else
        false
      end
    end

    def same_repository_path?(repository, resolved_local)
      url = repository.respond_to?(:url) ? repository.url : nil
      return false if url.nil? || url.to_s.empty?

      File.expand_path(url.to_s) == resolved_local
    end

    def create_repository(project:, identifier:, local_path:)
      record = @repository_factory.call(
        repository_class,
        project_id: project.id,
        identifier: identifier,
        url: local_path,
        type: 'Repository::Git'
      )
      record.save!
      record
    end

    def repository_class
      @repository_class_override || Repository::Git
    end
  end
end

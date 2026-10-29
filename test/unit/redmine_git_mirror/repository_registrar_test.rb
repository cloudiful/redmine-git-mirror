# frozen_string_literal: true

require File.expand_path('../../test_helper', __dir__)

class RedmineGitMirrorRepositoryRegistrarTest < Minitest::Test
  class FakeRepository
    attr_reader :attributes, :saved

    def initialize(attributes = {})
      @attributes = attributes
      @saved = false
    end

    def save!
      @saved = true
      self
    end

    def assign_attributes(attrs)
      attrs.each_pair { |k, v| @attributes[k] = v }
    end

    def id
      @attributes[:id]
    end

    def url
      @attributes[:url]
    end

    def url=(value)
      @attributes[:url] = value
    end

    def identifier
      @attributes[:identifier]
    end

    def identifier=(value)
      @attributes[:identifier] = value
    end

    def project_id
      @attributes[:project_id]
    end

    def project_id=(value)
      @attributes[:project_id] = value
    end

    def type
      @attributes[:type] || 'FakeRepository'
    end

    def type=(value)
      @attributes[:type] = value
    end
  end

  class FakeRepositoryClass
    attr_reader :created, :queries

    def initialize
      @seed = []
      @created = []
      @queries = []
    end

    def seed(record)
      @seed << record
      record
    end

    def all_records
      @seed
    end

    def new(attrs)
      FakeRepository.new(attrs)
    end
  end

  def setup
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      yield
    end if false # placeholder; real setup happens per-test
  end

  def with_tmpdir
    Dir.mktmpdir { |dir| yield dir }
  end

  def parsed_url(owner:, repo:)
    RedmineGitMirror::UrlValidator::ParsedUrl.new(
      scheme: 'git',
      host: 'git.example.com',
      owner: owner,
      repo: repo
    )
  end

  def fake_project(id: 7)
    Struct.new(:id, :identifier).new(id, "project-#{id}")
  end

  def test_path_for_is_inside_root
    with_tmpdir do |tmpdir|
      registrar = RedmineGitMirror::RepositoryRegistrar.new(mirror_root: tmpdir)
      parsed = parsed_url(owner: 'acme', repo: 'widgets')

      path = registrar.path_for(project: fake_project, parsed: parsed)
      assert File.expand_path(path).start_with?(File.expand_path(tmpdir) + '/')
    end
  end

  def test_upsert_creates_new_record_inside_root
    with_tmpdir do |tmpdir|
      fake_class = FakeRepositoryClass.new
      registrar = RedmineGitMirror::RepositoryRegistrar.new(
        mirror_root: tmpdir,
        repository_factory: ->(_klass, attrs) { fake_class.new(attrs) },
        repository_class: fake_class
      )

      parsed = parsed_url(owner: 'acme', repo: 'widgets')
      local = File.join(tmpdir, '7', 'acme__widgets.git')

      result = registrar.upsert(project: fake_project, parsed: parsed, local_path: local)
      assert_equal local, File.expand_path(result.attributes[:url])
      assert_equal 7, result.attributes[:project_id]
      assert result.attributes[:identifier].match?(/\A(?!\d+$)[a-z0-9_\-]*\z/)
    end
  end

  def test_upsert_is_idempotent_for_same_input
    with_tmpdir do |tmpdir|
      fake_class = FakeRepositoryClass.new
      registrar = RedmineGitMirror::RepositoryRegistrar.new(
        mirror_root: tmpdir,
        repository_factory: ->(_klass, attrs) { fake_class.new(attrs) },
        repository_class: fake_class
      )

      parsed = parsed_url(owner: 'acme', repo: 'widgets')
      local = File.join(tmpdir, '7', 'acme__widgets.git')

      first = registrar.upsert(project: fake_project, parsed: parsed, local_path: local)
      fake_class.seed(first)
      second = registrar.upsert(project: fake_project, parsed: parsed, local_path: local)

      assert_equal first, second
    end
  end

  def test_upsert_raises_conflict_for_different_path_with_same_identifier
    with_tmpdir do |tmpdir|
      fake_class = FakeRepositoryClass.new
      registrar = RedmineGitMirror::RepositoryRegistrar.new(
        mirror_root: tmpdir,
        repository_factory: ->(_klass, attrs) { fake_class.new(attrs) },
        repository_class: fake_class
      )

      parsed = parsed_url(owner: 'acme', repo: 'widgets')
      local = File.join(tmpdir, '7', 'acme__widgets.git')

      # The registrar derives `mirror_<project_id>_<owner_repo>`. Seed the
      # fake with that identifier so the registrar can find it.
      derived_id = "mirror_#{fake_project.id}_#{parsed.mirror_identifier}".downcase.gsub(/[^a-z0-9_\-]/, '_')
      record = fake_class.new(
        project_id: 7,
        identifier: derived_id,
        url: '/var/elsewhere/acme__widgets.git'
      )
      fake_class.seed(record)

      assert_raises(RedmineGitMirror::RepositoryRegistrar::ConflictingRepository) do
        registrar.upsert(project: fake_project, parsed: parsed, local_path: local)
      end
    end
  end

  def test_upsert_rejects_path_outside_root
    fake_class = FakeRepositoryClass.new
    registrar = RedmineGitMirror::RepositoryRegistrar.new(
      mirror_root: '/var/lib/redmine/repositories',
      repository_factory: ->(_klass, attrs) { fake_class.new(attrs) },
      repository_class: fake_class
    )

    parsed = parsed_url(owner: 'acme', repo: 'widgets')
    assert_raises(RedmineGitMirror::RepositoryRegistrar::InvalidMirrorPath) do
      registrar.upsert(project: fake_project, parsed: parsed, local_path: '/tmp/elsewhere.git')
    end
  end
end

# frozen_string_literal: true

# Functional test for the authenticated controller. This test requires
# Redmine's test environment and is intended to be run through
# `rake redmine:plugins:test` so that ActionController::TestCase, fixtures,
# and the route loader are all available.
#
# The test focuses on the unauthenticated and authorized request paths.
# When invoked outside Redmine the file is parsed but the test classes are
# not registered.

require_relative '../test_helper'

if File.exist?(File.expand_path('../../../test/test_helper', __dir__))
  require File.expand_path('../../../test/test_helper', __dir__)

  class RedmineGitMirrorRepositoryControllerTest < ActionController::TestCase
    setup do
      @project = Project.find('ecookbook')
      Setting.sys_api_enabled = false # we are not using the WS key
      @previous_plugin_settings = Setting.plugin_redmine_git_mirror
      @previous_plugin_settings = nil unless @previous_plugin_settings.is_a?(Hash)
      Setting.plugin_redmine_git_mirror = { 'allowed_hosts' => 'git.example.com' }
      # Never run the real clone job during the request test. The job is
      # exercised separately by MirrorRefreshJobTest against a stubbed
      # command runner.
      @original_perform_later = RedmineGitMirror::MirrorRefreshJob.method(:perform_later)
      RedmineGitMirror::MirrorRefreshJob.define_singleton_method(:perform_later) do |_id|
        # No-op: the controller test only asserts that the request returns
        # a queued mirror; the actual clone is exercised in job tests.
        true
      end
    end

    teardown do
      RedmineGitMirror::MirrorRefreshJob.define_singleton_method(:perform_later, @original_perform_later) if @original_perform_later
      RedmineGitMirror::Mirror.delete_all
      Setting.plugin_redmine_git_mirror = @previous_plugin_settings || {}
      # Each test sets the API key directly; clear it so later test
      # files in the same process start without a configured key.
      ENV.delete('REDMINE_GIT_MIRROR_API_KEY')
    end

    test 'request without authorization header returns 403' do
      post :create, params: { project_id: @project.id, url: 'https://git.example.com/acme/widgets.git' }, format: :json
      assert_response :forbidden
    end

    test 'request with wrong bearer token returns 403' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      @request.headers['Authorization'] = 'Bearer wrong-key'
      post :create,
           params: { project_id: @project.id, url: 'https://git.example.com/acme/widgets.git' },
           format: :json
      assert_response :forbidden
    end

    test 'request with non-bearer authorization scheme returns 403' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      @request.headers['Authorization'] = 'Basic dXNlcjpwYXNz'
      post :create,
           params: { project_id: @project.id, url: 'https://git.example.com/acme/widgets.git' },
           format: :json
      assert_response :forbidden
    end

    test 'request with correct bearer token queues a mirror and returns 202' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      @request.headers['Authorization'] = 'Bearer correct-key'
      post :create,
           params: { project_id: @project.id, url: 'https://git.example.com/acme/widgets.git' },
           format: :json
      assert_response :accepted
      body = JSON.parse(response.body)
      assert_equal 'pending', body['status']
      assert_match(/acme__widgets\.git\z/, body['local_path'])
      assert RedmineGitMirror::Mirror.find_by(id: body['id']).present?
    end

    test 'query-string key is no longer accepted' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      # Even with the correct key in ?key=, the controller must reject
      # the request because the contract is now Authorization-header only.
      post :create,
           params: { project_id: @project.id, key: 'correct-key',
                     url: 'https://git.example.com/acme/widgets.git' },
           format: :json
      assert_response :forbidden
    end

    test 'rejected request does not include the supplied token in the response body' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      @request.headers['Authorization'] = 'Bearer wrong-key'
      post :create,
           params: { project_id: @project.id, url: 'https://git.example.com/acme/widgets.git' },
           format: :json
      body = response.parsed_body rescue response.body
      assert_response :forbidden
      assert_includes body.to_s, 'Access denied'
      refute_includes body.to_s, 'wrong-key'
      refute_includes body.to_s, ENV['REDMINE_GIT_MIRROR_API_KEY']
    end

    test 'request without url returns 400' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      @request.headers['Authorization'] = 'Bearer correct-key'
      post :create,
           params: { project_id: @project.id },
           format: :json
      assert_response :bad_request
    end

    test 'request with disallowed host returns 422' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      @request.headers['Authorization'] = 'Bearer correct-key'
      post :create,
           params: { project_id: @project.id, url: 'https://malicious.example.com/acme/widgets.git' },
           format: :json
      assert_response :unprocessable_content
    end

    test 'request preserves ssh user in queued mirror remote_url' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      @request.headers['Authorization'] = 'Bearer correct-key'
      post :create,
           params: { project_id: @project.id,
                     url: 'git@git.example.com:acme/widgets.git' },
           format: :json
      assert_response :accepted
      body = JSON.parse(response.body)
      mirror = RedmineGitMirror::Mirror.find_by(id: body['id'])
      assert_equal 'git@git.example.com:acme/widgets.git', mirror.remote_url
    end

    test 'status endpoint requires bearer token' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      RedmineGitMirror::Mirror.create!(
        project_id: @project.id,
        remote_url: 'https://git.example.com/acme/widgets.git',
        local_path: '/var/lib/redmine/repositories/' + @project.id.to_s + '/acme__widgets.git',
        identifier: 'mirror_test_status',
        status: 'ready'
      )
      get :show,
          params: { project_id: @project.id, identifier: 'mirror_test_status' },
          format: :json
      assert_response :forbidden

      @request.headers['Authorization'] = 'Bearer correct-key'
      get :show,
          params: { project_id: @project.id, identifier: 'mirror_test_status' },
          format: :json
      assert_response :success
      body = JSON.parse(response.body)
      assert_equal 'ready', body['status']
      assert_equal 'mirror_test_status', body['identifier']
    end

    test 'authentication honors a key rotated behind the process cache' do
      Setting.plugin_redmine_git_mirror = { 'api_key' => 'first-key', 'allowed_hosts' => 'git.example.com' }
      assert_equal 'first-key', RedmineGitMirror::Config.api_key

      # The rotation lands in the settings table from another process
      # while this process still holds the memoized previous key.
      Setting.where(name: 'plugin_redmine_git_mirror').update_all(
        value: { 'api_key' => 'second-key', 'allowed_hosts' => 'git.example.com' }.to_yaml,
        updated_on: Time.current + 5.seconds
      )

      @request.headers['Authorization'] = 'Bearer first-key'
      post :create,
           params: { project_id: @project.id, url: 'https://git.example.com/acme/widgets.git' },
           format: :json
      assert_response :forbidden

      @request.headers['Authorization'] = 'Bearer second-key'
      post :create,
           params: { project_id: @project.id, url: 'https://git.example.com/acme/widgets.git' },
           format: :json
      assert_response :accepted
    end

    test 'queued mirror uses root and hosts refreshed behind the process cache' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'correct-key'
      Setting.plugin_redmine_git_mirror = { 'mirror_root' => '/old/root' }
      assert_equal '/old/root', RedmineGitMirror::Config.mirror_root

      # Another process saves a new root and a new host without
      # clearing this process's memo. The worker consumes both values
      # through the same Config readers, so the queued mirror must
      # already reflect them here.
      Setting.where(name: 'plugin_redmine_git_mirror').update_all(
        value: { 'mirror_root' => '/fresh/root', 'allowed_hosts' => 'git.fresh.test' }.to_yaml,
        updated_on: Time.current + 5.seconds
      )

      @request.headers['Authorization'] = 'Bearer correct-key'
      post :create,
           params: { project_id: @project.id, url: 'https://git.fresh.test/acme/widgets.git' },
           format: :json
      assert_response :accepted
      body = JSON.parse(response.body)
      assert body['local_path'].start_with?('/fresh/root/'),
             "expected local_path under /fresh/root, got #{body['local_path'].inspect}"
    end
  end
end

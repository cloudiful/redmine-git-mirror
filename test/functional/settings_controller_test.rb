# frozen_string_literal: true

# Functional test for the administrator settings page. Requires
# Redmine's test environment and is intended to be run through
# `rake redmine:plugins:test`. When invoked outside Redmine the file is
# parsed but the test class is not registered.

require_relative '../test_helper'

# `require_relative '../test_helper'` loads Redmine's harness when the plugin
# sits inside a Redmine checkout and the standalone helper otherwise. The
# controller test needs Redmine, so register it only when that harness (and
# thus ActionController) is loaded.
if defined?(ActionController::TestCase)
  class RedmineGitMirrorSettingsControllerTest < ActionController::TestCase
    tests RedmineGitMirror::SettingsController
    fixtures :users

    ENV_KEYS = %w[
      REDMINE_GIT_MIRROR_API_KEY
      REDMINE_GIT_MIRROR_ALLOWED_HOSTS
      REDMINE_GIT_MIRROR_ROOT
    ].freeze

    setup do
      @previous_env = {}
      ENV_KEYS.each { |key| @previous_env[key] = ENV.delete(key) }

      @previous_settings = Setting.plugin_redmine_git_mirror
      @previous_settings = nil unless @previous_settings.is_a?(Hash)
      Setting.plugin_redmine_git_mirror = {}

      # The production controller keeps CSRF protection enabled. The
      # functional harness does not submit authenticity tokens, so the
      # protection is lifted for the test process only and restored
      # afterwards.
      @previous_forgery = RedmineGitMirror::SettingsController.allow_forgery_protection
      RedmineGitMirror::SettingsController.allow_forgery_protection = false
    end

    teardown do
      Setting.plugin_redmine_git_mirror = @previous_settings || {}
      @previous_env.each_pair { |key, value| ENV[key] = value unless value.nil? }
      ENV_KEYS.each { |key| ENV.delete(key) if @previous_env[key].nil? }
      RedmineGitMirror::SettingsController.allow_forgery_protection = @previous_forgery
    end

    test 'anonymous user is redirected to login' do
      get :edit
      assert_response :redirect
    end

    test 'non-administrator cannot view settings' do
      @request.session[:user_id] = 2
      get :edit
      assert_response :forbidden
    end

    test 'non-administrator cannot update settings' do
      @request.session[:user_id] = 2
      patch :update, params: { allowed_hosts: 'evil.example.com', mirror_root: '/tmp/evil' }
      assert_response :forbidden
      saved = Setting.plugin_redmine_git_mirror
      assert saved['allowed_hosts'].to_s.empty?
      assert saved['mirror_root'].to_s.empty?
    end

    test 'non-administrator cannot rotate the api key' do
      login_as_admin
      get :edit
      before = Setting.plugin_redmine_git_mirror['api_key']

      @request.session[:user_id] = 2
      post :rotate_api_key
      assert_response :forbidden
      assert_equal before, Setting.plugin_redmine_git_mirror['api_key']
    end

    test 'visiting settings generates and displays a key when none is configured' do
      login_as_admin
      get :edit

      assert_response :success
      saved = Setting.plugin_redmine_git_mirror['api_key']
      assert saved.is_a?(String) && !saved.empty?
      assert_includes response.body, ERB::Util.html_escape(saved)
      assert_includes response.body, 'readonly'
      assert_includes response.body, 'Copy'
    end

    test 'visiting settings shows the environment key without persisting' do
      ENV['REDMINE_GIT_MIRROR_API_KEY'] = 'env-key'
      login_as_admin
      get :edit

      assert_response :success
      assert_includes response.body, 'env-key'
      assert Setting.plugin_redmine_git_mirror['api_key'].to_s.empty?
    end

    test 'administrator saves allowed hosts and mirror root' do
      login_as_admin
      get :edit
      key_before = Setting.plugin_redmine_git_mirror['api_key']

      patch :update, params: { allowed_hosts: 'git.a.test, git.b.test', mirror_root: '/srv/mirrors' }

      assert_redirected_to '/redmine_git_mirror/settings'
      assert_equal 'git.a.test, git.b.test', Setting.plugin_redmine_git_mirror['allowed_hosts']
      assert_equal '/srv/mirrors', Setting.plugin_redmine_git_mirror['mirror_root']
      assert_equal key_before, Setting.plugin_redmine_git_mirror['api_key']
      assert_equal ['git.a.test', 'git.b.test'], RedmineGitMirror::Config.allowed_hosts
      assert_equal '/srv/mirrors', RedmineGitMirror::Config.mirror_root
      refute_includes flash[:notice].to_s, key_before
    end

    test 'update rejects a relative mirror root without persisting' do
      login_as_admin
      get :edit
      key_before = Setting.plugin_redmine_git_mirror['api_key']

      patch :update, params: { allowed_hosts: 'git.example.com', mirror_root: 'relative/path' }

      assert_response :unprocessable_content
      assert Setting.plugin_redmine_git_mirror['mirror_root'].to_s.empty?
      assert_includes response.body, 'absolute'
      assert_equal key_before, Setting.plugin_redmine_git_mirror['api_key']
    end

    test 'rotate persists a different key and invalidates the old one' do
      login_as_admin
      get :edit
      old_key = Setting.plugin_redmine_git_mirror['api_key']
      assert RedmineGitMirror::Authenticator.authenticated?(old_key)

      post :rotate_api_key

      assert_redirected_to '/redmine_git_mirror/settings'
      new_key = Setting.plugin_redmine_git_mirror['api_key']
      refute_equal old_key, new_key
      assert RedmineGitMirror::Authenticator.authenticated?(new_key)
      refute RedmineGitMirror::Authenticator.authenticated?(old_key)
      refute_includes flash[:notice].to_s, old_key
      refute_includes flash[:notice].to_s, new_key
    end

    test 'settings page explains the shared persistent root and no migration' do
      login_as_admin
      get :edit

      assert_response :success
      assert_includes response.body, 'Sidekiq'
      assert_includes response.body, 'does not move'
    end

    test 'edit selects the Git mirrors admin menu item and not core Settings' do
      login_as_admin
      get :edit

      assert_response :success
      assert_select '#admin-menu a.redmine-git-mirror-settings.selected' do
        assert_select 'span.icon-label', 'Git mirrors'
      end
      assert_select '#admin-menu a.settings.selected', false
    end

    test 'edit renders the plugin sprite icon for the Git mirrors admin menu item' do
      login_as_admin
      get :edit

      assert_response :success
      assert_select 'a.redmine-git-mirror-settings svg use' do |uses|
        assert_equal 1, uses.size
        # The asset pipeline fingerprints a sprite it can resolve, so the
        # digest in the path proves the plugin sprite is shipped where
        # Redmine looks for plugin assets.
        assert_match %r{\A/assets/plugin_assets/redmine_git_mirror/icons-[0-9a-f]+\.svg#icon--git-mirror\z},
                     uses.first['href']
      end
    end

    test 'reads see settings saved behind the process cache' do
      Setting.plugin_redmine_git_mirror = {
        'api_key' => 'cached-key',
        'allowed_hosts' => 'old.example.com',
        'mirror_root' => '/old/root'
      }
      assert_equal 'cached-key', RedmineGitMirror::Config.api_key
      assert_equal ['old.example.com'], RedmineGitMirror::Config.allowed_hosts
      assert_equal '/old/root', RedmineGitMirror::Config.mirror_root

      # Another process (a second web worker or the settings page in a
      # different process) saves newer settings without clearing this
      # process's memo. Every store read refreshes the memo first, so
      # the API worker and the Sidekiq worker observe the new values.
      Setting.where(name: 'plugin_redmine_git_mirror').update_all(
        value: {
          'api_key' => 'fresh-key',
          'allowed_hosts' => 'new.example.com',
          'mirror_root' => '/new/root'
        }.to_yaml,
        updated_on: Time.current + 5.seconds
      )

      assert_equal 'fresh-key', RedmineGitMirror::Config.api_key
      assert_equal ['new.example.com'], RedmineGitMirror::Config.allowed_hosts
      assert_equal '/new/root', RedmineGitMirror::Config.mirror_root
    end

    test 'edit without sudo confirmation renders the sudo form and hides the key' do
      # Redmine's test harness disables sudo mode globally; re-enable it
      # the way core's own sudo tests do so this filter is exercised.
      # The session keeps no sudo confirmation timestamp, which is what
      # triggers the password form.
      Redmine::SudoMode.stubs(:enabled?).returns(true)
      Setting.plugin_redmine_git_mirror = { 'api_key' => 'saved-key' }
      @request.session[:user_id] = 1
      get :edit

      assert_response :success
      assert_includes response.body, 'sudo_password'
      refute_includes response.body, 'saved-key'
      refute_includes response.body, 'Current key'
    end

    test 'rotate without sudo confirmation renders the sudo form and keeps the key' do
      # See above: re-enable sudo mode for this test while leaving the
      # session unconfirmed.
      Redmine::SudoMode.stubs(:enabled?).returns(true)
      Setting.plugin_redmine_git_mirror = { 'api_key' => 'saved-key' }
      @request.session[:user_id] = 1
      post :rotate_api_key

      assert_response :success
      assert_includes response.body, 'sudo_password'
      assert_equal 'saved-key', Setting.plugin_redmine_git_mirror['api_key']
    end

    test 'update failure still ensures and displays the api key' do
      login_as_admin
      patch :update, params: { allowed_hosts: 'git.example.com', mirror_root: 'relative/path' }

      assert_response :unprocessable_content
      saved = Setting.plugin_redmine_git_mirror['api_key']
      assert saved.is_a?(String) && !saved.empty?
      assert_includes response.body, ERB::Util.html_escape(saved)
    end

    private

    def login_as_admin
      @request.session[:user_id] = 1
      @request.session[:sudo_timestamp] = Time.now.to_i
    end
  end
end

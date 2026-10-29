# frozen_string_literal: true

module RedmineGitMirror
  # Administrator-only settings page for mirror configuration.
  #
  # Unlike the JSON mirror API, this controller keeps Redmine's default
  # CSRF protection and requires an administrator for every action, so
  # the shared API key is only ever visible to administrators. The key
  # itself is never accepted as form input and never appears in flash
  # messages, URLs, or logs; it changes only via rotation.
  class SettingsController < ApplicationController
    layout 'admin'

    before_action :require_admin

    # The controller reuses Redmine's "settings" controller name, so the
    # shared menu-item map cannot target this page without also hijacking
    # the core Administration → Settings item. Selecting the plugin's admin
    # menu entry for this controller keeps both entries correct.
    def current_menu_item
      :redmine_git_mirror_settings
    end

    # Viewing or rotating the shared secret additionally requires a
    # fresh sudo-mode confirmation, mirroring how Redmine core guards
    # its own API-key surfaces. Saving hosts/root stays admin + CSRF.
    require_sudo_mode :edit, :rotate_api_key

    # Shows the settings form. Visiting with no key configured
    # generates a high-entropy URL-safe key and persists it so the
    # page always displays a usable key for copy.
    def edit
      @api_key = Config.ensure_api_key!
      @allowed_hosts = Config.allowed_hosts.join(', ')
      @mirror_root = Config.mirror_root
      @errors = []
      return if Config.api_key_configured?

      @errors << 'The API key could not be generated. Check the Redmine logs.'
    end

    # Saves allowed hosts and mirror root. The API key is preserved
    # untouched; use #rotate_api_key to change it.
    def update
      values, @errors = Config.validate_settings(
        'allowed_hosts' => params[:allowed_hosts],
        'mirror_root' => params[:mirror_root]
      )

      if @errors.empty? && Config.save_settings(values)
        flash[:notice] = 'Git mirror settings saved.'
        redirect_to redmine_git_mirror_settings_path
      else
        @errors << 'The settings could not be saved.' if @errors.empty?
        @api_key = Config.ensure_api_key!
        if @api_key.empty?
          @errors << 'The API key could not be generated. Check the Redmine logs.'
        end
        @allowed_hosts = params[:allowed_hosts].to_s
        @mirror_root = params[:mirror_root].to_s
        render :edit, status: :unprocessable_content
      end
    end

    # Persists a fresh API key. The previous key stops authenticating
    # immediately. The key itself never appears in the redirect or the
    # flash message.
    def rotate_api_key
      rotated = Config.rotate_api_key!
      if rotated.empty?
        flash[:error] = 'The API key could not be rotated. Check the Redmine logs.'
      else
        flash[:notice] = 'API key rotated. Update the caller with the new key shown below.'
      end
      redirect_to redmine_git_mirror_settings_path
    end
  end
end

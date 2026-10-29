# frozen_string_literal: true

module RedmineGitMirror
  # Production settings store backed by Redmine's Setting table. Reads
  # return {} and writes return false when Redmine is unavailable
  # (standalone unit tests), where tests inject a memory store instead.
  #
  # Redmine memoizes every setting per process (`Setting[:name]`) and
  # only refreshes that memo from `ApplicationController#user_setup`,
  # once per served request. The Sidekiq worker and the plugin's own
  # JSON API controller never run that hook, so a plain memoized read
  # would serve a rotated key, a new mirror root, or new allowed hosts
  # only after a process restart. Every read therefore runs
  # `Setting.check_cache` first, which clears the memo when another
  # process has saved newer settings.
  #
  # The class name matches the file basename so Zeitwerk eager loading
  # resolves `RedmineGitMirror::SettingsStore` from `settings_store.rb`.
  class SettingsStore
    PLUGIN_SETTINGS_METHOD = :plugin_redmine_git_mirror

    def read
      return {} unless settings_available?

      ::Setting.check_cache if ::Setting.respond_to?(:check_cache)
      raw = ::Setting.public_send(PLUGIN_SETTINGS_METHOD)
      raw.is_a?(Hash) ? raw : {}
    rescue StandardError
      {}
    end

    def write(values)
      return false unless settings_available?(writer: true)

      current = read
      merged = current.merge(values.each_with_object({}) { |(k, v), m| m[k.to_s] = v })
      ::Setting.public_send("#{PLUGIN_SETTINGS_METHOD}=", merged)
      true
    rescue StandardError
      false
    end

    private

    def settings_available?(writer: false)
      return false unless defined?(::Setting)

      name = writer ? "#{PLUGIN_SETTINGS_METHOD}=" : PLUGIN_SETTINGS_METHOD.to_s
      ::Setting.respond_to?(name)
    end
  end
end

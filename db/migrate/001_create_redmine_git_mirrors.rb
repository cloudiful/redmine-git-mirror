# frozen_string_literal: true

class CreateRedmineGitMirrors < ActiveRecord::Migration[7.0]
  def change
    create_table :redmine_git_mirrors do |t|
      t.references :project, null: false, foreign_key: true
      t.string :remote_url, null: false, limit: 255
      t.string :local_path, null: false, limit: 255
      t.string :identifier, null: false, limit: 100
      t.string :status, null: false, limit: 16, default: 'pending'
      t.text :error_message
      t.timestamps null: false
    end

    add_index :redmine_git_mirrors, [:project_id, :identifier],
              unique: true, name: 'index_redmine_git_mirrors_on_project_identifier'
    add_index :redmine_git_mirrors, [:project_id, :remote_url],
              unique: true, name: 'index_redmine_git_mirrors_on_project_remote_url'
  end
end

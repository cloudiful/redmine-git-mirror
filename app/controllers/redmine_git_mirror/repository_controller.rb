# frozen_string_literal: true

module RedmineGitMirror
  # Authenticated JSON endpoint used by an external client to queue mirror work
  # and read its status.
  #
  # Authentication uses an HTTP Authorization: Bearer <token> header. The
  # shared secret is never accepted as a query parameter or request body so
  # Rails access logs (which include query strings by default) cannot record
  # it. The Authorization header is filtered by Rails' default parameter
  # filter so it does not appear in logs either.
  class RepositoryController < ActionController::Base
    include ActiveSupport::SecurityUtils

    skip_before_action :verify_authenticity_token

    before_action :authenticate!
    before_action :load_project, only: [:show, :create]

    # POST /sys/redmine_git_mirror/projects/:project_id/repository
    def create
      raw_url = params[:url].to_s
      if raw_url.empty?
        return render json: { error: 'url is required' }, status: :bad_request
      end

      service = MirrorService.new
      mirror =
        begin
          service.register(project: @project, raw_url: raw_url)
        rescue ArgumentError => e
          return render json: { error: e.message }, status: :unprocessable_content
        end

      MirrorRefreshJob.perform_later(mirror.id)
      render json: service.status_payload(mirror), status: :accepted
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: e.record.errors.full_messages.join(', ') },
             status: :unprocessable_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'project not found' }, status: :not_found
    end

    # GET /sys/redmine_git_mirror/projects/:project_id/repository
    def show
      identifier = params[:identifier].to_s
      service = MirrorService.new
      mirror =
        if identifier.empty?
          service.find_by_project(@project.id).order(updated_at: :desc).first
        else
          service.find_by_project_and_identifier(@project.id, identifier)
        end

      if mirror.nil?
        render json: { error: 'mirror not found' }, status: :not_found
      else
        render json: service.status_payload(mirror), status: :ok
      end
    end

    private

    def authenticate!
      User.current = nil
      token = bearer_token
      return true if Authenticator.authenticated?(token)

      # Generic log line that does not include the supplied token.
      logger.info 'redmine_git_mirror: rejected request without valid bearer token'
      render plain: 'Access denied', status: :forbidden
      false
    end

    # Extracts the bearer token from the Authorization header. Returns an
    # empty string when the header is missing or not in the Bearer scheme,
    # which causes Authenticator.secure_compare to reject without leaking
    # the supplied value into the response or logs.
    def bearer_token
      header = request.headers['Authorization'].to_s
      match = header.match(/\ABearer\s+(.+)\z/i)
      match ? match[1].strip : ''
    end

    def load_project
      @project = Project.find(params[:project_id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'project not found' }, status: :not_found
    end
  end
end

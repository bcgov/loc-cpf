class ApplicationController < ActionController::Base
  protect_from_forgery prepend: true
  include ActionController::MimeResponds

  # before_action :log_request_headers
  before_action :authenticate_user!, except: [:status]

  def authenticate_user!
    log_request_headers
    if Rails.env.development?
      # use a dummy user for development
      user = User.find_or_create_the_dummy_user
    else
      token = request.headers["HTTP_X_USERINFO"]
      return render_unauthorized unless token.present?

      user = User.find_or_create_from_kong(token)
      return render_unauthorized unless user.present?
    end
    sign_in(user, store: false)
  end

  def sso
    redirect_to user_profile_path
  end

  def status
    respond_to do |format|
      format.json { render json: { status: "Batch Geocoder API service is up." } }
      format.html { render plain: "Batch Geocoder API service is up." }
    end 
  end

  private

  def render_unauthorized
    respond_to do |format|
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.html do
        render html: <<~HTML.html_safe, status: :unauthorized
          <!doctype html>
          <html>
            <head><title>401 SSO Unauthorized</title></head>
            <body style="font-family: Arial, sans-serif; padding: 2rem;">
              <h1>401 - SSO Unauthorized</h1>
              <p>You are not authorized to access this resource.</p>
            </body>
          </html>
        HTML
      end
      format.any { render plain: "Unauthorized", status: :unauthorized }
    end
  end

  def log_request_headers
    headers = request.headers.to_h.each_with_object({}) do |(key, value), out|
      next unless key.start_with?("HTTP_") || %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)

      out[key] =
        if key.match?(/HTTP_AUTHORIZATION|HTTP_COOKIE|HTTP_X_CSRF_TOKEN/)
          "[FILTERED]"
        else
          value
        end
    end

    msg = "[RequestHeaders] #{request.request_method} #{request.fullpath} #{headers}"
    Rails.logger.info(msg)
    $stdout.puts(msg)
  end
end

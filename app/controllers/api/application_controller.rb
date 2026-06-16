class Api::ApplicationController < ActionController::API
  include ActionController::MimeResponds

  before_action :authenticate_user!

  # Note: now we have two types of authentication. One from the Kong token in the header, 
  # and another from api_token param for users to authenticate directly with an API token. 
  # We may want to unify these two in the future, but for now we will support both for flexibility.
  def authenticate_user!
    if !request.headers["HTTP_X_CONSUMER_ID"].blank?
      # this is a Kong-authenticated request, we can find or create the user from the Kong consumer
      @user = User.find_or_create_from_consumer(request.headers["HTTP_X_CONSUMER_ID"], request.headers["HTTP_X_CONSUMER_USERNAME"])
      return render_unauthorized unless @user.present?

    elsif !request.headers["HTTP_X_USERINFO"].blank?
      # this is from a SSO (from browser URI)
      token = request.headers["HTTP_X_USERINFO"]
      return render_unauthorized unless token.present?

      @user = User.find_or_create_from_kong(token)
    elsif params[:api_token].present? || request.headers["apikey"].present?
      # this is a direct API token authentication (e.g. from Postman or curl)
      @token = Token.find_by(value: params[:api_token] || request.headers["apikey"])
      @user = @token.present? && @token.isValid? ? @token.user : nil
      
      return render_unauthorized unless @user.present?
    else
        return render_unauthorized
    end

  end

  private

  def render_unauthorized
    respond_to do |format|
      format.json { render json: { error: "Unauthorized" }, status: :unauthorized }
      format.any { render plain: "api_token is missing or invalid.", status: :unauthorized }
    end
  end
end

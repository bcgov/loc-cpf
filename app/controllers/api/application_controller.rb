class Api::ApplicationController < ActionController::API
  include ActionController::MimeResponds

  before_action :authenticate_user!

  def authenticate_user!
    Rails.logger.info request.headers.to_h.inspect
    if !request.headers["HTTP_X_USERINFO"].blank?
      token = request.headers["HTTP_X_USERINFO"]
      return render_unauthorized unless token.present?

      @user = User.find_or_create_from_kong(token)
    elsif params[:api_token].present?
      @token = Token.find_by(value: params[:api_token])
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

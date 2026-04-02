class ApplicationController < ActionController::API
  before_action :authenticate_user!
  
  def authenticate_user!
    token = request.headers["Authorization"]&.split(" ")&.last
    if token.present?
      user_token = Token.find_by(token: token)
      if user_token&.isValid?
        @current_user = user_token.user
      else
        render json: { error: "Unauthorized" }, status: :unauthorized
      end
    else
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end
end

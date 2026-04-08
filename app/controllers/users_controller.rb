class UsersController < ApplicationController

  # list api tokens for the current user
  def tokens
    respond_to do |format|
      format.json { render json: current_user.tokens.select(:id, :expire_at, :created_at) }
      format.html { @tokens = current_user.tokens.order(created_at: :desc) }
    end
  end

  def create_token
    token = current_user.tokens.create(token: SecureRandom.hex(32), expire_at: params[:expire_at])
    if token.persisted?
      render json: { id: token.id, expire_at: token.expire_at, created_at: token.created_at }, status: :created
    else
      render json: { error: "Failed to create token" }, status: :unprocessable_entity
    end
  end

  def revoke_token
    token = current_user.tokens.find_by(id: params[:id])
    if token
      token.destroy
      render json: { message: "Token revoked" }
    else
      render json: { error: "Token not found" }, status: :not_found
    end
  end

  # show current user profile
  def show
    respond_to do |format|
      format.json { render json: current_user.slice(:id, :email, :display_name, :idir_username, :admin) }
      format.html {}
    end
  end
end
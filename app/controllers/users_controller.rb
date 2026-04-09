class UsersController < ApplicationController
  layout "user"

  # list api tokens for the current user
  def tokens
    @tokens = current_user.tokens.order(created_at: :desc)

    respond_to do |format|
      format.json { render json: @tokens.select(:id, :value, :expired_at, :created_at) }
      format.html
    end
  end

  def create_token
    token = current_user.tokens.new(expired_at: params[:expired_at].presence)

    if token.save
      respond_to do |format|
        format.json { render json: { id: token.id, value: token.value, expired_at: token.expired_at, created_at: token.created_at }, status: :created }
        format.html { redirect_to tokens_users_path(notice: "Token created.") }
      end
    else
      message = token.errors.full_messages.to_sentence.presence || "Failed to create token"

      respond_to do |format|
        format.json { render json: { error: message }, status: :unprocessable_entity }
        format.html { redirect_to tokens_users_path(alert: message) }
      end
    end
  end

  def revoke_token
    token = current_user.tokens.find_by(id: params[:id])

    if token
      token.destroy
      respond_to do |format|
        format.json { render json: { message: "Token revoked" } }
        format.html { redirect_to tokens_users_path(notice: "Token revoked.") }
      end
    else
      respond_to do |format|
        format.json { render json: { error: "Token not found" }, status: :not_found }
        format.html { redirect_to tokens_users_path(alert: "Token not found.") }
      end
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
class Admin::UsersController < Admin::ApplicationController
  USERS_PER_PAGE = 10

  def index
    sort_column = params[:sort] || "created_at"
    sort_direction = params[:direction] || "desc"
    
    valid_columns = %w[id display_name email created_at]
    sort_column = "created_at" unless valid_columns.include?(sort_column)
    sort_direction = "desc" if sort_direction != "asc"

    @users = User.order("#{sort_column} #{sort_direction}").page(params[:page]).per(USERS_PER_PAGE)
    @sort_column = sort_column
    @sort_direction = sort_direction
  end

  def tokens
    @user = User.find_by(id: params[:id])
    if @user.nil?
      redirect_to admin_users_path, alert: "User not found"
    else
      @tokens = @user.tokens.order(created_at: :desc)
    end
  end

  def create_token
    @user = User.find_by(id: params[:id])
    token = @user.tokens.new(expired_at: params[:expired_at].presence, value: params[:value].presence)

    if token.save
      respond_to do |format|
        format.json { render json: { id: token.id, value: token.value, expired_at: token.expired_at, created_at: token.created_at }, status: :created }
        format.html { redirect_to tokens_admin_user_path(@user), notice: "Token created." }
      end
    else
      message = token.errors.full_messages.to_sentence.presence || "Failed to create token"

      respond_to do |format|
        format.json { render json: { error: message }, status: :unprocessable_entity }
        format.html { redirect_to tokens_admin_user_path(@user), alert: message }
      end
    end
  end

  def revoke_token
    token = Token.find_by(id: params[:id])
    @user = token.user if token

    if token
      token.destroy
      respond_to do |format|
        format.json { render json: { message: "Token revoked" } }
        format.html { redirect_to tokens_admin_user_path(@user), notice: "Token revoked." }
      end
    else
      respond_to do |format|
        format.json { render json: { error: "Token not found" }, status: :not_found }
        format.html { redirect_to tokens_admin_user_path(@user), alert: "Token not found." }
      end
    end
  end

  def create
    # This action is used for importing users without IDIR from legacy system. It has minial implementation and is not intended for regular use.
    @user = User.new(email: params[:email], display_name: params[:display_name], client_id: params[:client_id])
    @user.password = Devise.friendly_token[0, 20]
    respond_to do |format|
      format.html {
        if @user.save
          redirect_to admin_users_path, notice: "User created."
        else
          redirect_to admin_users_path, alert: @user.errors.full_messages.to_sentence.presence || "Failed to create user."
        end
      }
    end
  end
  
end
class SessionsController < ApplicationController
  skip_before_action :verify_authenticity_token, only: :create

  def create
    user = User.find_by(email: params[:email])
    if user&.authenticate(params[:password])
      session[:user_id] = user.id
      respond_to do |format|
        format.html { redirect_to root_path }
        format.json { render json: { user_id: user.id }, status: :ok }
      end
    else
      reason = if user.nil?
                 "user_not_found"
      elsif params[:password].blank?
                 "password_blank"
      else
                 "password_mismatch"
      end
      Rails.logger.warn("[bench-auth-401] reason=#{reason} email=#{params[:email].inspect} pwd_len=#{params[:password].to_s.length}")
      respond_to do |format|
        format.html { redirect_to root_path, alert: "Invalid credentials" }
        format.json { render json: { error: "Invalid credentials", reason: reason }, status: :unauthorized }
      end
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path
  end
end

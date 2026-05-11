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
      respond_to do |format|
        format.html { redirect_to root_path, alert: "Invalid credentials" }
        format.json { render json: { error: "Invalid credentials" }, status: :unauthorized }
      end
    end
  end

  def destroy
    session.delete(:user_id)
    redirect_to root_path
  end
end

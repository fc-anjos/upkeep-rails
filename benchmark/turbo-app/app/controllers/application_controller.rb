class ApplicationController < ActionController::Base
  allow_browser versions: :modern

  before_action :set_current_user
  prepend_around_action :instrument_bench_request

  private

  def set_current_user
    Current.user = User.find_by(id: session[:user_id])
  end

  def require_login
    redirect_to root_path unless Current.user
  end

  def instrument_bench_request(&action)
    BenchMetrics.instrument_controller_request(self, &action)
  end
end

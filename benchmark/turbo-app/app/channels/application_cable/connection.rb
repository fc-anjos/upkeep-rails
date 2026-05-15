module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      BenchMetrics.instrument_cable_connect(self) do
        self.current_user = find_verified_user
      end
    end

    private

    def find_verified_user
      user_id = request.session[:user_id] || cookies.signed[:user_id]
      User.find_by(id: user_id)
    end
  end
end

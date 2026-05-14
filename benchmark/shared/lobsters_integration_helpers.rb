# frozen_string_literal: true

module LobstersIntegrationHelpers
  XHR_HEADERS = { "HTTP_X_REQUESTED_WITH" => "XMLHttpRequest" }.freeze

  def sign_in_as(user)
    post "/login", params: {
      email: user.email,
      password: LobstersSeedData::PASSWORD
    }

    assert_redirected_to "/"
  end

  def seeded_story
    Story.order(:id).first
  end

  def seeded_user(offset: 10)
    User.where("email LIKE ?", "user%@bench.test").order(:id).offset(offset).first
  end
end

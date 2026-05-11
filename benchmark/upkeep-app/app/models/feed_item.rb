class FeedItem < ApplicationRecord
  # Feed rows are shared records. Benchmark partials choose whether to
  # render anonymous output, Current-dependent output, or mixed regions.
  def user_label
    user = Current.user
    return "anonymous" unless user

    "signed:#{user.email}"
  end

  def current_vote_label
    user = Current.user
    return "vote:anonymous" unless user

    "vote:user-#{user.id}:item-#{id}"
  end
end

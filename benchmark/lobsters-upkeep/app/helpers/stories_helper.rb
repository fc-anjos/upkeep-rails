module StoriesHelper
  def show_guidelines?
    return true if !@user

    return true if @user.stories_submitted_count <= 5

    if Moderation.joins(:story)
                 .where(
                   "stories.user_id = ? AND moderations.created_at > ?",
                   @user.id,
                   5.days.ago
                 ).exists?
      return true
    end

    false
  end

  def is_unread?(comment)
    return false if !@user || !@ribbon

    (comment.created_at > @ribbon.updated_at) && (comment.user_id != @user.id)
  end
end

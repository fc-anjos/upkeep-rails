class CreateFeedItems < ActiveRecord::Migration[8.1]
  # `classifier/identity_free_feed` workload: an anonymous public feed with no
  # authenticated user, no CSRF on the update path, and no per-row
  # identity relation. Rows carry only `title` + `body` so the render
  # partial is structurally identity-free — the classifier must
  # resolve `_feed_item.html.erb` to `:none`, which is the payoff the
  # profile measures.
  def change
    create_table :feed_items do |t|
      t.string :title, null: false
      t.text :body, null: false
      t.timestamps
    end
  end
end

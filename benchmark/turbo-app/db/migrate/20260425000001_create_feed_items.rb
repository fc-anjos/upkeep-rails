# frozen_string_literal: true

class CreateFeedItems < ActiveRecord::Migration[8.1]
  def change
    create_table :feed_items do |t|
      t.string :title, null: false
      t.text :body, null: false
      t.timestamps
    end
  end
end

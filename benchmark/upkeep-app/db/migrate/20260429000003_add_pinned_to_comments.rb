class AddPinnedToComments < ActiveRecord::Migration[8.1]
  def change
    add_column :comments, :pinned, :boolean, default: false, null: false
  end
end

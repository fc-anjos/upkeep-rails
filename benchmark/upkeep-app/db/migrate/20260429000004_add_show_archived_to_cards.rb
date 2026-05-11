class AddShowArchivedToCards < ActiveRecord::Migration[8.1]
  def change
    add_column :cards, :show_archived, :boolean, default: true, null: false
  end
end

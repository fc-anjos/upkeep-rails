class AddStiToComments < ActiveRecord::Migration[8.1]
  def change
    add_column :comments, :type, :string
  end
end

class CreateComments < ActiveRecord::Migration[8.1]
  def change
    create_table :comments do |t|
      t.references :card, null: false, foreign_key: true
      t.string :body, null: false
      t.timestamps
    end
  end
end

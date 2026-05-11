class CreateBenchmarkSchema < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :password_digest, null: false
      t.timestamps
    end
    add_index :users, :email, unique: true

    create_table :rooms do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :room_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :room, null: false, foreign_key: true
      t.timestamps
    end
    add_index :room_memberships, [ :user_id, :room_id ], unique: true

    create_table :messages do |t|
      t.text :body, null: false
      t.references :room, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end

    create_table :boards do |t|
      t.string :name, null: false
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    create_table :cards do |t|
      t.string :title, null: false
      t.string :status, null: false, default: "todo"
      t.references :board, null: false, foreign_key: true
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end

    create_table :accesses do |t|
      t.references :board, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :accesses, [ :board_id, :user_id ], unique: true
  end
end

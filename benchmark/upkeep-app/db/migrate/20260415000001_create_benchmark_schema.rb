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

    create_table :upkeep_subscriptions, id: :string do |t|
      t.string :subscriber_id, null: false
      t.json :recorder_snapshot, null: false
      t.json :metadata
      t.string :subscription_shape_key
      t.timestamps
    end
    add_index :upkeep_subscriptions, :subscriber_id
    add_index :upkeep_subscriptions, :subscription_shape_key, name: "idx_upkeep_subscriptions_on_shape_key"

    create_table :upkeep_subscription_index_entries do |t|
      t.string :subscription_id, null: false
      t.string :lookup_key_digest, null: false
      t.string :dependency_source, null: false
      t.string :lookup_table, null: false
      t.json :lookup_record_id_snapshot
      t.string :lookup_attribute, null: false
      t.string :dependency_table, null: false
      t.string :dependency_predicate_digest
      t.json :dependency_metadata_snapshot
      t.json :owner_ids_snapshot, null: false
      t.timestamps
    end
    add_index :upkeep_subscription_index_entries, :subscription_id
    add_index :upkeep_subscription_index_entries, :lookup_key_digest
    add_foreign_key :upkeep_subscription_index_entries, :upkeep_subscriptions, column: :subscription_id, on_delete: :cascade

    create_table :upkeep_subscription_shape_index_entries do |t|
      t.string :subscription_shape_key, null: false
      t.string :lookup_key_digest, null: false
      t.string :dependency_source, null: false
      t.string :lookup_table, null: false
      t.json :lookup_record_id_snapshot
      t.string :lookup_attribute, null: false
      t.string :dependency_table, null: false
      t.string :dependency_predicate_digest
      t.json :dependency_metadata_snapshot
      t.json :owner_ids_snapshot, null: false
      t.timestamps
    end
    add_index :upkeep_subscription_shape_index_entries, :subscription_shape_key, name: "idx_upkeep_sub_shape_entries_on_shape_key"
    add_index :upkeep_subscription_shape_index_entries, :lookup_key_digest, name: "idx_upkeep_sub_shape_entries_on_lookup_digest"
  end
end

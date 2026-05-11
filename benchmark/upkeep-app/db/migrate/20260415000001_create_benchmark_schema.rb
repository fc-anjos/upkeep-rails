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
      t.integer  :digest_version, null: false
      t.binary   :read_set_bytes, null: false
      t.string   :fragment_address, null: false
      t.string   :subscription_url
      t.string   :envelope_digest, null: false
      t.json     :rack_env
      t.json     :context
      t.binary   :snapshot
      t.json     :snapshot_data
      t.string   :snapshot_hash
      t.json     :fragment_locals
      t.json     :fragment_record_index
      t.json     :fragment_bindings
      t.json     :fragment_hashes
      t.json     :fragment_locals_digests
      t.json     :fragment_region_digests
      t.json     :fragment_slot_states
      t.string   :tenant_key
      t.integer  :refcount, default: 0, null: false
      t.datetime :created_at
      t.datetime :expires_at
    end

    create_table :upkeep_endpoints, id: :string do |t|
      t.string   :subscription_id, null: false
      t.string   :originator_token, null: false
      t.string   :transport_address
      t.string   :node_id
      t.boolean  :connected
      t.boolean  :active
      t.datetime :expires_at
      t.datetime :created_at
      t.datetime :updated_at
    end
    add_index :upkeep_endpoints, :subscription_id
    add_index :upkeep_endpoints, :originator_token
    add_foreign_key :upkeep_endpoints, :upkeep_subscriptions, column: :subscription_id, on_delete: :cascade
  end
end

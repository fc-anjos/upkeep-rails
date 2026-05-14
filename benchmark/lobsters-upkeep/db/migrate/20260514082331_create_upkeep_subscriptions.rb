class CreateUpkeepSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :upkeep_subscriptions, id: :string do |t|
      t.string :subscriber_id, null: false
      t.json :recorder_snapshot, null: false
      t.json :metadata
      t.timestamps
    end
    add_index :upkeep_subscriptions, :subscriber_id

    create_table :upkeep_subscription_index_entries do |t|
      t.string :subscription_id, null: false
      t.string :lookup_key_digest, null: false
      t.json :lookup_key_snapshot, null: false
      t.json :owner_id_snapshot, null: false
      t.json :dependency_cache_key_snapshot, null: false
      t.json :dependency_snapshot, null: false
      t.timestamps
    end
    add_index :upkeep_subscription_index_entries, :subscription_id
    add_index :upkeep_subscription_index_entries, :lookup_key_digest
    add_foreign_key :upkeep_subscription_index_entries,
      :upkeep_subscriptions,
      column: :subscription_id,
      on_delete: :cascade
  end
end

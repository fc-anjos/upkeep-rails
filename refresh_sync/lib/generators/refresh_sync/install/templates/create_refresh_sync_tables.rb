class CreateRefreshSyncTables < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
  def change
    create_table :refresh_sync_cohorts do |t|
      t.string :stream, null: false
      t.string :deploy_key, null: false
      t.text :read_set_json, null: false
      t.text :surfaces_json, null: false, default: "[]"
      t.text :tables_json, null: false, default: "[]"
      t.text :baselines_json, null: false, default: "{}"
      t.datetime :heartbeat_at
      # Stamped by the first verified cable subscription; later subscriptions
      # on the same stream are reconnects and trigger one resync refresh.
      t.datetime :activated_at
    end
    add_index :refresh_sync_cohorts, :stream, unique: true

    create_table :refresh_sync_surfaces do |t|
      t.string :name, null: false
      t.string :deploy_key, null: false
      # Duplicated out of state_json so the dispatch-time claim is a single
      # atomic UPDATE ... WHERE status IN ('shared','region_shared').
      t.string :status, null: false, default: "observing"
      t.datetime :dispatched_at
      t.text :state_json
    end
    add_index :refresh_sync_surfaces, [:name, :deploy_key], unique: true

    create_table :refresh_sync_claims do |t|
      t.string :claim_key, null: false
      t.datetime :created_at
    end
    add_index :refresh_sync_claims, :claim_key, unique: true
  end
end

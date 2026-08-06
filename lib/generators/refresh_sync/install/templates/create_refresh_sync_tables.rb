class CreateRefreshSyncTables < ActiveRecord::Migration[<%= ActiveRecord::Migration.current_version %>]
  def change
    create_table :refresh_sync_cohorts do |t|
      t.string :stream, null: false
      t.string :deploy_key, null: false
      # Viewer identity (nil for unauthenticated pages): the key per-member
      # divergence ejection and re-admission act on.
      t.string :identity
      t.text :read_set_json, null: false
      t.text :surfaces_json, null: false, default: "[]"
      t.text :baselines_json, null: false, default: "{}"
      t.datetime :heartbeat_at
      # Stamped by the first verified cable subscription; later subscriptions
      # on the same stream are reconnects and trigger one resync refresh.
      t.datetime :activated_at
    end
    add_index :refresh_sync_cohorts, :stream, unique: true

    # Indexed inverse of each cohort's read-set table list: write matching
    # is an indexed join, never a JSON scan.
    create_table :refresh_sync_cohort_tables do |t|
      t.bigint :cohort_id, null: false
      t.string :table_name, null: false
    end
    add_index :refresh_sync_cohort_tables, :table_name
    add_index :refresh_sync_cohort_tables, :cohort_id

    create_table :refresh_sync_surfaces do |t|
      t.string :name, null: false
      t.string :deploy_key, null: false
      # Duplicated out of state_json so the dispatch-time claim is a single
      # atomic UPDATE ... WHERE status IN ('shared','region_shared').
      t.string :status, null: false, default: "observing"
      t.datetime :dispatched_at
      # Optimistic lock: concurrent surface-state persists from different
      # processes reload-and-reapply instead of losing an update.
      t.integer :lock_version, null: false, default: 0
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

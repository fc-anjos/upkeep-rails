# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_04_29_000004) do
  create_table "accesses", force: :cascade do |t|
    t.integer "board_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["board_id", "user_id"], name: "index_accesses_on_board_id_and_user_id", unique: true
    t.index ["board_id"], name: "index_accesses_on_board_id"
    t.index ["user_id"], name: "index_accesses_on_user_id"
  end

  create_table "boards", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creator_id", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_boards_on_creator_id"
  end

  create_table "cards", force: :cascade do |t|
    t.integer "board_id", null: false
    t.datetime "created_at", null: false
    t.integer "creator_id", null: false
    t.boolean "show_archived", default: true, null: false
    t.string "status", default: "todo", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["board_id"], name: "index_cards_on_board_id"
    t.index ["creator_id"], name: "index_cards_on_creator_id"
  end

  create_table "comments", force: :cascade do |t|
    t.string "body", null: false
    t.integer "card_id", null: false
    t.datetime "created_at", null: false
    t.boolean "pinned", default: false, null: false
    t.string "type"
    t.datetime "updated_at", null: false
    t.index ["card_id"], name: "index_comments_on_card_id"
  end

  create_table "feed_items", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
  end

  create_table "messages", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.integer "room_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["room_id"], name: "index_messages_on_room_id"
    t.index ["user_id"], name: "index_messages_on_user_id"
  end

  create_table "room_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "room_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["room_id"], name: "index_room_memberships_on_room_id"
    t.index ["user_id", "room_id"], name: "index_room_memberships_on_user_id_and_room_id", unique: true
    t.index ["user_id"], name: "index_room_memberships_on_user_id"
  end

  create_table "rooms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "upkeep_subscription_index_entries", force: :cascade do |t|
    t.json "dependency_cache_key_snapshot", null: false
    t.json "dependency_snapshot", null: false
    t.datetime "created_at", null: false
    t.string "lookup_key_digest", null: false
    t.json "lookup_key_snapshot", null: false
    t.json "owner_id_snapshot", null: false
    t.string "subscription_id", null: false
    t.datetime "updated_at", null: false
    t.index ["lookup_key_digest"], name: "index_upkeep_subscription_index_entries_on_lookup_key_digest"
    t.index ["subscription_id"], name: "index_upkeep_subscription_index_entries_on_subscription_id"
  end

  create_table "upkeep_subscriptions", id: :string, force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "metadata"
    t.json "recorder_snapshot", null: false
    t.string "subscriber_id", null: false
    t.datetime "updated_at", null: false
    t.index ["subscriber_id"], name: "index_upkeep_subscriptions_on_subscriber_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "accesses", "boards"
  add_foreign_key "accesses", "users"
  add_foreign_key "boards", "users", column: "creator_id"
  add_foreign_key "cards", "boards"
  add_foreign_key "cards", "users", column: "creator_id"
  add_foreign_key "comments", "cards"
  add_foreign_key "messages", "rooms"
  add_foreign_key "messages", "users"
  add_foreign_key "room_memberships", "rooms"
  add_foreign_key "room_memberships", "users"
  add_foreign_key "upkeep_subscription_index_entries", "upkeep_subscriptions", column: "subscription_id", on_delete: :cascade
end

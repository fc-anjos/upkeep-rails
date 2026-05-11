# frozen_string_literal: true

require "active_record"

module Upkeep
  module Domain
    class User < ActiveRecord::Base
      self.table_name = "users"

      def can_see_card_value?(card)
        card.value <= value_limit
      end
    end

    class Board < ActiveRecord::Base
      self.table_name = "boards"

      has_many :cards, class_name: "Upkeep::Domain::Card", foreign_key: :board_id
    end

    class Card < ActiveRecord::Base
      self.table_name = "cards"

      belongs_to :board, class_name: "Upkeep::Domain::Board"
    end

    CardSummary = Data.define(:id, :title)

    class CardPresenter
      def initialize(card)
        @card = card
      end

      def title = @card.title

      def status_label
        @card.status == "done" ? "Done" : "Open"
      end
    end

    class SecureCardPresenter
      def initialize(card)
        @card = card
      end

      def title = @card.title

      def value_content
        Runtime::Current.user.can_see_card_value?(@card) ? "$#{@card.value}" : "Hidden"
      end
    end

    module Database
      module_function

      def reset!
        ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
        ActiveRecord::Base.logger = nil
        ActiveRecord::Schema.verbose = false

        ActiveRecord::Schema.define do
          create_table :users, force: true do |table|
            table.string :name, null: false
            table.integer :value_limit, null: false
          end

          create_table :boards, force: true do |table|
            table.string :name, null: false
          end

          create_table :cards, force: true do |table|
            table.references :board, null: false
            table.string :title, null: false
            table.string :status, null: false
            table.integer :position, null: false
            table.integer :value, null: false
          end
        end
      end

      def seed!
        Runtime::ChangeLog.reset

        User.create!(name: "Alice", value_limit: 100)
        User.create!(name: "Bob", value_limit: 50)

        board = Board.create!(name: "Launch")
        Card.create!(board: board, title: "Plan", status: "open", position: 1, value: 80)
        Card.create!(board: board, title: "Build", status: "open", position: 2, value: 40)
        Card.create!(board: board, title: "Review", status: "open", position: 3, value: 120)

        Runtime::ChangeLog.reset
      end
    end
  end
end


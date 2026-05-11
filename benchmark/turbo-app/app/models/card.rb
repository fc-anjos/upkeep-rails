class Card < ApplicationRecord
  belongs_to :board
  belongs_to :creator, class_name: "User"

  broadcasts_refreshes_to :board
end

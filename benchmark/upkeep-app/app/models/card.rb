class Card < ApplicationRecord
  belongs_to :board, touch: true
  belongs_to :creator, class_name: "User"
  has_many :comments, dependent: :destroy
end

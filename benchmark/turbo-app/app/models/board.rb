class Board < ApplicationRecord
  belongs_to :creator, class_name: "User"
  has_many :cards, dependent: :destroy
  has_many :accesses, dependent: :destroy
  has_many :users, through: :accesses

  def accessible_to?(user)
    accesses.exists?(user: user)
  end
end

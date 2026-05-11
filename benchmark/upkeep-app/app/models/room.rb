class Room < ApplicationRecord
  has_many :room_memberships, dependent: :destroy
  has_many :users, through: :room_memberships
  has_many :messages, dependent: :destroy
end

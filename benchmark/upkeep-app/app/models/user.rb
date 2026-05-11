class User < ApplicationRecord
  has_secure_password

  has_many :room_memberships, dependent: :destroy
  has_many :rooms, through: :room_memberships
  has_many :messages, dependent: :destroy
  has_many :accesses, dependent: :destroy
  has_many :accessible_boards, through: :accesses, source: :board
end

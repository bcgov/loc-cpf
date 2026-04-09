class Token < ApplicationRecord
  MAX_TOKENS_PER_USER = 10

  belongs_to :user
  before_create :generate_token_value
  validate :user_token_limit_not_exceeded, on: :create

  def generate_token_value
    self.value = SecureRandom.hex(16)
  end

  def isValid?
    self.expired_at.nil? || self.expired_at > Time.now
  end

  private

  def user_token_limit_not_exceeded
    return unless user && user.tokens.count >= MAX_TOKENS_PER_USER

    errors.add(:base, "Maximum #{MAX_TOKENS_PER_USER} tokens allowed per user")
  end
end

class Token < ApplicationRecord
  belongs_to :user

  def isValid?
    self.expire_at.nil? || self.expire_at > Time.now
  end
end

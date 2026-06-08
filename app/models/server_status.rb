class ServerStatus < ApplicationRecord
  enum :status, { running: "running", paused: "paused" }

  validates :status, presence: true

  def self.current
    first_or_create!(status: "running")
  end

  def self.toggle!
    record = current
    record.status = record.paused? ? "running" : "paused"
    record.save!
    record
  end

  def self.paused?
    current.paused?
  end
end

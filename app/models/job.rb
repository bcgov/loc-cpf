class Job < ApplicationRecord
  belongs_to :user
  has_one_attached :input_file, dependent: :destroy
  has_one_attached :output_file, dependent: :destroy

  before_destroy :purge_attachments

  MAX_ATTEMPTS = 10

  before_create :set_default_values

  def get_resechueduled_job
    if self.reschedued_jid.present?
      Job.find_by(id: self.reschedued_jid)
    else
      nil
    end
  end

  def set_default_values
    self.attempt_count ||= 0
    self.notification_email ||= user.email
  end

  def reach_max_attempts?
    self.attempt_count >= MAX_ATTEMPTS
  end

  def get_status
    if self.completed_at.present?
      self.success ? "completed" : "failed"
    elsif self.started_at.present?
      self.reach_max_attempts? ? "terminated" : "in_progress"
    elsif self.scheduled_at.present? && self.scheduled_at > Time.now
      "scheduled"
    else
      "submitted"
    end
  end

  private

  def purge_attachments
    input_file.purge if input_file.attached?
    output_file.purge if output_file.attached?
  end
end

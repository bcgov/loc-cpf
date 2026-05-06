class Job < ApplicationRecord
  belongs_to :user
  has_one_attached :input_file, dependent: :destroy
  has_one_attached :output_file, dependent: :destroy
  has_one_attached :error_file, dependent: :destroy

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
    self.attempt_count ||= 1
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

  def is_enqueued_or_scheduled_in_sidekiq?
    return false if jid.blank?
    Sidekiq::ScheduledSet.new.find_job(jid).present? || Sidekiq::Queue.new.find_job(jid).present?
  end

  def cancel!
    # only allow canceling if job is not completed yet and it is in sidekiq queue or scheduled
    if completed_at.present?
      return false
    end

    if jid.present? && get_status != "scheduled"
      Sidekiq::ScheduledSet.new.find_job(jid)&.delete || Sidekiq::Queue.new.find_job(jid)&.delete
    end

    update!(
      completed_at: Time.now,
      success: false,
      error_message: "Job was cancelled"
    )
  end

  private

  def purge_attachments
    input_file.purge if input_file.attached?
    output_file.purge if output_file.attached?
    error_file.purge if error_file.attached?
  end
end

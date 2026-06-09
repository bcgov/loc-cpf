require 'sidekiq/api'

class Job < ApplicationRecord
  belongs_to :user
  has_one_attached :input_file, dependent: :destroy
  has_one_attached :output_file, dependent: :destroy
  has_one_attached :error_file, dependent: :destroy

  before_destroy :purge_attachments

  MAX_ATTEMPTS = 10

  before_create :set_default_values

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

  # used for reconciler to determine if the job is eligible for retry or recovery
  def is_terminal_status?
     %w[completed failed canceled].include?(get_status)
  end

  def is_missing_required_artifacts?
    if self.kind_of?(MasterJob)
      return false unless self.master_job.present?
    end
    self.input_file.attached? && !self.input_file.blob.present?
  end

  # deprecated
  def is_stale?
    return false if is_terminal_status?
    return false if started_at.blank?
    return false if sidekiq_worker_info.present?
    true
  end

  def sidekiq_worker_info
    return nil if jid.blank?

    Sidekiq::Workers.new.each do |process_id, thread_id, work|
      payload = work["payload"] || {}
      next unless payload["jid"] == jid

      return {
        process_id: process_id,
        thread_id: thread_id,
        run_at: (Time.at(work["run_at"]) if work["run_at"])
      }
    end

    nil
  rescue => e
    Rails.logger.warn("sidekiq worker lookup failed for job=#{id}, jid=#{jid}: #{e.message}")
    nil
  end

  def get_queue_name
    return nil if jid.blank?

    return "Running" if sidekiq_worker_info.present?
    return "ScheduledSet" if Sidekiq::ScheduledSet.new.find_job(jid).present?
    return "RetrySet" if Sidekiq::RetrySet.new.find_job(jid).present?
    return "DeadSet" if Sidekiq::DeadSet.new.find_job(jid).present?

    queue = Sidekiq::Queue.all.find { |q| q.find_job(jid).present? }
    queue&.name
  rescue => e
    Rails.logger.warn("sidekiq queue lookup failed for job=#{id}, jid=#{jid}: #{e.message}")
    nil
  end

  def missing_from_all_sidekiq_states?
    return true if jid.blank?
    return false if sidekiq_worker_info.present?
    return false if sidekiq_job_exists?(jid)

    true
  end

  private

  def sidekiq_job_exists?(jid)
    return true if Sidekiq::ScheduledSet.new.find_job(jid).present?
    return true if Sidekiq::RetrySet.new.find_job(jid).present?
    return true if Sidekiq::DeadSet.new.find_job(jid).present?
    return true if Sidekiq::Queue.all.any? { |q| q.find_job(jid).present? }

    false
  rescue => e
    Rails.logger.warn("sidekiq lookup failed for job=#{id}, jid=#{jid}: #{e.message}")
    false
  end

  def purge_attachments
    input_file.purge if input_file.attached?
    output_file.purge if output_file.attached?
    error_file.purge if error_file.attached?
  end
end

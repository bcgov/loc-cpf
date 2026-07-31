class GeocoderMergeJob < MergeJob

  def sidekiq_status
    return "completed" if completed_at.present?
    return "not_enqueued" if jid.blank?

    require "sidekiq/api"

    return "running" if Sidekiq::Workers.new.any? { |_p, _t, w| w.dig("payload", "jid") == jid }
    return "queued" if Sidekiq::Queue.new("geocoder_worker_sk_job").find_job(jid)
    return "scheduled" if Sidekiq::ScheduledSet.new.find_job(jid)
    return "retrying" if Sidekiq::RetrySet.new.find_job(jid)
    return "dead" if Sidekiq::DeadSet.new.find_job(jid)

    "not_found"
  rescue => e
    Rails.logger.warn("worker sidekiq_status lookup failed for job=#{id}, jid=#{jid}: #{e.message}")
    "unknown"
  end

  def enqueue_sidekiq_job
    # submit a sidekiq job to process this merge job
    return if jid.present?

    run_at = 2.seconds.from_now
    enqueued_jid = GeocoderMergeSkJob.perform_at(run_at, id)
    # store jid_history as JSON text: ["jid1","jid2",...]
    history =
      begin
        raw = self.jid_history
        raw.present? ? JSON.parse(raw) : []
      rescue JSON::ParserError
        []
      end
    history << enqueued_jid

    update_columns(
      jid_history: history.to_json,
      jid: enqueued_jid,
      scheduled_at: run_at
    )
  end

  def reenqueue_sidekiq_job
    # this method reset sidekiq data for this job so it can be re-enqueued
    # it also increase the attempt_count for retry limit tracking
    Sidekiq::RetrySet.new.find_job(self.jid)&.delete
    Sidekiq::ScheduledSet.new.find_job(self.jid)&.delete
    Sidekiq::Queue.new("geocoder_worker_sk_job").find_job(self.jid)&.delete
    self.jid = nil
    self.started_at = nil
    self.completed_at = nil
    self.scheduled_at = nil
    self.result_created_at = nil
    self.total_rows = nil
    self.success = nil
    self.error_message = nil
    self.output_file.purge if self.output_file.attached?
    self.error_file.purge if self.error_file.attached?

    self.attempt_count = (self.attempt_count || 0) + 1
    self.save!
    # make sure the master job is aware of the re-enqueue action and can update its status accordingly; 
    # this is important for the reconciler to have the correct view of the system state and make informed decisions on recovery actions.
    self.master_job.check_worker_jobs_completion if self.master_job.present?
    self.enqueue_sidekiq_job 
  end

  def delete_sidekiq_job
    Sidekiq::RetrySet.new.find_job(self.jid)&.delete
    Sidekiq::ScheduledSet.new.find_job(self.jid)&.delete
    Sidekiq::Queue.new("geocoder_worker_sk_job").find_job(self.jid)&.delete
  end
end
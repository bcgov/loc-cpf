class GeocoderWorkerJob < WorkerJob
  # ...existing code...

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
    return if jid.present?

    run_at = 10.seconds.from_now
    enqueued_jid = GeocoderWorkerSkJob.perform_at(run_at, id)
    update_columns(jid: enqueued_jid, scheduled_at: run_at)
  end
end
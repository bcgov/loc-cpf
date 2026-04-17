class GeocoderWorkerJob < WorkerJob

  def enqueue_sidekiq_job
    return if jid.present?

    run_at = 10.seconds.from_now
    enqueued_jid = GeocoderWorkerSkJob.perform_at(run_at, id)
    update_columns(jid: enqueued_jid, scheduled_at: run_at)
  end
end
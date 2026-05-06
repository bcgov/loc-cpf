require "csv"
require "stringio"

class GeocoderMasterJob < MasterJob
  # after_commit :enqueue_sidekiq_job, on: :create
  # after_commit :generate_result_file_if_ready, on: :update
  

  def to_user_json
    {
      id: id,
      status: self.get_status,
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
      total_rows: total_rows,
      total_worker_jobs: total_jobs,
      completed_worker_jobs: completed_jobs,
      input_file_url: attachment_download_url(input_file),
      output_file_url: attachment_download_url(output_file),
      error_file_url: attachment_download_url(error_file),
      error_message: error_message,
      options: api_options
    }
  end

  def enqueue_sidekiq_job
    return if jid.present?

    run_at = 5.seconds.from_now
    enqueued_jid = GeocoderMasterSkJob.perform_at(run_at, id)
    update_columns(jid: enqueued_jid, scheduled_at: run_at)
  end

  # generate the final output file if all worker jobs are completed, and update the master job's output_file attachment and completed_at timestamp
  def generate_result_file
    return if self.success === false # if master job already marked as failed, skip result generation
    return if result_created_at.present? && output_file.attached?
    return unless total_jobs.present? && total_jobs != 0 && total_jobs == completed_jobs

    endpoint = API_PROVIDERS[0]["endpoints"].find { |e| e["name"] == "Geocode" }
    output_headers = endpoint["output_headers"] || []
    raise "output_headers not configured for Geocode endpoint" if output_headers.empty?

    combined_csv = CSV.generate do |csv|
      csv << output_headers

      worker_jobs.order(:id).each do |worker_job|
        next unless worker_job.output_file.attached?

        worker_job.output_file.open do |file|
          CSV.parse(file.read, headers: true).each do |row|
            csv << output_headers.map { |header| row[header] }
          end
        end
      end
    end

    output_file.attach(
      io: StringIO.new(combined_csv),
      filename: "job_#{id}_output.csv",
      content_type: "text/csv"
    )

    error_headers = ["sequenceNumber", "yourId", "addressString", "errorMessage"]
    failed_rows = 0
    combined_error_csv = CSV.generate do |csv|
      csv << error_headers
      worker_jobs.order(:id).each do |worker_job|
        next unless worker_job.error_file.attached?

        worker_job.error_file.open do |file|
          CSV.parse(file.read, headers: true).each do |row|
            values = error_headers.map { |h| row[h] }
            next if values.all?(&:blank?)

            csv << values
            failed_rows += 1
          end
        end
      end
    end

    if failed_rows > 0
      error_file.attach(
        io: StringIO.new(combined_error_csv),
        filename: "job_#{id}_errors.csv",
        content_type: "text/csv"
      )
      update_columns(result_created_at: Time.current, error_message: "Completed with #{failed_rows} failed rows")
    else
      error_file.purge if error_file.attached?
      update_columns(result_created_at: Time.current, error_message: nil)
    end
  end

  def sidekiq_status
    return "completed" if completed_at.present?
    return "not_enqueued" if jid.blank?

    require "sidekiq/api"

    return "running" if Sidekiq::Workers.new.any? { |_p, _t, w| w.dig("payload", "jid") == jid }
    return "queued" if Sidekiq::Queue.new("geocoder_master_sk_job").find_job(jid)
    return "scheduled" if Sidekiq::ScheduledSet.new.find_job(jid)
    return "retrying" if Sidekiq::RetrySet.new.find_job(jid)
    return "dead" if Sidekiq::DeadSet.new.find_job(jid)

    "not_found"
  rescue => e
    Rails.logger.warn("master sidekiq_status lookup failed for job=#{id}, jid=#{jid}: #{e.message}")
    "unknown"
  end

  private

  def attachment_download_url(attachment)
    return nil unless attachment.attached?

    helpers = Rails.application.routes.url_helpers
    opts = public_url_options

    if opts[:host].present?
      helpers.rails_storage_proxy_url(attachment, disposition: "attachment", **opts)
    else
      helpers.rails_storage_proxy_path(attachment, disposition: "attachment")
    end
  end

  def public_url_options
    app_cfg = CPF_CONFIG["app_options"] || {}
    host = app_cfg["public_url_host"].presence || ENV["APP_PUBLIC_HOST"].presence || Rails.application.routes.default_url_options[:host]
    protocol = app_cfg["public_url_protocol"].presence || ENV["APP_PUBLIC_PROTOCOL"].presence || Rails.application.routes.default_url_options[:protocol]

    { host: host, protocol: protocol }.compact
  end
end
require "csv"
require "stringio"
require "sidekiq/api"

class GeocoderMasterJob < MasterJob
  VALID_OUTPUT_FILE_FORMATS = %w[csv tsv].freeze

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
      options: api_options,
      output_file_format: normalized_output_file_format
    }
  end

  def enqueue_sidekiq_job
    return if jid.present?

    run_at = 5.seconds.from_now
    enqueued_jid = GeocoderMasterSkJob.perform_at(run_at, id)
    update_columns(jid: enqueued_jid, scheduled_at: run_at)
  end

  def reenqueue_sidekiq_job
    # this method reset sidekiq data for this job so it can be re-enqueued
    # it also increase the attempt_count for retry limit tracking
    # for a master job, we want to delete all associated worker jobs and recreate them 
    # to ensure a clean retry with all new sidekiq jobs created for worker jobs;
    Sidekiq::RetrySet.new.find_job(self.jid)&.delete
    Sidekiq::ScheduledSet.new.find_job(self.jid)&.delete
    Sidekiq::Queue.new("geocoder_master_sk_job").find_job(self.jid)&.delete

    worker_jobs.each do |worker_job|
      worker_job.delete_sidekiq_job
      worker_job.destroy
    end

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

    # for master jobs only
    self.total_jobs = nil
    self.completed_jobs = nil

    self.attempt_count = (self.attempt_count || 0) + 1
    save!
    self.enqueue_sidekiq_job
  end

  # method is used to check if all worker jobs are completed, and if so,
  # generate the final output file for the master job; 
  # this is called by the worker jobs after they are requeued or re-run because
  # in that case we do not know if the worker job has increased completed_jobs count or not 
  def check_worker_jobs_completion
    return if self.success === false # if master job already marked as failed, skip result generation
    return unless total_jobs.present? && total_jobs != 0

    completed_count = worker_jobs.where.not(completed_at: nil).count
    update_columns(completed_jobs: completed_count)

    if completed_count == total_jobs
      generate_result_file 
    elsif completed_count < total_jobs && result_created_at.present? && output_file.attached?
      # this means some worker jobs were requeued or re-run after the master job has generated the result file,
      # we should remove the result file and reset the result_created_at timestamp to ensure data consistency; 
      output_file.purge
      update_columns(result_created_at: nil)
    end
  end

  # generate the final output file if all worker jobs are completed, and update the master job's output_file attachment and completed_at timestamp
  def generate_result_file
    return if self.success === false
    return if result_created_at.present? && output_file.attached?
    return unless total_jobs.present? && total_jobs != 0 && total_jobs == completed_jobs

    endpoint = API_PROVIDERS[0]["endpoints"].find { |e| e["name"] == "Geocode" }
    output_headers = endpoint["output_headers"] || []
    raise "output_headers not configured for Geocode endpoint" if output_headers.empty?

    file_format = normalized_output_file_format
    col_sep = file_format == "tsv" ? "\t" : ","
    content_type = file_format == "tsv" ? "text/tsv" : "text/csv"

    combined_output = generate_tabular_with_quoted_headers(headers: output_headers, col_sep: col_sep) do |csv|
      worker_jobs.order(:id).each do |worker_job|
        next unless worker_job.output_file.attached?

        worker_job.output_file.open do |file|
          parse_tabular_rows(file.read).each do |row|
            next if failed_output_row?(row)

            csv << output_headers.map { |header| row[header] }
          end
        end
      end
    end

    output_file.attach(
      io: StringIO.new(combined_output),
      filename: "job_#{id}_output.#{file_format}",
      content_type: content_type
    )

    error_headers = ["sequenceNumber", "yourId", "addressString", "errorMessage"]
    error_file_format = normalized_output_file_format
    error_col_sep = error_file_format == "tsv" ? "\t" : ","
    error_content_type = error_file_format == "tsv" ? "text/tsv" : "text/csv"

    failed_rows = 0
    combined_error_data = generate_tabular_with_quoted_headers(headers: error_headers, col_sep: error_col_sep) do |csv|
      worker_jobs.order(:id).each do |worker_job|
        next unless worker_job.error_file.attached?

        worker_job.error_file.open do |file|
          parse_tabular_rows(file.read).each do |row|
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
        io: StringIO.new(combined_error_data),
        filename: "job_#{id}_errors.#{error_file_format}",
        content_type: error_content_type
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

  def normalized_output_file_format
    format = output_file_format.to_s.downcase
    VALID_OUTPUT_FILE_FORMATS.include?(format) ? format : "csv"
  end

  def parse_tabular_rows(content)
    first_line = content.to_s.each_line.first.to_s
    detected_col_sep = first_line.include?("\t") ? "\t" : ","
    CSV.parse(content, headers: true, col_sep: detected_col_sep)
  end

  def failed_output_row?(row)
    result_number = row["resultNumber"].to_s.strip
    return true if result_number == "0"

    # defensive fallback for rows with no usable geocode result fields
    full_address = row["fullAddress"].to_s.strip
    score = row["score"].to_s.strip
    result_number.blank? && full_address.blank? && (score.blank? || score == "0")
  end

  def generate_tabular_with_quoted_headers(headers:, col_sep:)
    header_line = CSV.generate_line(headers, col_sep: col_sep, force_quotes: true)
    body = CSV.generate(col_sep: col_sep) do |csv|
      yield(csv) if block_given?
    end
    "#{header_line}#{body}"
  end
end
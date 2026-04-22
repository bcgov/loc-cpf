require "csv"
require "stringio"

class GeocoderMasterSkJob
  include Sidekiq::Job

  sidekiq_options retry: false, queue: :geocoder_master_sk_job, backtrace: false

  def perform(job_id)
    job = Job.find_by(id: job_id)

    ### identify the associated job
    # check if job exists and has the correct jid
    if job.nil?
      Rails.logger.info "Job not found: #{job_id}, Sidekiq JID: #{self.jid}"
      return
    end

    if job.jid.present? && job.jid != self.jid
      Rails.logger.info "JID mismatch for Job ID: #{job_id}, Sidekiq JID: #{self.jid}, Job JID: #{job.jid}"
      return
    end
    if job.jid.nil?
      job.update!(jid: self.jid)
    end

    ### perform the geocoding task
    begin
      if job.type != "GeocoderMasterJob"
        raise "Job ID: #{job_id} is not a GeocoderMasterJob, actual type: #{job.type}"
      end
      job.update!(started_at: Time.now)

      max_rows = WORKER_OPTIONS["max_worker_row_count"].to_i
      raise "Invalid max_worker_row_count: #{max_rows}" if max_rows <= 0

      delimiter = detect_delimiter(job.input_data_content_type)

      worker_job_count = 0
      total_row_count = 0
      part_index = 1
      headers = nil
      chunk_rows = []
      pending_worker_jobs = []

      ActiveRecord::Base.transaction do
        job.input_file.open do |file|
          CSV.foreach(file.path, headers: true, col_sep: delimiter) do |row|
            headers ||= row.headers
            next if row.fields.all?(&:blank?)

            total_row_count += 1
            chunk_rows << row

            if chunk_rows.size >= max_rows
              pending_worker_jobs << create_worker_job_from_rows(job, headers, chunk_rows, part_index, delimiter)
              worker_job_count += 1
              part_index += 1
              chunk_rows = []
            end
          end
        end

        if chunk_rows.any?
          pending_worker_jobs << create_worker_job_from_rows(job, headers, chunk_rows, part_index, delimiter)
          worker_job_count += 1
        end
      end

      job.update!(
        completed_at: Time.now,
        success: true,
        total_jobs: worker_job_count,
        total_rows: total_row_count,
        error_message: nil
      )

      # enqueue only after all worker jobs are created successfully
      pending_worker_jobs.each(&:enqueue_sidekiq_job)
    rescue => e
      job.update!(
        completed_at: Time.now,
        success: false,
        error_message: "master_failed: #{e.message}".truncate(255)
      )
      Rails.logger.error "Error processing Job ID: #{job_id}, error: #{e.message}"
    end
  end

  private

  def detect_delimiter(content_type)
    case content_type.to_s.downcase
    when "text/tab-separated-values", "text/tsv", /tsv/
      "\t"
    else
      ","
    end
  end

  def create_worker_job_from_rows(job, headers, rows, index, delimiter = ",")
    chunk_csv = CSV.generate(col_sep: delimiter) do |csv|
      csv << headers
      rows.each { |row| csv << headers.map { |h| row[h] } }
    end

    worker_job = GeocoderWorkerJob.create!(
      user: job.user,
      master_job_id: job.id,
      endpoint_name: job.endpoint_name,
      api_options: job.api_options.to_json,
      input_data_content_type: job.input_data_content_type,
      output_data_content_type: job.output_data_content_type || "text/csv",
      scheduled_at: Time.current
    )

    ext = delimiter == "\t" ? "tsv" : "csv"
    worker_job.input_file.attach(
      io: StringIO.new(chunk_csv),
      filename: "job_#{job.id}_worker_#{index}.#{ext}",
      content_type: job.input_data_content_type
    )
    worker_job
  end
end

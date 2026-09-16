require "csv"
require "tempfile"
require "net/http"
require "uri"

class GeocoderMergeSkJob
  include Sidekiq::Job

  sidekiq_options retry: false, queue: :geocoder_merge_sk_job, backtrace: false

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

    # fail fast if master job already failed
    if job.master_job_id.present?
      master_job = Job.find_by(id: job.master_job_id)
      if master_job&.success == false
        job.update!(
          started_at: Time.now,
          completed_at: Time.now,
          success: false,
          error_message: "merge_skipped: master job failed".truncate(255)
        )
        return
      end
    end

    ### perform merge task
    combined_output_file = nil
    combined_error_file = nil
    begin
      job.update!(started_at: Time.now)
      master_job = job.master_job

      if master_job.success === false
        job.update!(
          completed_at: Time.now,
          success: false,
          error_message: "Master job is already marked as failed.".truncate(255)
        )
        return
      elsif master_job.result_created_at.present? && master_job.output_file.attached?
        job.update!(
          completed_at: Time.now,
          success: true,
          error_message: "Results have already been created.".truncate(255)
        )
        return
      elsif master_job.total_jobs.blank? || master_job.total_jobs == 0 || master_job.total_jobs != master_job.completed_jobs
        job.update!(
          completed_at: Time.now,
          success: false,
          error_message: "Master job is empty or is not yet completed.".truncate(255)
        )
        return
      end

      endpoint = API_PROVIDERS[0]["endpoints"].find { |e| e["name"] == "Geocode" }
      output_headers = endpoint["output_headers"] || []
      raise "output_headers not configured for Geocode endpoint" if output_headers.empty?

      final_output_headers = output_headers.reject { |h| h == "sid" }

      file_format = master_job.normalized_output_file_format
      col_sep = file_format == "tsv" ? "\t" : ","
      content_type = file_format == "tsv" ? "text/tsv" : "text/csv"

      combined_output_file = build_tabular_tempfile(headers: final_output_headers, col_sep: col_sep) do |csv|
        master_job.worker_jobs.order(:id).each do |worker_job|
          next unless worker_job.output_file.attached?

          worker_job.output_file.open do |file|
            each_tabular_row(file) do |row|
              next if failed_output_row?(row)

              csv << final_output_headers.map { |header| row[header] }
            end
          end
        end
      end

      master_job.output_file.attach(
        io: combined_output_file,
        filename: "job_#{job.id}_output.#{file_format}",
        content_type: content_type
      )

      error_headers = ["sequenceNumber", "yourId", "addressString", "errorMessage"]
      error_file_format = master_job.normalized_output_file_format
      error_col_sep = error_file_format == "tsv" ? "\t" : ","
      error_content_type = error_file_format == "tsv" ? "text/tsv" : "text/csv"

      failed_rows = 0
      combined_error_file = build_tabular_tempfile(headers: error_headers, col_sep: error_col_sep) do |csv|
        master_job.worker_jobs.order(:id).each do |worker_job|
          next unless worker_job.error_file.attached?

          worker_job.error_file.open do |file|
            each_tabular_row(file) do |row|
              values = error_headers.map { |h| row[h] }
              next if values.all?(&:blank?)

              csv << values
              failed_rows += 1
            end
          end
        end
      end

      if failed_rows > 0
        master_job.error_file.attach(
          io: combined_error_file,
          filename: "job_#{job.id}_errors.#{error_file_format}",
          content_type: error_content_type
        )
        master_job.update_columns(result_created_at: Time.current, error_message: "Completed with #{failed_rows} failed rows")
      else
        master_job.error_file.purge if master_job.error_file.attached?
        master_job.update_columns(result_created_at: Time.current, error_message: nil)
      end

      master_job.update!(
        completed_at: Time.now,
        result_created_at: Time.now,
        success: true
      )
      job.update!(
        completed_at: Time.now,
        success: true
      )
      
    rescue => e
      master_job.update!(
        completed_at: Time.now,
        success: false,
        error_message: "Worker failed: #{e.message}".truncate(255)
      )
      job.update!(
        completed_at: Time.now,
        success: false,
        error_message: "Merge failed: #{e.message}".truncate(255)
      )
      Rails.logger.error "Error processing Job ID: #{job_id}, error: #{e.message}"
    ensure
      [combined_output_file, combined_error_file].each do |tempfile|
        next unless tempfile

        tempfile.close
        tempfile.unlink
      end
    end
  end

  private

  # streams rows from an open worker file without loading the whole file into memory
  def each_tabular_row(file)
    first_line = file.gets
    return if first_line.nil?

    detected_col_sep = first_line.include?("\t") ? "\t" : ","
    file.rewind
    CSV.new(file, headers: true, col_sep: detected_col_sep).each { |row| yield row }
  end

  # writes the combined header/rows to a tempfile incrementally instead of buffering an in-memory string
  def build_tabular_tempfile(headers:, col_sep:)
    tempfile = Tempfile.new("geocoder_merge")
    tempfile.binmode
    tempfile.write(CSV.generate_line(headers, col_sep: col_sep, force_quotes: true))

    csv = CSV.new(tempfile, col_sep: col_sep)
    yield csv

    tempfile.flush
    tempfile.rewind
    tempfile
  end

  def failed_output_row?(row)
    result_number = row["resultNumber"].to_s.strip
    return true if result_number == "0"

    # defensive fallback for rows with no usable geocode result fields
    full_address = row["fullAddress"].to_s.strip
    score = row["score"].to_s.strip
    result_number.blank? && full_address.blank? && (score.blank? || score == "0")
  end

end

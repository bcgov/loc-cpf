require "csv"
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
      input_file_url: input_file.attached? ? Rails.application.routes.url_helpers.rails_blob_url(input_file, disposition: "attachment", only_path: true) : nil,
      output_file_url: output_file.attached? ? Rails.application.routes.url_helpers.rails_blob_url(output_file, disposition: "attachment", only_path: true) : nil,
      options: self.api_options
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

    update_columns(result_created_at: Time.current)
  end
end
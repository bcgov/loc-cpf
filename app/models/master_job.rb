class MasterJob < Job
  has_many :worker_jobs, -> { where(type: ["WorkerJob", "GeocoderWorkerJob"]) }, class_name: "Job", foreign_key: :master_job_id, dependent: :destroy

  def get_status
    # note: master job is only considered completed when all worker jobs are completed
    # and if any worker job failed, the master job is considered failed. In addition,
    # master job should also check if the final result file is generated successfully
    if completed_at.present? # this means the master job has run to generate worker jobs
      if worker_jobs.any? { |job| job.get_status == "failed" }
        if success.nil?
          update_column(:success, false)
        end
        "failed"
      elsif output_file.attached?
        "completed"
      elsif total_jobs.present? && completed_jobs.present? && completed_jobs < total_jobs
        "in progress"
      elsif total_jobs.present? && completed_jobs.present? && completed_jobs == total_jobs
        "finalizing"
      else
        "queued"
      end
    elsif started_at.present?
      reach_max_attempts? ? "terminated" : "in_progress"
    elsif scheduled_at.present? && scheduled_at > Time.now
      "scheduled"
    else
      "submitted"
    end
  end
end
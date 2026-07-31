class MasterJob < Job
  has_many :worker_jobs, -> { where(type: ["WorkerJob", "GeocoderWorkerJob"]) }, class_name: "Job", foreign_key: :master_job_id, dependent: :destroy

  has_many :merge_jobs, -> { where(type: ["MergeJob", "GeocoderMergeJob"]) }, class_name: "Job", foreign_key: :master_job_id, dependent: :destroy


  def get_status
    if completed_at.present? # master job has finished splitting/creating worker jobs
      if worker_jobs.any? { |job| job.get_status == "failed" }
        update_column(:success, false) if success.nil?
        "failed"
      elsif success === false
        "failed"
      elsif result_created_at.present?
        "completed"
      elsif total_jobs.present? && completed_jobs.present? && completed_jobs < total_jobs
        "in_progress"
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
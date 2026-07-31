class MergeJob < Job
  belongs_to :master_job, class_name: "Job", foreign_key: :master_job_id
end
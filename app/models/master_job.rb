class MasterJob < Job
  has_many :worker_jobs, dependent: :destroy
end
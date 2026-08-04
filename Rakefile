# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

require_relative "config/application"

Rails.application.load_tasks

namespace :job_manager do
  desc "Run JobManager.check_jobs"
  task check_jobs: :environment do
    JobManager.check_jobs
  end

  desc "Run JobManager.cleanup_old_master_jobs"
  task cleanup_old_master_jobs: :environment do
    JobManager.cleanup_old_master_jobs
  end
end

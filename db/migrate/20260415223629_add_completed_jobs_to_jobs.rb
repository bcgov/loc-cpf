class AddCompletedJobsToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :completed_jobs, :integer
  end
end

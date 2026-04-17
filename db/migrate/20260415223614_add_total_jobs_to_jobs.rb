class AddTotalJobsToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :total_jobs, :integer
  end
end

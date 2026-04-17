class AddResultCreatedAtToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :result_created_at, :datetime
  end
end

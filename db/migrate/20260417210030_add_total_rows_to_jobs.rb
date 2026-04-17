class AddTotalRowsToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :total_rows, :integer
  end
end

class RemoveFilePathsFromJobs < ActiveRecord::Migration[8.0]
  def change
    remove_column :jobs, :input_file_path, :string
    remove_column :jobs, :output_file_path, :string
  end
end

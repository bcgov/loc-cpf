class AddOutputFileFormatToJobs < ActiveRecord::Migration[7.0]
  def change
    add_column :jobs, :output_file_format, :string, null: false, default: "csv"
  end
end

class AddInputDataContentTypeToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :input_data_content_type, :string
  end
end

class AddOutputDataContentTypeToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :output_data_content_type, :string
  end
end

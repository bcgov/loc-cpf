class AddApiOptionsToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :api_options, :text
  end
end

class AddErrorFieldsToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :error_message, :string
  end
end

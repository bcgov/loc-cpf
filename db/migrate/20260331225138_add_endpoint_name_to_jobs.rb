class AddEndpointNameToJobs < ActiveRecord::Migration[8.0]
  def change
    add_column :jobs, :endpoint_name, :string
  end
end

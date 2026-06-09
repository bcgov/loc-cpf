class CreateServerStatuses < ActiveRecord::Migration[7.0]
  def change
    create_table :server_statuses do |t|
      t.string :status, null: false, default: "running"
      t.timestamps
    end
  end
end

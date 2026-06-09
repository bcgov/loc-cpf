class AddJidHistoryToJobs < ActiveRecord::Migration[7.0]
  def change
    add_column :jobs, :jid_history, :text
  end
end

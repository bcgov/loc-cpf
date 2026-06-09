class RemoveRescheduedJidFromJobs < ActiveRecord::Migration[7.0]
  def change
    remove_column :jobs, :reschedued_jid, :string, if_exists: true
  end
end

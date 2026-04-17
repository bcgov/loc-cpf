class AddMasterJobFkToJobs < ActiveRecord::Migration[8.0]
  def up
    unless column_exists?(:jobs, :master_job_id)
      add_reference :jobs, :master_job, foreign_key: { to_table: :jobs }, index: true
      return
    end

    add_index :jobs, :master_job_id unless index_exists?(:jobs, :master_job_id)
  end

  def down
    remove_index :jobs, :master_job_id if index_exists?(:jobs, :master_job_id)
    # keep column for backward compatibility
  end
end

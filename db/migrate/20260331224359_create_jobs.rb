class CreateJobs < ActiveRecord::Migration[8.0]
  def change
    create_table :jobs do |t|
      t.string :type
      t.string :jid
      t.boolean :success
      t.datetime :started_at
      t.datetime :completed_at
      t.datetime :scheduled_at
      t.string :reschedued_jid
      t.integer :attempt_count
      t.integer :master_job_id
      t.string :input_file_path
      t.string :output_file_path
      t.integer :user_id
      t.string :notification_email

      t.timestamps
    end
  end
end

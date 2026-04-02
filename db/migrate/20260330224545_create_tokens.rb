class CreateTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :tokens do |t|
      t.integer :user_id
      t.string :value
      t.timestamp :expired_at

      t.timestamps
    end
  end
end

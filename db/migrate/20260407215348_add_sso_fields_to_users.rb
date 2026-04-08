class AddSsoFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :display_name, :string
    add_column :users, :idir_username, :string
    add_column :users, :admin, :boolean
    add_column :users, :client_id, :string
  end
end

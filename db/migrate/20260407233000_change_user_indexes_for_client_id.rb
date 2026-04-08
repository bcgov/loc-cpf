class ChangeUserIndexesForClientId < ActiveRecord::Migration[8.0]
  def up
    if index_exists?(:users, :email, name: "index_users_on_email", unique: true)
      remove_index :users, name: "index_users_on_email"
    end

    unless index_exists?(:users, :email, name: "index_users_on_email")
      add_index :users, :email, name: "index_users_on_email"
    end

    unless index_exists?(:users, :client_id, name: "index_users_on_client_id", unique: true)
      add_index :users, :client_id, unique: true, name: "index_users_on_client_id"
    end
  end

  def down
    if index_exists?(:users, :client_id, name: "index_users_on_client_id")
      remove_index :users, name: "index_users_on_client_id"
    end

    if index_exists?(:users, :email, name: "index_users_on_email")
      remove_index :users, name: "index_users_on_email"
    end

    unless index_exists?(:users, :email, name: "index_users_on_email", unique: true)
      add_index :users, :email, unique: true, name: "index_users_on_email"
    end
  end
end

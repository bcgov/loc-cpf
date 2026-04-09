class AddIndexToTokensValue < ActiveRecord::Migration[8.0]
  def change
    add_index :tokens, :value, name: "index_tokens_on_value" unless index_exists?(:tokens, :value, name: "index_tokens_on_value")
  end
end

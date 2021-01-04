Sequel.migration do
  up do
    alter_table :contents do
      add_column :media_url, String
    end
  end
end

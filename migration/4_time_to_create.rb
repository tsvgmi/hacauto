Sequel.migration do
  up do
    alter_table :performances do
      set_column_type :created, :DateTime
      set_column_type :updated_at, :DateTime
    end
  end
end

# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table :performances do
      add_column :latlong,   String
      add_column :latlong_2, String
    end
  end
end

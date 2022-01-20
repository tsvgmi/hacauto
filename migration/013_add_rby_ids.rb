# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table :performances do
      add_column :record_by_ids, String
    end
  end
end

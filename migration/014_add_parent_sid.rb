# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table :performances do
      add_column :parent_sid, String
    end
  end
end

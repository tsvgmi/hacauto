# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table :performances do
      add_column :expire_at, DateTime
    end
  end
end

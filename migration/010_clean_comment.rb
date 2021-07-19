# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table :comments do
      drop_column  :stitle
      drop_column  :record_by
    end
  end
end

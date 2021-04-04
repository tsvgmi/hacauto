# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table :performances do
      drop_column :sfile
      drop_column :ofile
      drop_column :is_ensemble
      drop_column :parent
    end
  end
end

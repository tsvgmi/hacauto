# frozen_string_literal: true

Sequel.migration do
  up do
    create_table :tags do
      primary_key :id
      String  :sname, unique: true
      String  :lname, unique: true
      String  :description
    end
  end
end

Sequel.migration do
  up do
    create_table :comments do
      primary_key :id
      String  :sid, unique: true, null: false
      String  :stitle
      String  :record_by
      String  :comments, size:1024
      Date    :updated_at
    end
  end
end

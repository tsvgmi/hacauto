Sequel.migration do
  up do
    create_table :loves do
      String  :sid
      String  :user
      Date    :updated_at
      primary_key [:sid, :user], name: :love
    end
  end
end

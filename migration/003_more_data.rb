# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table :performances do
      drop_column :collab_url
      drop_column :play_path
      drop_column :since
      drop_column :sincev
      drop_column :media_url

      add_column :song_info_url, String
      add_column :other_city, String
    end
  end
end

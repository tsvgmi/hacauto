# frozen_string_literal: true

Sequel.migration do
  up do
    create_table :singers do
      primary_key :id
      Integer :account_id, unique: true
      String  :name, null: false
      String  :avatar
      String  :following
      String  :follower
      String  :alias
      Date    :updated_at
    end

    create_table :songtags do
      primary_key :id
      String :name, unique: true, null: false
      String :tags
      Date   :updated_at
    end

    create_table :favorites do
      String  :sid,    unique: true, null: false
      String  :singer, unique: true, null: false
      Date    :updated_at
    end

    create_table :contents do
      primary_key :id
      String  :sid, unique: true, null: false
      String  :title
      String  :stitle
      String  :avatar
      String  :href
      String  :record_by
      Boolen  :is_ensemble
      Boolen  :isfav
      Boolen  :oldfav
      String  :collab_url
      String  :play_path
      String  :parent
      String  :orig_city
      Integer :listens
      Integer :loves
      Integer :gifts
      Integer :psecs
      Integer :stars
      String  :ofile
      String  :sfile
      String  :since
      Float   :sincev
      Date    :created
      Date    :updated_at
    end
  end
end

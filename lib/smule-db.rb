#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hacauto.rb
#---------------------------------------------------------------------------
#++
require_relative "../etc/toolenv"
require 'yaml'
require 'thor'
require 'sequel'
require 'tty-progressbar'
require 'core'

require 'sequel/adapters/sqlite'
class Sequel::SQLite::Dataset
  def size
    self.count
  end
end

module SmuleAuto
  class HashableSet
    def initialize(dataset, key, vcol=nil)
      @dataset = dataset
      @key     = key
      @vcol    = vcol
    end
    
    def [](kval)
      unless rec = @dataset.where(@key => kval).first
        @dataset.insert_conflict(:replace).insert(@key => kval)
      end
      rec ||= @dataset.where(@key => kval).first
      @vcol ? rec[@vcol] : rec
    end
  end

  class SmuleDB
    DBNAME = "smule.db"

    attr_reader :content

    def self.instance(user, cdir='.')
      @_db ||= SmuleDB.new(user, cdir)
    end

    def initialize(user, cdir = '.')
      create_db unless test(?f, DBNAME)
      @user     = user
      @DB       = Sequel.sqlite(DBNAME)
      YAML.load_file('etc/db_models.yml').each do |model, minfo|
        klass = Class.new(Sequel::Model)
        klass.dataset = @DB[minfo['table'].to_sym]
        Object.const_set model, klass
      end

      @content  = @DB[:performances]
      @singers  = @DB[:singers]
      @songtags = @DB[:song_tags]
    end

    def tags
      HashableSet.new(@songtags, :name, :tags)
    end

    def update_song(sinfo)
      begin
        sinfo.delete(:lyrics)
        @content.insert_conflict(:replace).insert(sinfo)
      rescue => errmsg
        Plog.error(errmsg)
      end
    end

    def delete_song(sinfo)
      sinfo[:deleted] = true
      @content.where(sid:sinfo[:sid]).delete
    end

    def select_set(ftype, value)
      if ftype == :recent
        if value =~ /,/
          sday, eday = value.split(',').map{|f| f.to_i}
        else
          sday, eday = value.to_i, -1
        end
        ldate  = Time.now - sday*24*3600
        edate  = Time.now - eday*24*3600
        if ldate > edate
          ldate, edate = edate, ldate
        end
      end
      case ftype
      when :url
        newset = @content.where(href:value)
      when :isfav
        newset = @content.where(isfav:true)
      when :favs
        newset = @content.where(isfav:true) + @content.where(oldfav:true)
        newset = @content.where{(isfav=true) or (oldfav=true)}
      when :record_by
        newset = @content.where(Sequel.like(:record_by, "%#{value}%"))
      when :title
        newset = @content.where(Sequel.like(:stitle, "%#{value}%"))
      when :recent
        newset = @content.where(created: ldate..edate)
      when :star
        newset = @content.where{stars >= value.to_i}
      else
        Plog.info("Unknown selection - #{ftype}")
        newset = @content
      end
      Plog.dump_info(msg:"Selecting #{newset.size} songs",
                     ftype:ftype, value:value)
      newset.all
    end

    def each(options={})
      recs = @content.where(Sequel.lit(options[:filter])).
        order(:record_by, :created)
      Plog.dump_info(options:options, rcount:recs.count)
      progress_set(recs) do |r, bar|
        yield r[:sid], r
        true
      end
    end

    def select_sids(sids)
      @content.where(sid:sids).all
    end

    def dump_db
      file  = "data/content-new.yml"
      Plog.info("Writing #{file} - #{@content.count}")
      mcontent = {}
      @content.all.each do |r|
        mcontent[r[:sid]] = r
      end
      File.open(file, "w") do |fod|
        fod.puts mcontent.to_yaml
      end

      file = "data/singers-new.yml"
      Plog.info("Writing #{file} - #{@singers.count}")
      File.open(file, 'w') do |fod|
        fod.puts @singers.all.to_yaml
      end

      file = "data/songtags-new.yml"
      Plog.info("Writing #{file} - #{@songtags.count}")
      File.open(file, 'w') do |fod|
        @songtags.all.each do |r|
          fod.puts [r[:name], r[:tags]].join(':::')
        end
      end
      true
    end

    def load_db
      content_file  = "data/content-#{@user}.yml"
      songtags_file = "data/songtags2.yml"
      ycontent      = YAML.load_file(content_file)
      bar           = TTY::ProgressBar.new("Content [:bar] :percent", total: ycontent.size)
      ycontent.each do |sid, sinfo|
        irec = sinfo.dup
        irec.delete(:m4tag)
        irec[:record_by] = irec[:record_by]
        begin
          @content.insert_conflict(:replace).insert(irec)
          bar.advance
        rescue => errmsg
          Plog.dump_error(errmsg:errmsg, irec:irec)
        end
      end

      ysingers = YAML.load_file("data/singers-#{@user}.yml")
      bar      = TTY::ProgressBar.new("Singers [:bar] :percent", total: ysingers.size)
      ysingers.each do |singer, sinfo|
        irec = sinfo.dup
        begin
          @singers.insert_conflict(:replace).insert(irec)
          bar.advance
        rescue => errmsg
          Plog.dump_info(errmsg:errmsg, singer:singer, sinfo:sinfo)
        end
      end

      ytags = File.read(songtags_file).split("\n")
      bar   = TTY::ProgressBar.new("Tags [:bar] :percent", total: ytags.size)
      ytags.each do |l|
        name, tags = l.split(':::')
        @songtags.insert_conflict(:replace).insert(name:name, tags:tags)
        bar.advance
      end
      @cur_user  = @user
      @load_time = Time.now
      Plog.info("Loading db complete")
    end

    def add_new_songs(block, isfav=false)
      require 'time'

      now = Time.now

      # Favlist must be reset if specified
      if isfav
        @content.update(isfav:nil)
      end

      block.each do |r|
        r[:updated_at] = now
        r[:isfav]      = isfav if isfav
        if c = @content.where(sid:r[:sid]).first
          updset = {
            listens:   r[:listens],
            loves:     r[:loves],
            record_by: r[:record_by],   # In case user change login
            isfav:     r[:isfav],
            orig_city: r[:orig_city],
            avatar:    r[:avatar],
            sfile:     r[:sfile] || c[:sfile],
            ofile:     r[:ofile] || c[:ofile],
          }
          updset[:oldfav] = true if updset[:isfav]
          @content.where(sid:r[:sid]).update(updset)
        else
          r.delete(:lyrics)
          @content.insert(r)
        end
      end
      self
    end

    def set_follows(followings, followers)
      @singers.update(following:nil, follower:nil)
      allset = {}
      followings.each do |e|
        k = e[:name]
        allset[k] = e
        allset[k][:following] = true
      end
      followers.each do |e|
        k = e[:name]
        allset[k] ||= e
        allset[k][:follower] = true
      end
      allset.each do |k, v|
        @singers.insert_conflict(:replace).insert(v)
      end
      self
    end

    def add_tag(song, tags)
      songs   = song.is_a?(Array) ? song : [song]
      stitles = songs.map{|r| r[:stitle]}
      wset    = SongTag.where(name:stitles)
      addset, delset = tags.split(',').partition{|r| r[0] != '-'}
      delset = delset.map{|r| r[1..-1]}
      SongTag.where(name:stitles).each do |r|
        new_val = ((r[:tags] || '').split(',') + addset).uniq
        new_val -= delset
        new_val = new_val.sort.uniq.join(',')
        Plog.dump_info(new_val:new_val, r:r)
        r.update(tags:new_val)
      end
      wset.count
    end
  end

  class Main < Thor
    include ThorAddition

    desc "load_db user", "load_db"
    def load_db_for_user(user, cdir='.')
      cli_wrap do
        SmuleDB.instance(user, cdir).load_db
      end
    end

    desc "dump_db", "dump_db"
    def dump_db(user, cdir='.')
      cli_wrap do
        SmuleDB.instance(user, cdir).dump_db
      end
    end
  end
end

if (__FILE__ == $0)
  SmuleAuto::Main.start(ARGV)
end

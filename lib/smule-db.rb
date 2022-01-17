#!/usr/bin/env ruby
# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        hacauto.rb
#---------------------------------------------------------------------------
#++
require_relative '../etc/toolenv'
require 'yaml'
require 'thor'
require 'sequel'
require 'tty-progressbar'
require 'core'

require 'sequel/adapters/sqlite'
module Sequel
  module SQLite
    # Docs for Dataset
    class Dataset
      def size
        count
      end
    end
  end
end

module SmuleAuto
  # Docs for HashableSet
  class HashableSet
    def initialize(dataset, key, vcol: nil)
      @dataset = dataset
      @key     = key
      @vcol    = vcol
    end

    def [](kval)
      if (rec = @dataset.where(@key => kval).first).nil?
        @dataset.insert_conflict(:replace).insert(@key => kval)
      end
      rec ||= @dataset.where(@key => kval).first
      @vcol ? rec[@vcol] : rec
    end
  end

  # Docs for SmuleDB
  class SmuleDB
    DBNAME = 'smule.db'

    attr_reader :content, :singers, :db

    def self.instance(user, cdir: '.')
      @instance ||= SmuleDB.new(user, cdir: cdir)
    end

    def initialize(user, cdir: '.')
      dbname = File.join(cdir, DBNAME)
      @user  = user
      @db    = Sequel.sqlite(database: dbname, timeout: 1_000_000)
      Sequel::Model.plugin :insert_conflict
      YAML.safe_load_file('etc/db_models.yml').each do |model, minfo|
        klass = Class.new(Sequel::Model)
        klass.dataset = @db[minfo['table'].to_sym]
        Object.const_set model, klass
      end

      @all_content = @db[:performances].where(deleted: nil).or(deleted: 0)
      @content     = @all_content.where(Sequel.lit('record_by like ?',
                                                   "%#{user}%"))
      @singers     = @db[:singers]
      @songtags    = @db[:song_tags]
    end

    def songtags
      HashableSet.new(@songtags, :name, vcol: :tags)
    end

    def update_song(sinfo)
      sinfo.delete(:lyrics)
      @content.insert_conflict(:replace).insert(sinfo)
    rescue StandardError => e
      Plog.error(e)
    end

    def delete_song(sinfo)
      sinfo[:deleted] = true
      # @content.where(sid: sinfo[:sid]).delete
      @content.where(sid: sinfo[:sid]).update(deleted: true)
    end

    def select_set(ftype, value)
      if ftype == :recent
        if value =~ /,/
          sday, eday = value.split(',').map(&:to_i)
        else
          sday = value.to_i
          eday = -1
        end
        ldate  = Time.now - sday * 24 * 3600
        edate  = Time.now - eday * 24 * 3600
        ldate, edate = edate, ldate if ldate > edate
      end
      case ftype
      when :query
        begin
          newset = @content.where(Sequel.lit(value))
        rescue StandardError => e
          Plog.dump_error(e: e, value: value, trace: e.backtrace)
          newset = []
        end
      when :url
        newset = @content.where(sid: File.basename(value))
      when :my_open
        newset = @content.where(record_by: @user)
        newset = newset.where(Sequel.lit('message is null or message not like "%#thvopen%"')) if value
      when :my_duets
        newset = @content.where(record_by: "#{@user},#{@user}")
        newset = newset.where(Sequel.lit('message is null or message not like "%#thvduets%"')) if value
      when :my_tags
        newset = @content.where(Sequel.lit(%(message like "%#{value}%")))
      when :isfav
        newset = @content.where(isfav: true)
        if value
          newset = newset.where(Sequel.lit('message is null or message not like "%#thvduets%"'))
                         .where(Sequel.ilike(:record_by, "#{@user}%"))
        end
      when :favs
        newset = @content.where(Sequel.lit('isfav=1 or oldfav=1'))
        if value
          newset = newset.where(Sequel.lit('message is null or message not like "%#thvduets%"'))
                         .where(Sequel.ilike(:record_by, "#{@user}%"))
        end
      when :record_by
        newset = @content.where(Sequel.ilike(:record_by, "%#{value}%"))
      when :title
        newset = @content.where(Sequel.ilike(:stitle, "%#{value}%"))
      when :recent
        newset = @content.where(created: ldate..edate)
      when :sid
        newset = @content.where(sid: value.split(/[, ]+/))
      when :star
        newset = @content.where { stars >= value.to_i }
      when :untagged
        newset = @content
                 .where(Sequel.lit('message is null or message not like "%#%"'))
                 .where(Sequel.ilike(:record_by, "#{@user}%"))
      else
        Plog.info("Unknown selection - #{ftype}")
        newset = @content
      end
      Plog.dump_info(msg: "Selecting #{newset.size} songs",
                     ftype: ftype, value: value)
      newset.all
    end

    def each(options={})
      filters = options[:filter].split('/').map { |r| "(#{r})" }.join(' OR ')
      recs = @content.order(:record_by, :created)
      recs = recs.where(Sequel.lit(filters)) unless filters.empty?
      Plog.dump(recs: recs, options: options, rcount: recs.count)
      progress_set(recs) do |r, _bar|
        yield r[:sid], r
        true
      end
    end

    def select_sids(sids)
      @content.where(sid: sids).all
    end

    def add_new_songs(block, isfav: false)
      require 'time'

      now = Time.now

      # Favlist must be reset if specified
      @content.update(isfav: nil) if isfav

      newcount = 0
      updcount = 0
      block.each do |r|
        r[:updated_at] = now
        r[:isfav]      = isfav if isfav
        if @all_content.where(sid: r[:sid]).first
          updset = {
            listens:   r[:listens],
            loves:     r[:loves],
            record_by: r[:record_by], # In case user change login
            isfav:     r[:isfav],
            orig_city: r[:orig_city],
            avatar:    r[:avatar],
            message:   r[:message],
          }
          updset[:oldfav]    = true if updset[:isfav]
          updset[:latlong]   = r[:latlong] if r[:latlong]
          updset[:latlong_2] = r[:latlong_2] if r[:latlong_2]
          @all_content.where(sid: r[:sid]).update(updset)
          updcount += 1
        else
          r.delete(:lyrics)
          @all_content.insert(r)
          newcount += 1
        end
      end
      [newcount, updcount]
    end

    def set_follows(followings, followers, others=nil)
      allset = @singers.as_hash(:account_id)
      now    = Time.now
      (others || []).each do |e|
        Plog.dump(name: e[:name])
        k = e[:account_id]
        allset[k] ||= e
        allset[k][:following]  = nil
        allset[k][:follower]   = nil
        allset[k][:updated_at] = now
        allset[k][:name]       = e[:name]
        allset[k][:avatar]     = e[:avatar]
      end
      followings.each do |e|
        Plog.dump(name: e[:name])
        k = e[:account_id]
        allset[k] ||= e
        allset[k][:following]  = true
        allset[k][:updated_at] = now
        allset[k][:name]       = e[:name]
        allset[k][:avatar]     = e[:avatar]
      end
      followers.each do |e|
        Plog.dump(name: e[:name])
        k = e[:account_id]
        allset[k] ||= e
        allset[k][:follower]   = true
        allset[k][:updated_at] = now
        allset[k][:name]       = e[:name]
        allset[k][:avatar]     = e[:avatar]
      end
      allset.each do |_k, v|
        @singers.insert_conflict(:replace).insert(v)
      end
      self
    end

    def add_tag(song, tags)
      songs   = song.is_a?(Array) ? song : [song]
      stitles = songs.map { |r| r[:stitle] }
      wset    = SongTag.where(name: stitles)
      addset, delset = tags.split(',').partition { |r| r[0] != '-' }
      delset = delset.map { |r| r[1..] }
      SongTag.where(name: stitles).each do |r|
        new_val = ((r[:tags] || '').split(',') + addset).uniq
        new_val -= delset
        new_val = new_val.sort.uniq.join(',')
        Plog.dump_info(new_val: new_val, r: r)
        r.update(tags: new_val)
      end
      wset.count
    end

    def top_partners(limit, options={})
      days  = options[:days] || 30
      odate = (Time.now - days * 24 * 3600).strftime('%Y-%m-%d')
      query = Performance.group_and_count(:record_by)
                         .select_append { sum(loves).as(loves) }
                         .select_append { sum(listens).as('listens') }
                         .select_append { sum(stars).as('stars') }
                         .select_append { sum(isfav).as(isfavs) }
                         .select_append { sum(oldfav).as(oldfavs) }
                         .order(:listens).reverse
                         .limit(limit * 4)
                         .where(Sequel.lit('record_by like ?', "%#{@user}%"))
                         .where(Sequel.lit('created > ?', odate))
      Plog.dump(sql: query.sql)
      rank = {}
      query.each do |r|
        key = r[:record_by].sub(/,?#{@user},?/, '')
        rank[key] ||= {count: 0, loves: 0, listens: 0, isfavs: 0, oldfavs: 0, stars: 0}
        rank[key][:count]   += r[:count]
        rank[key][:loves]   += r[:loves]
        rank[key][:listens] += r[:listens]
        rank[key][:stars]   += r[:stars].to_i
        rank[key][:isfavs]  += r[:isfavs].to_i
        rank[key][:oldfavs] += r[:oldfavs].to_i
      end
      rank.each do |_singer, sinfo|
        score = sinfo[:count] + sinfo[:isfavs] * 10 + sinfo[:oldfavs] * 5 +
                sinfo[:loves] * 0.2 +
                sinfo[:listens] / 20.0 + sinfo[:stars] * 0.1
        sinfo[:score] = score
      end
      rank.to_a.select { |k, _v| !k.empty? && k != @user }
          .sort_by { |_singer, sinfo| sinfo[:score] * -1 }[0..limit - 1]
    end
  end

  # Docs for Main
  class Main < Thor
    include ThorAddition

    no_commands do
      def _edit_file(records, format: 'json')
        require 'tempfile'

        newfile = Tempfile.new('new')
        bakfile = Tempfile.new('bak')

        bakfile.puts(records.map(&:to_json).join("\n"))
        bakfile.close

        case format
        when /^y/i
          newfile.puts(records.to_yaml)
          newfile.close
          system("vim #{newfile.path}")
          newrecs = YAML.safe_load_file(newfile.path)
          editout = Tempfile.new('edit')
          editout.puts(newrecs.map(&:to_json).join("\n"))
          editout.close
        else
          newfile.puts(records.map(&:to_json).join("\n"))
          system("vim #{newfile.path}")
          editout = newfile
        end

        diff   = `set -x; diff #{bakfile.path} #{editout.path} | tee /dev/tty`
        delset = []
        addset = []
        diff.split("\n").each do |l|
          next unless l =~ /{/

          case l
          when />/
            data = JSON.parse(l[2..], symbolize_names: true)
            addset << data
          when /</
            data = JSON.parse(l[2..], symbolize_names: true)
            delset << data
          end
        rescue StandardError => e
          Plog.error(e: e, l: l)
        end
        [addset, delset]
      end
    end

    desc 'rank_singer(user)', 'rank_singer'
    option :days, type: :numeric, default: 180, alias: '-d',
      desc: 'Look back the specified number of days only'
    def rank_singer(user)
      cli_wrap do
        tdir    = _tdir_check
        content = SmuleDB.instance(user, cdir: tdir)
        days    = options[:days]
        limit   = options[:limit] || 100
        rank    = content.top_partners(limit, options)
        puts "Ranking in last #{days} days"
        line = 0
        output = []
        output << %w[No. Singer Count Loves Listens Favs Stars Score]
        output << %w[=== ====== ===== ===== ======= ==== ===== =====]
        rank.each do |singer, sinfo|
          line += 1
          output << [line, singer, sinfo[:count], sinfo[:loves],
                     sinfo[:listens], sinfo[:isfavs] + sinfo[:oldfavs],
                     sinfo[:stars], sinfo[:score].to_i]
        end
        print_table(output)
        true
      end
    end
  end
end

SmuleAuto::Main.start(ARGV) if __FILE__ == $PROGRAM_NAME

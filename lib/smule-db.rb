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
    count
  end
end

module SmuleAuto
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

  class SmuleDB
    DBNAME = "smule.db".freeze

    attr_reader :content, :singers

    def self.instance(user, cdir: '.')
      @instance ||= SmuleDB.new(user, cdir: cdir)
    end

    def initialize(user, cdir: '.')
      dbname = File.join(cdir, DBNAME)
      @user  = user
      @DB    = Sequel.sqlite(dbname)
      Sequel::Model.plugin :insert_conflict
      YAML.safe_load_file('etc/db_models.yml').each do |model, minfo|
        klass = Class.new(Sequel::Model)
        klass.dataset = @DB[minfo['table'].to_sym]
        Object.const_set model, klass
      end

      @all_content = @DB[:performances]
      @content     = @all_content.where(Sequel.lit('record_by like ?',
                                                   "%#{user}%"))
      @singers     = @DB[:singers]
      @songtags    = @DB[:song_tags]
    end

    def tags
      HashableSet.new(@songtags, :name, :tags)
    end

    def update_song(sinfo)
      sinfo.delete(:lyrics)
      @content.insert_conflict(:replace).insert(sinfo)
    rescue => e
      Plog.error(e)
    end

    def delete_song(sinfo)
      sinfo[:deleted] = true
      @content.where(sid:sinfo[:sid]).delete
    end

    def select_set(ftype, value)
      if ftype == :recent
        if value =~ /,/
          sday, eday = value.split(',').map { |f| f.to_i }
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
      when :query
        begin
          newset = @content.where(Sequel.lit(value))
        rescue => e
          Plog.dump_error(e:e, value:value, trace:e.backtrace)
          newset = []
        end
      when :url
        newset = @content.where(sid:File.basename(value))
      when :isfav
        newset = @content.where(isfav:true)
      when :favs
        newset = @content.where(Sequel.lit('isfav=1 or oldfav=1'))
      when :record_by
        newset = @content.where(Sequel.ilike(:record_by, "%#{value}%"))
      when :title
        newset = @content.where(Sequel.ilike(:stitle, "%#{value}%"))
      when :recent
        newset = @content.where(created: ldate..edate)
      when :sid
        newset = @content.where(sid:value.split(/[, ]+/))
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
      filters = options[:filter].split('/').map { |r| "(#{r})" }.join(' OR ')
      recs = @content.order(:record_by, :created)
      unless filters.empty?
        recs = recs.where(Sequel.lit(filters))
      end
      Plog.dump_info(recs:recs, options:options, rcount:recs.count)
      progress_set(recs) do |r, _bar|
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
      ycontent      = YAML.safe_load_file(content_file)
      bar           = TTY::ProgressBar.new("Content [:bar] :percent", total: ycontent.size)
      ycontent.each do |_sid, sinfo|
        irec = sinfo.dup
        irec.delete(:m4tag)
        irec[:record_by] = irec[:record_by]
        begin
          @content.insert_conflict(:replace).insert(irec)
          bar.advance
        rescue => e
          Plog.dump_error(e:e, irec:irec)
        end
      end

      ysingers = YAML.safe_load_file("data/singers-#{@user}.yml")
      bar      = TTY::ProgressBar.new("Singers [:bar] :percent", total: ysingers.size)
      ysingers.each do |singer, sinfo|
        irec = sinfo.dup
        begin
          @singers.insert_conflict(:replace).insert(irec)
          bar.advance
        rescue => e
          Plog.dump_info(e:e, singer:singer, sinfo:sinfo)
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

    def add_new_songs(block, isfav: false)
      require 'time'

      now = Time.now

      # Favlist must be reset if specified
      if isfav
        @content.update(isfav:nil)
      end

      newcount = 0
      block.each do |r|
        r[:updated_at] = now
        r[:isfav]      = isfav if isfav
        if @all_content.where(sid:r[:sid]).first
          updset = {
            listens:   r[:listens],
            loves:     r[:loves],
            record_by: r[:record_by],   # In case user change login
            isfav:     r[:isfav],
            orig_city: r[:orig_city],
            avatar:    r[:avatar],
          }
          updset[:oldfav] = true if updset[:isfav]
          @all_content.where(sid:r[:sid]).update(updset)
        else
          r.delete(:lyrics)
          @all_content.insert(r)
          newcount += 1
        end
      end
      newcount
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
      allset.each do |_k, v|
        @singers.insert_conflict(:replace).insert(v)
      end
      self
    end

    def add_tag(song, tags)
      songs   = song.is_a?(Array) ? song : [song]
      stitles = songs.map { |r| r[:stitle] }
      wset    = SongTag.where(name:stitles)
      addset, delset = tags.split(',').partition{ |r| r[0] != '-'}
      delset = delset.map { |r| r[1..-1] }
      SongTag.where(name:stitles).each do |r|
        new_val = ((r[:tags] || '').split(',') + addset).uniq
        new_val -= delset
        new_val = new_val.sort.uniq.join(',')
        Plog.dump_info(new_val:new_val, r:r)
        r.update(tags:new_val)
      end
      wset.count
    end

    def top_partners(limit, options={})
      days  = options[:days] || 30
      odate = (Time.now - days*24*3600).strftime("%Y-%m-%d")
      query = Performance.group_and_count(:record_by).
        select_append{sum(loves).as(loves)}.
        select_append{sum(listens).as('listens')}.
        select_append{sum(stars).as('stars')}.
        select_append{sum(isfav).as(isfavs)}.
        select_append{sum(oldfav).as(oldfavs)}.
        order(:listens).reverse.
        limit(limit*4).
        where(Sequel.lit 'record_by like ?', "%#{@user}%").
        where(Sequel.lit 'created > ?', odate)
      Plog.dump(sql:query.sql)
      rank = {}
      query.each do |r|
        key = r[:record_by].sub(/,?#{@user},?/, '')
        rank[key] ||= {count: 0, loves:0, listens:0, isfavs:0, oldfavs:0, stars:0}
        rank[key][:count]   += r[:count]
        rank[key][:loves]   += r[:loves]
        rank[key][:listens] += r[:listens]
        rank[key][:stars]   += r[:stars].to_i
        rank[key][:isfavs]  += r[:isfavs].to_i
        rank[key][:oldfavs] += r[:oldfavs].to_i
      end
      rank.each do |_singer, sinfo|
        score = sinfo[:count] + sinfo[:isfavs]*10 + sinfo[:oldfavs]*5 +
          sinfo[:loves]*0.2 +
          sinfo[:listens]/20.0 + sinfo[:stars]*0.1
        sinfo[:score] = score
      end
      rank.to_a.select { |k, _v| !k.empty? && k != @user }.
        sort_by { |_singer, sinfo| sinfo[:score] * -1}[0..limit-1]
    end
  end

  class Main < Thor
    include ThorAddition

    no_commands do
      def _edit_file(records, format: 'json')
        require 'tempfile'

        newfile = Tempfile.new('new')
        bakfile = Tempfile.new('bak')

        bakfile.puts(records.map { |r| r.to_json }.join("\n"))

        case format
        when /^y/i
          newfile.puts(records.to_yaml)
          system("vim #{newfile.path}")
          newrecs = YAML.safe_load_file(newfile.path)
          editout = Tempfile.new('edit')
          editout.puts(newrecs.map { |r| r.to_json }.join("\n"))
        else
          newfile.puts(records.map { |r| r.to_json }.join("\n"))
          system("vim #{newfile.path}")
          editout = newfile
        end

        diff = `set -x; diff #{bakfile.path} #{editout.path}`
        puts diff
        delset, addset = [], []
        diff.split("\n").each do |l|
          begin
            if l =~ />/
              data = JSON.parse(l[2..-1], symbolize_names:true)
              addset << data
            elsif l =~ /</
              data = JSON.parse(l[2..-1], symbolize_names:true)
              delset << data
            end
          rescue => e
            Plog.error(e:e, l:l)
          end
        end
        [addset, delset]
      end
    end

    desc "load_db user", "load_db"
    def load_db_for_user(user, cdir: '.')
      cli_wrap do
        SmuleDB.instance(user, cdir).load_db
      end
    end

    desc "dump_db user [dir]", "dump_db"
    long_desc <<~LONGDESC
Dump the database into yaml file (for backup)
    LONGDESC
    def dump_db(user, cdir: '.')
      cli_wrap do
        SmuleDB.instance(user, cdir).dump_db
      end
    end

    desc "edit_tag", "Edit tag of existing song"
    long_desc <<~LONGDESC
Dump the tag data into a text file.  Allow user to edit and update with any
changes back into the database
    LONGDESC
    option :format, type: :string, default:'json'
    def edit_tag(user)
      cli_wrap do
        tdir           = _tdir_check(options[:data_dir])
        # Must call once to init db connection/model
        SmuleDB.instance(user, tdir)
        records        = SongTag.all.
          sort_by { |r| r[:name] }.
          map     { |r| r.values }
        insset, delset = _edit_file(records, options[:format])
        if delset.size > 0
          SongTag.where(id:delset.map { |r| r[:id] }).destroy
        end
        insset.each do |r|
          r.delete(:id)
          SongTag.new(r).save
        end
        true
      end
    end

    desc "edit_singer", "edit_singer"
    option :format, type: :string, default:'json'
    def edit_singer(user)
      cli_wrap do
        tdir    = _tdir_check(options[:data_dir])
        # Must call once to init db connection/model
        SmuleDB.instance(user, tdir)
        records = Singer.all.sort_by { |r| r[:name]}.map{|r| r.values }
        insset, delset = _edit_file(records, options[:format])
        if delset.size > 0
          Singer.where(id:delset.map { |r| r[:id] }).destroy
        end
        insset.each do |r|
          r.delete(:id)
          Singer.new(r).save
        end
        true
      end
    end

    desc "rank_singer(user)", "rank_singer"
    option :days,  type: :numeric, default:180, alias:'-d',
      desc:'Look back the specified number of days only'
    def rank_singer(user)
      cli_wrap do
        tdir    = _tdir_check
        content = SmuleDB.instance(user, tdir)
        days    = options[:days]
        limit   = options[:limit] || 100
        rank    = content.top_partners(limit, options)
        puts "Ranking in last #{days} days"
        line = 0
        output = []
        output << %w(No. Singer Count Loves Listens Favs Stars Score)
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

if (__FILE__ == $0)
  SmuleAuto::Main.start(ARGV)
end

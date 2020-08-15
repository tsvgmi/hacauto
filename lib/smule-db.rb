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

module SmuleAuto
  class SmuleDB
    DBNAME = "smule.db"

    def initialize(user, cdir = '.')
      create_db unless test(?f, DBNAME)
      @user     = user
      @DB       = Sequel.sqlite(DBNAME)
      @content = @DB[:contents]
      @singers  = @DB[:singers]
      @songtags = @DB[:songtags]
    end

    def each(options={})
      Plog.dump_info(options:options)
      @content.where(Sequel.lit(options[:filter])).each do |r|
        yield r[:sid], r
      end
    end

    def writeback
      Plog.info("Skip write back")
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
        irec.delete(:media_url)
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
        # Keep the 1st created, b/c it is more accurate
        sid = r[:sid]

        r.delete(:since)
        r.delete(:sincev)
        if c = @content.where(sid:sid).first
          c.update(
            listens:   r[:listens],
            loves:     r[:loves],
            since:     r[:since],
            record_by: r[:record_by],   # In case user change login
            isfav:     r[:isfav],
            orig_city: r[:orig_city],
            media_url: r[:media_url],
            sfile:     r[:sfile] || c[:sfile],
            ofile:     r[:ofile] || c[:ofile],
          )
          if c[:isfav]
            c[:oldfav] = true
          end
        else
          @content.insert(r)
        end
      end
      self
    end

  end

  class Main < Thor
    include ThorAddition

    desc "load_db user", "load_db"
    def load_db_for_user(user, cdir='.')
      cli_wrap do
        SmuleDB.new(user, cdir).load_db
      end
    end

    desc "dump_db", "dump_db"
    def dump_db(user, cdir='.')
      cli_wrap do
        SmuleDB.new(user, cdir).dump_db
      end
    end
  end
end

if (__FILE__ == $0)
  SmuleAuto::Main.start(ARGV)
end

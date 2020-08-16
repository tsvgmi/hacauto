#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        smule-content.rb
# Date:        2020-07-07 14:49:11 -0700
# Copyright:   E*Trade, 2020
# $Id$
#---------------------------------------------------------------------------
#++
require 'tty-progressbar'

module SmuleAuto
  class Content
    attr_reader :content, :singers, :tags

    def initialize(user, cdir='.')
      @user     = user
      @cdir     = cdir
      @cfile    = "#{cdir}/content-#{user}.yml"
      @sfile    = "#{cdir}/singers-#{user}.yml"
      @tagfile = "#{cdir}/songtags2.yml"
      @loaded   = Time.at(0)
      refresh
    end

    def update_song(sinfo)
      Plog.info("No update for text data")
    end

    def delete_song(sinfo)
      sinfo[:deleted] = true
    end

    def select_sids(sids)
      @content.select{|k, v| sids.include?(k)}.values
    end

    def select_set(ftype, value)
      newset = []

      if ftype == :recent
        if value =~ /,/
          sday, eday = value.split(',').map{|f| f.to_i}
        else
          sday, eday = value.to_i, 0
        end
        ldate  = Time.now - sday*24*3600
        edate  = Time.now - eday*24*3600
        if ldate > edate
          ldate, edate = edate, ldate
        end
      end
      Plog.dump_info(ftype:ftype, value:value)
      if ftype == :url
        if result = @content.find{|k, v| v[:href] == value}
          newset = [result[1]]
        end
      else
        @content.each do |k, v|
          case ftype
          when :isfav
            newset << v if v[:isfav]
          when :favs
            newset << v if (v[:isfav] || v[:oldfav])
          when :record_by
            newset << v if v[:record_by].downcase.include?(value.downcase)
          when :title
            newset << v if v[:stitle].include?(value.downcase)
          when :recent
            newset << v if (created_value(v[:created]) >= ldate &&
              created_value(v[:created]) <= edate)
          when :star
            newset << v if v[:stars].to_i >= value.to_i
          end
        end
      end
      Plog.info("Selecting #{newset.size} songs")
      newset
    end

    def refresh
      if File.mtime(@cfile) <= @loaded
        Plog.info("File #{@cfile} was not changed. Skip")
        return
      end
      if test(?s, @cfile)
        Plog.info("Loading #{@cfile}")
        @content = YAML.load_file(@cfile)
      else
        Plog.warn("#{@cfile} does not exist or empty")
        @content = {}
      end
      @content.each do |k, r|
        r[:sincev] = time_since(r[:since]) / 3600.0
      end
      Plog.info("Loading #{@sfile}")
      @singers = test(?f, @sfile) ? YAML.load_file(@sfile) : {}
      @tags    = {}
      if test(?f, @tagfile)
        Plog.info("Loading #{@tagfile}")
        File.open(@tagfile) do |fid|
          while l = fid.gets
            begin
              k, v = l.chomp.split(':::')
              if v && !v.empty?
                @tags[k] = v.split(',')
              end
            rescue => errmsg
              Plog.dump_error(errmsg:errmsg.to_s, l:l)
            end
          end
        end
      end
      @loaded = Time.now
    end

    def following
      @singers.select{|k, v| v[:following]}
    end

    def follower
      @singers.select{|k, v| v[:follower]}
    end

    def _write_with_backup(mfile, content, options={})
      wset = [mfile]
      if options[:backup]
        wset << File.join('/Volumes/Voice/SMULE', File.basename(mfile))
      end
      wset.uniq.each do |afile|
        b2file = afile + ".bak"
        if test(?f, afile)
          FileUtils.move(afile, b2file, verbose:true)
        end
        begin
          File.open(afile, 'w') do |fod|
            Plog.info("Writing #{content.size} entries to #{afile}")
            case options[:format]
            when :text
              fod.puts content
            else
              fod.puts content.to_yaml
            end
          end
        rescue Errno::ENOENT => errmsg
          Plog.dump_error(file:afile, errmsg:errmsg)
        end
      end
    end

    def writeback(backup=true)
      if File.mtime(@cfile) > @loaded
        Plog.error("File #{@cfile} was updated after load - #{@loaded}")
      end

      @content = @content.select do |sid, asong|
        !asong[:deleted]
      end
      @content.each do |sid, asong|
        stitle = to_search_str(asong[:title])
        asong[:stitle] ||= stitle
      end
      woption = {format: :yaml, backup: backup}
      _write_with_backup(@cfile, @content, woption)
      _write_with_backup(@sfile, @singers, woption) if @schanged
      @loaded   = Time.now

      newsong = false
      @content.each do |sid, asong|
        title = asong[:title]
        stitle = to_search_str(title)
        if stitle && !stitle.empty?
          unless @tags[stitle]
            @tags[stitle] = []
            newsong = true
          end
        end
      end

      if newsong || @newtag
        wtag = @tags.to_a.sort.
          map {|k2, v| "#{k2}:::#{v.join(',')}"}
        woption = {format: :text, backup: backup}
        _write_with_backup(@tagfile, wtag, woption)
        @newtag = false
      end
      self
    end

    def add_tag(song, tag)
      key = song[:stitle]
      @tags[key] = ((@tags[key] || []) + [tag]).uniq
      @newtag    = true
    end

    def set_follows(followings, followers)
      # Clear the list first
      @singers.each do |singer, sinfo|
        @singers[singer].delete(:following)
        @singers[singer].delete(:follower)
      end
      followings.each do |singer|
        @singers[singer[:name]] = singer
        @singers[singer[:name]][:following] = true
      end
      followers.each do |singer|
        @singers[singer[:name]] ||= singer
        @singers[singer[:name]][:follower] = true
      end
      @schanged = true
      self
    end

    def add_new_songs(block, isfav=false)
      require 'time'

      now = Time.now

      # Favlist must be reset if specified
      if isfav
        @content.each do |sid, sinfo|
          sinfo.delete(:isfav)
        end
      end

      block.each do |r|
        r[:updated_at] = now
        r[:isfav]      = isfav if isfav
        # Keep the 1st created, b/c it is more accurate
        sid = r[:sid]

        r.delete(:since)
        r.delete(:sincev)
        if c = @content[sid]
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
          @content[sid] = r
        end
      end
      self
    end

    def list
      block = []
      @content.each do |href, r|
        title     = r[:title].scrub
        record_by = r[:record_by]
        stitle    = to_search_str(title)
        block << [title, record_by, stitle]
      end
      block.sort_by {|t, r, st| "#{st}:#{r}"}.each do |title, record_by, st|
        puts "%-50.50s %-24.24s %s" % [title, record_by, st]
      end
      self
    end

    # Also select_set implement an alternate selection
    def _build_filter_from_string(filter)
      if filter.start_with?('@')
        ffile = filter[1..-1]
        filter = Hash[File.read(ffile).split("\n").map{|f| f.split('=')}]
        filter[:fname] = ffile
      else
        filter = Hash[filter.split('/').map{|f| f.split('=')}]
      end
      filter = filter.transform_keys(&:to_sym)
      filter.each do |k, v|
        if k == :created
          filter[k] = v.split(',').map{|f| Time.parse(f)}
        else
          filter[k] = v.split(',') if v.include?(',')
        end
      end
      Plog.dump_info(filter:filter)
      filter
    end

    def each(options={})
      filter = options[:filter] || {}
      filter = _build_filter_from_string(filter) if filter.is_a?(String)
      econtent = []
      @content.each do |song_id, sinfo|
        if filter.size > 0
          pass = true
          filter.each do |fk, fv|
            if fk == :created
              from_time, to_time = fv
              to_time ||= Time.now
              if sinfo[fk].to_time < from_time || sinfo[fk].to_time > to_time
                pass = false
                break
              end
            else
              if fv.is_a?(Array)
                unless fv.include?(sinfo[fk].to_s)
                  pass = false
                  break
                end
              else
                unless sinfo[fk].to_s =~ /#{fv}/i
                  pass = false
                  break
                end
              end
            end
          end
          next unless pass
        end
        econtent << [song_id, sinfo]
      end
      if options[:pbar]
        bar = TTY::ProgressBar.new(options[:pbar] + ' [:bar] :percent',
                                   total:econtent.size)
      end
      econtent.each do |k, v|
        yield k, v
        bar.advance if options[:pbar]
      end
      true
    end
  end
end


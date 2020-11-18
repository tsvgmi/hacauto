#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        smule_song.rb
# Date:        2020-08-23 11:40:00 -0700
# Copyright:   E*Trade, 2020
# $Id$
#---------------------------------------------------------------------------
#++

module SmuleAuto
  class SmuleSong
    def initialize(sinfo, options={})
      @info          = sinfo
      @options       = options
      @surl          = "https://www.smule.com#{@info[:href]}"

      @info[:created] ||= Date.today
      if @info[:created].is_a?(String)
        @info[:created] = Date.parse(@info[:created])
      end
    end

    def [](key)
      @info[key]
    end

    def [](key, value)
      @info[key] = value
    end

    def _extract_info(perf)
      lyrics = nil
      if perf[:lyrics]
        lyrics = JSON.parse(perf[:lyrics], symbolize_names:true).
          map {|line| line.map {|w| w[:text]}.join}.join("\n")
      end

      output = {
        sid:           perf[:key],
        title:         perf[:title],
        stitle:        to_search_str(perf[:title]),
        href:          perf[:web_url],
        psecs:         perf[:song_length],
        created:       Time.parse(perf[:created_at]),
        avatar:        perf[:cover_url],
        orig_city:     (perf[:orig_track_city] || {}).values.join(', '),
        listens:       perf[:stats][:total_listens],
        loves:         perf[:stats][:total_loves],
        gifts:         perf[:stats][:total_gifts],
        record_by:     perf[:performed_by_url].sub(/^\//, ''),
        song_info_url: perf[:song_info_url],
        lyrics:        lyrics,
      }
      if perf[:child_count] <= 0
        if operf = perf[:other_performers][0]
          output.update(
            other_city:  operf ? (operf[:city] || {}).values.join(', ') : nil,
            record_by:   [perf[:performed_by], operf[:handle]].join(','),
          )
        end
      else
        output[:is_ensemble] = true
      end
      output
    end

    def get_ensemble_asset
      source    = HTTP.follow.get(@surl).to_s 
      asset_str = (source.split("\n").grep(/DataStore.Pages.Duet/)[0] || "").
        sub(/^\s+DataStore.Pages.Duet = {/, '{').sub(/;$/, '')
      res = JSON.parse(asset_str, symbolize_names:true) || {}
      main_out = _extract_info(res[:recording])
      outputs  = [main_out]
      res[:performances][:list].each do |jinfo|
        collab_out = _extract_info(jinfo).update(
          psecs:         main_out[:psecs],
          song_info_url: main_out[:song_info_url],
          orig_city:     main_out[:orig_city],
          lyrics:        main_out[:lyrics],
        )
        outputs << collab_out
      end
      outputs
    end

    def get_asset
      olink    = @surl.sub(/\/ensembles$/, '')
      source   = HTTP.follow.get(olink).to_s 
      document = Nokogiri::HTML(source)
      asset_str    = nil

      if stream = document.at('meta[name="twitter:player:stream"]')
        asset_str = document.css('head script')[0].text.split("\n").grep(/Recording:/)[0].sub(/^\s*Recording: /, '')[0..-2]
      elsif stream = document.css('script')[0]
        if asset_str = stream.text.split("\n").grep(/^\s+Recording: /)[0]
          asset_str = asset_str.sub(/^\s+Recording: /, '').sub(/,$/, '')
        end
      end
      unless asset_str
        return {}
      end
      res = JSON.parse(asset_str, symbolize_names:true) || {}
      unless perf = res[:performance]
        Plog.dump_error(msg:"No performance data found", olink:olink)
        return {}
      end

      lyrics = nil
      if perf[:lyrics]
        lyrics = JSON.parse(perf[:lyrics], symbolize_names:true).
          map {|line| line.map {|w| w[:text]}.join}.join("\n")
      end

      output = {
        sid:           perf[:key],
        title:         perf[:title],
        stitle:        to_search_str(perf[:title]),
        href:          perf[:web_url],
        psecs:         perf[:song_length],
        created:       perf[:created_at],
        avatar:        perf[:cover_url],
        orig_city:     (perf[:orig_track_city] || {}).values.join(', '),
        listens:       perf[:stats][:total_listens],
        loves:         perf[:stats][:total_loves],
        gifts:         perf[:stats][:total_gifts],
        record_by:     perf[:performed_by],
        song_info_url: perf[:song_info_url],
        lyrics:        lyrics,
      }
      if perf[:child_count] <= 0
        operf = (perf[:other_performers][0] || {})
        output.update(
          other_city:  operf ? (operf[:city] || {}).values.join(', ') : nil,
          record_by:   [perf[:performed_by], operf[:handle]].join(','),
        )
      else
        output[:is_ensemble] = true
      end
      if @options[:verbose]
        output.update(res:res)
      end
      output
    end

    def play(spage)
      href = @info[:href].sub(/\/ensembles$/, '')
      # This will start playing
      # Page was archived
      spinner = TTY::Spinner.new("[:spinner] Loading ...",
                                    format: :pulse_2)
      spinner.auto_spin      
      spage.goto(href)
      %w(div.error-gone div.page-error).each do |acss|
        if spage.css(acss).size > 0
          Plog.info("#{@info[:title]} is gone")
          spinner.stop('Done!')
          return :deleted
        end
      end
      spage.click_and_wait('button._1oqc74f')

      1.upto(15) do
        duration_s = spage.css("._vln25l")[0]
        if duration_s && duration_s.text != "00:00"
          break
        end
        sleep 2
        spage.refresh
      end
      spinner.stop('Done!')

      # Should pickup for joined file where info was not picked up
      # at first
      asset = get_asset
      if @info[:href] !~ /ensembles$/ && @info[:other_city].to_s == ""
        @info[:other_city] = asset[:other_city]
      end

      # Click on play
      @info.update(listens:asset[:listens], loves:asset[:loves],
                   psecs:asset[:psecs])
      @info[:listens] += 1
      @info[:psecs]
    end
    
    def download_from_singsalon(ssconnect=nil, coptions={})
      begin
        if @options[:force] || !test(?f, @info[:sfile])
          if ssconnect
            Plog.info("Downloading for #{@info[:title]}")
            get_audio_from_singsalon(@info[:sfile], ssconnect)
          else
            Plog.error("Need to download #{@info[:stitle]}/#{@info[:record_by]}, but there is no connection")
            return false
          end
        end
        if test(?s, @info[:sfile])
          update_mp4tag(coptions[:excuser])
        end
        unless test(?l, @info[:ofile])
          unless test(?d, File.dirname(@info[:ofile]))
            FileUtils.mkdir_p(File.dirname(@info[:ofile]), verbose:true)
          end
          FileUtils.symlink(@info[:sfile], @info[:ofile],
                            verbose:true, force:true)
        end
      rescue => errmsg
        Plog.dump_error(errmsg:errmsg)
        return false
      end
      true
    end

    def is_mp4_tagged?(excuser=nil)
      sfile = @info[:sfile]
      if !sfile || !test(?s, sfile)
        Plog.error("#{@info[:stitle]}:#{sfile} empty or not exist")
        return false
      end
      wset = `atomicparsley #{sfile} -t`.split("\n").map {|l|
        key, value = l.split(/\s+contains:\s+/)
        key = key.split[-1].gsub(/[^a-z0-9_]/i, '').to_sym
        [key, value]
      }
      wset    = Hash[wset]
      album   = @info[:created].strftime("Smule-%Y.%m")
      year    = @info[:created].strftime("%Y")
      aartist = @info[:record_by].gsub(/(,?)#{excuser}(,?)/, '')
      if wset[:nam] == 'ver:1' || wset[:alb] != album || \
          wset[:day] != year || wset[:aART] != aartist
        wset.delete(:lyr)
        Plog.dump_info(msg:"Tagging #{sfile}", wset:wset, title:@info[:title],
                       record_by:@info[:record_by])
        return false
      end
      true
    end

    def update_mp4tag(excuser=nil)
      if is_mp4_tagged?(excuser)
        return :was_tagged
      end
      ofile = @info[:sfile]
      if ofile && test(?f, ofile)
        href    = 'https://www.smule.com' + @info[:href]
        date    = @info[:created].strftime("%Y-%m-%d")
        album   = @info[:created].strftime("Smule-%Y.%m")
        artist  = @info[:record_by].gsub(',', ', ')
        year    = @info[:created].strftime("%Y")
        comment = "#{date} - #{href}"
        title   = clean_emoji(@info[:title]).gsub(/\'/, "")

        command = "atomicparsley #{ofile}"

        # Get the artwork
        lcfile  = File.basename(@info[:avatar])
        curl(@info[:avatar], lcfile)
        if test(?f, lcfile) && `file #{lcfile}` =~ /JPEG/
          command += " --artwork REMOVE_ALL --artwork #{lcfile}"
        end
        command += " --title '#{title}'"
        command += " --artist '#{artist}'"
        command += " --album '#{album}'"
        if excuser
          aartist = @info[:record_by].gsub(/(,?)#{excuser}(,?)/, '')
          command += " --albumArtist '#{aartist}'"
        end
        command += " --year '#{year}'"
        command += " --comment '#{comment}'"

        if lyric = @info[:lyrics] || self.get_asset[:lyrics]
          tmpf = Tempfile.new("lyric")
          tmpf.puts(lyric)
          tmpf.close
          l_flag = " --lyricsFile #{tmpf.path}"
        else
          l_flag = ''
        end

        output = `(set -x; #{command} --overWrite #{l_flag}) | tee /dev/tty`.
          encode("UTF-8", invalid: :replace, replace: "")
        if output =~ /insufficient space to retag the source file/io
          return :error
        end
        FileUtils.remove(lcfile, verbose:true)
        return :updated
      else
        return :notfound
      end
    end

    def wait_loop(limit, msg, sleep=1)
      wait_time = 0
      Plog.info("Waiting for #{msg}:#{limit}")
      while true
        if wait_time >= limit
          Plog.error("Timeout waiting for operation")
          return false
        end
        yield
        sleep(sleep)
        wait_time += sleep
      end
      Plog.info("found")
      true
    end

    def wait_for_last_file(wdir, ofile, wtime=3600)
      Plog.info("Right click and download to #{ofile} please")
      m4file = nil
      wait_loop(wtime, "see file") do
        m4file = Dir.glob("#{wdir}/*.m4a").
          sort_by{|r| File.mtime(r)}.last
        break if (m4file && test(?f, m4file))
      end
      if !m4file || !test(?f, m4file)
        return false
      end

      wait_loop(60, "see content") do
        if (fsize = File.size(m4file)) > 1_000_000
          break
        end
      end
      File.open(ofile, 'wb') do |f|
        f.write(File.read(m4file))
      end
      File.delete(m4file)
      Plog.info("Wrote #{ofile}(#{File.size(ofile)} bytes)")
      true
    end

    def get_audio_from_singsalon(ofile, ssconnect)
      olink   = 'https://www.smule.com/' + @info[:href].sub(/\/ensembles$/, '')
      ssconnect.goto('/smule-downloader')
      ssconnect.type('input.downloader-input', olink)
      ssconnect.click_and_wait('input.ipsButton[value~=Fetch]')

      # This open up new window
      handles    = ssconnect.window_handles
      cur_handle = ssconnect.window_handle
      begin
        wait_for_last_file(Dir.pwd, ofile)
      rescue => errmsg
        Plog.dump_error(errmsg:errmsg)
      end
      test(?s, ofile)
    end

    def self.collect_collabs(user, days)
      days        = days.to_i
      last_date   = (Time.now - days*24*3600)
      collab_list = Performance.
        where(Sequel.like(:record_by, user)).
        where(Sequel.like(:href, '%/ensembles')).
        where(created:Date.today-days..Date.today).
        reverse(:created)
      if collab_list.count <= 0
        Plog.info("No collabs found in last #{days} days")
        return []
      end
      result = []
      progress_set(collab_list, "Checking collabs") do |sinfo, bar|
        result.concat(SmuleSong.new(sinfo, verbose:true).get_ensemble_asset)
        true
      end
      result
    end

  end
end

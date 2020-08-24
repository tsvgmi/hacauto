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
        href:          perf[:web_url],
        psecs:         perf[:song_length],
        created:       perf[:created_at],
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
        operf = perf[:other_performers][0]
        output.update(
          other_city:  operf ? (operf[:city] || {}).values.join(', ') : nil,
          record_by:   [perf[:performed_by], operf[:handle]].join(','),
        )
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
      res    = JSON.parse(asset_str, symbolize_names:true) || {}
      perf   = res[:performance]
      lyrics = nil
      if perf[:lyrics]
        lyrics = JSON.parse(perf[:lyrics], symbolize_names:true).
          map {|line| line.map {|w| w[:text]}.join}.join("\n")
      end

      output = {
        sid:           perf[:key],
        title:         perf[:title],
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
        operf = perf[:other_performers][0]
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

      spinner = TTY::Spinner.new("[:spinner] Loading ...",
                                    format: :pulse_2)
      spinner.auto_spin
      # This will start playing
      spage.goto(href)
      %w(div.error-gone div.page-error).each do |acss|
        if spage.css(acss).size > 0
          Plog.info("#{@info[:title]} is gone")
          spinner.stop('Done!')
          return :deleted
        end
      end
      spage.click_and_wait('button._1oqc74f')
      count_set = spage.css("div._13gdiri")
      if count_set.size > 0
        if (value = count_set[0].text.to_i) > 0
          @info[:listens] = value
        end
        if (value = count_set[1].text.to_i) > 0
          @info[:loves] = value
        end
      end

      # The play time won't be known until the source is loaded
      duration_s = nil
      1.upto(15) do
        duration_s = spage.css("._vln25l")[0]
        if duration_s && duration_s.text != "00:00"
          break
        end
        sleep 2
        spage.refresh
      end
      spinner.stop('Done!')
      unless duration_s
        Plog.error("Cannot get song info")
        return 0
      end
      duration = duration_s.text.split(':')
      psecs    = duration[0].to_i * 60 + duration[1].to_i

      @info[:listens] += 1
      @info[:psecs] = psecs
    end
    
    def download_from_singsalon(ssconnect=nil, coptions={})
      begin
        if @options[:force] || !test(?f, @info[:sfile])
          if ssconnect
            Plog.info("Downloading for #{@info[:title]}")
            get_audio_from_singsalon(@info[:sfile], ssconnect)
          else
            Plog.error("Need to download song, but there is no connection")
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
        Plog.error("#{sfile} empty or not exist")
        return false
      end
      wset = `atomicparsley #{sfile} -t`.split("\n").map {|l|
        key, value = l.split(/\s+contains:\s+/)
        key = key.split[-1].gsub(/["]/, '')[1..-1].to_sym
        [key, value]
      }
      wset    = Hash[wset]
      album   = @info[:created].strftime("Smule-%Y.%m")
      year    = @info[:created].strftime("%Y")
      aartist = @info[:record_by].gsub(/(,?)#{excuser}(,?)/, '')
      if wset[:nam] == 'ver:1' || wset[:alb] != album || \
          wset[:day] != year || wset[:ART] != aartist
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
          command += " --artwork #{lcfile}"
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

        output = `(set -x; #{command} --overWrite #{l_flag}) | tee /dev/tty`
        if output =~ /insufficient space to retag the source file/io
          return :error
        end
        FileUtils.remove(lcfile, verbose:true)
        return :updated
      else
        return :notfound
      end
    end

    def get_audio_from_singsalon(ofile, ssconnect)
      olink   = 'https://www.smule.com/' + @info[:href].sub(/\/ensembles$/, '')
      ssconnect.type('input.downloader-input', olink)
      ssconnect.click_and_wait('input.ipsButton[value~=Fetch]')

      # This open up new window
      handles    = ssconnect.window_handles
      cur_handle = ssconnect.window_handle
      begin
        # This code is no longer active.  It was done during the time the site
        # switch to more debug mode to troubleshoot issue
        if handles.size > 1
          Plog.info("Switch to window #{handles[-1]} to download") if @options[:verbose]
          ssconnect.switch_to.window(handles[-1])
          sleep(4)
        end
        ssconnect.click_and_wait('a.ipsButton[download]')

        wait_time = 0
        while true
          if wait_time >= 60
            Plog.error("Timeout waiting for file to appear in Downloads")
            return false
          end
          m4file = Dir.glob("#{ENV['HOME']}/Downloads/*.m4a").
            sort_by{|r| File.mtime(r)}.last
          break if m4file
          sleep(1)
          wait_time += 1
        end

        Plog.info("Waiting for #{m4file}") if @options[:verbose]
        while (fsize = File.size(m4file)) < 1_000_000
          sleep(1)
        end
        File.open(ofile, 'wb') do |f|
          f.write(File.read(m4file))
        end
        Plog.info("Wrote #{ofile}(#{File.size(ofile)} bytes)")
      rescue => errmsg
        Plog.dump_error(errmsg:errmsg)
      ensure
        # This code is no longer active.  It was done during the time the site
        # switch to more debug mode to troubleshoot issue
        if handles.size > 1
          ssconnect.close
          ssconnect.switch_to.window(cur_handle)
        end
      end
      test(?s, ofile)
    end
  end
end

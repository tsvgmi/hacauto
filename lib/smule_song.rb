#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        smule_song.rb
# Date:        2020-08-23 11:40:00 -0700
# Copyright:   E*Trade, 2020
# $Id$
#---------------------------------------------------------------------------
#++

module SmuleAuto
  class FirefoxWatch
    def initialize(user, tmpdir, csong_file='cursong.yml', options={})
      @user       = user
      watch_dir   = `find #{tmpdir}/*/T -name 'rust_mozprofile.*'`.split("\n").
        sort_by{|d| File.mtime(d)}[-1]
      @watch_dir  = watch_dir
      Plog.info("Watching #{@watch_dir}")
      @csong_file = csong_file
      @options    = options
    end

    def change_handler(added)
      return if added.size <= 0
      STDERR.print('.'); STDERR.flush
      added.each do |f|
        begin
          SmuleSong.check_and_download(@csong_file, f, @user, @options)
        rescue Errno::ENOENT
          # Ignore this error.  Just glitch b/c I could not see fast
          # enough.  Likely non-mp4 file anyway
        rescue => errmsg
          p errmsg
        end
      end
    end

    def dirchange_handler(added)
      Plog.info("Dir is added: #{added.inspect}")
    end

    def start
      require 'listen'

      @listener = Listen.to(@watch_dir + '/cache2') do
        |modified, added, removed|
        change_handler(added) if added.size > 0
      end
      @listener.start
      @listener
    end
  end

  class SmulePage < SelPage
    def initialize(sdriver)
      super
    end

    def set_song_favorite(setit=true)
      # Click on the selector to expose
      click_and_wait("button.sc-pcYTN", 1, 1)
      refresh

      # This is actually toggle blindly.  So caller need to know/guess the current
      # before calling
      locator = 'span.sc-ptfmh.gtVEMN'

      cval = css('div.sc-qPVvu.Irslq svg path')[0][:fill]
      if cval == "#FFCE42"
        Plog.info("Already fav, skip it")
        return
      end
      cpos    = find_elements(:css, locator).size / 2
      click_and_wait(locator, 1, cpos)
      find_element(:xpath, "//html").click
      true
    end

    def set_like
      click_and_wait("div.sc-oTNDV.jzKNzB", 0, 0)
    end

    def set_song_tag(tag)
      if song_note =~ /#{tag}/
        Plog.info "Message already containing #{tag}"
        return false
      end
      text = ' ' + tag

      click_and_wait("button.sc-pcYTN", 1, 1)
      refresh
      locator = 'span.sc-ptfmh.gtVEMN'
      if page.css(locator).text !~ /Edit performance/
        find_element(:xpath, "//html").click
        return false
      end
      cpos    = find_elements(:css, locator).size / 2
      click_and_wait(locator, 1, cpos+2)

      type("textarea#message", text, append:true)  # Enter tag
      click_and_wait("input#recording-save")

      play_song(true)
    end

    def star_song(href)
      goto(href, 3)
      if css("div.sc-pBlxj.dGgbmN").size > 0
        Elog.eror("Already starred")
        return false
      end
      click_and_wait("div.sc-oTNDV.jzKNzB", 1)
      return true
    end

    # Play or pause song
    def play_song(doplay=true, options={})
      remain = 0
      refresh

      goto(options[:href]) if options[:href]
      if options[:href]
        %w(div.error-gone div.page-error).each do |acss|
          if css(acss).size > 0
            Plog.info("Song is gone")
            return :deleted
          end
        end
      end

      paths    = css('div.sc-pQsrT.bsHhNW svg path').size
      toggling = true
      if doplay && paths == 2
        Plog.info("Already playing.  Do nothing")
        toggling = false
      elsif !doplay && paths == 1
        Plog.info("Already stopped.  Do nothing")
        toggling = false
      end

      if doplay
        locator = 'span.sc-pYNsO'
        # First time I wait until song is loaded
        if options[:href]
          1.upto(5) do
            duration_s = css(locator)[1]
            if duration_s && duration_s.text != "00:00"
              break
            end
            sleep 2
            refresh
          end
        end
        curtime   = css(locator)[0].text.split(':')
        curtime_s = curtime[0].to_i*60 + curtime[1].to_i

        endtime   = css(locator)[1].text.split(':')
        endtime_s = endtime[0].to_i*60 + endtime[1].to_i

        remain    = endtime_s - curtime_s
      else
        remain = 0
      end

      if toggling
        Plog.info("Think play = #{doplay}, remain: #{remain}")
        click_and_wait('div.sc-pZCuu', 0)
      end
      remain
    end

    def get_comments
      click_and_wait("div.sc-oTNDV.jzKNzB",0,2)
      refresh
      res = []
      css('div.sc-pLyGp.hIGHoI').reverse.each do |acmt|
        comment = acmt.css('div.sc-pDboM.deGaYK').text.split
        user = comment[0]
        msg  = comment[1..-1].join(' ')
        res << [user, msg]
      end
      click_and_wait('div.sc-pBzUF.jfMcol', 0)

      # Show player up again
      click_and_wait('div.sc-pZCuu', 0)
      click_and_wait('div.sc-pZCuu', 0)
      res
    end

    def toggle_autoplay
      click_and_wait("div.sc-qWfkp")
    end

    def song_note
      css('span.sc-fzomuh.bBrjWV')[0].text
    end
  end

  class SmuleSong
    class << self
      def check_and_download(info_file, media_file, user, options={})
        fsize = File.size(media_file)
        if fsize < 1_000_000 || `file #{media_file}` !~ /Apple.*Audio/
          return
        end
        if info_file.is_a?(Hash)
          sinfo = info_file
        else
          sinfo = YAML.load_file(info_file)
        end
        SmuleSong.new(sinfo, options).
          check_and_download(media_file, user)
      end

      def update_from_url(url, options)
        sid   = File.basename(url)
        sinfo = Performance.first(sid:sid) || Performance.new(sid:sid)
        song  = SmuleSong.new(sinfo, options)
        if url =~ /ensembles$/
          result = song.get_ensemble_asset
        else
          result = [song.get_asset]
        end
        if options[:update]
          result.each do |sdata|
            sdata.delete(:lyrics)
            Plog.dump_info(title:sdata[:title], record_by:sdata[:record_by])
            sinfo = Performance.first(sid:sdata[:sid]) ||
                    Performance.new(sid:sdata[:sid])
            Plog.dump_info(data:sdata[:href], info:sinfo[:href],
                           sid:sinfo[:sid])
            sinfo.update(sdata)
            sinfo.save
          end
        end
        result
      end

      def song_dir
        @tdir ||= '/Volumes/Voice/SMULE'
      end

      def song_dir=(adir)
        @tdir = adir
      end
    end

    def initialize(sinfo, options={})
      @info          = sinfo
      @options       = options
      @surl          = "https://www.smule.com#{@info[:href]}"

      @info[:created] ||= Date.today
      if @info[:created].is_a?(String)
        @info[:created] = Date.parse(@info[:created])
      end
    end

    def ssfile
      File.join(SmuleSong.song_dir, 'STORE', @info[:sid] + '.m4a')
    end

    def sofile
      odir  = SmuleSong.song_dir +
        "/#{@info[:record_by].split(',').sort.join('-')}"
      FileUtils.mkdir_p(odir, verbose:true) unless test(?d, odir)
      title = @info[:title].strip.gsub(/[\/\"]/, '-')
      ofile = File.join(odir, title.gsub(/\&/, '-').gsub(/\'/, '-') + '.m4a')
      sfile = ssfile
      Plog.dump_info(sfile:sfile, ofile:ofile)
      if File.exist?(sfile) && !File.symlink?(ofile)
        FileUtils.remove(ofile, verbose:true, force:true)
        FileUtils.ln_s(sfile, ofile, verbose:true, force:true)
      end
      ofile
    end

    def move_song(new_name)
      cur_record = @info[:record_by]
      new_record = cur_record.gsub(old_name, new_name)
      if new_record == cur_record
        Plog.info("No change in data")
        return false
      end
      @info[:record_by] = new_record
      sofile
      true
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
        created:       Time.parse(perf[:created_at]),
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
      if spage.play_song(true, href:href) == :deleted
        spinner.stop('Done!')
        return :deleted
      end
      spinner.stop('Done!')

      # Should pickup for joined file where info was not picked up
      # at first
      asset = get_asset
      unless asset
        return 0
      end
      if @info[:href] !~ /ensembles$/ && @info[:other_city].to_s == ""
        @info[:other_city] = asset[:other_city]
      end

      # Click on play
      @info.update(listens:asset[:listens], loves:asset[:loves],
                   psecs:asset[:psecs])
      @info[:psecs]
    end

    def mp4_tags
      sfile = ssfile
      if !sfile || !test(?s, sfile)
        Plog.error("#{@info[:stitle]}:#{sfile} empty or not exist")
        return nil
      end
      wset = `set -x; atomicparsley #{sfile} -t`.split("\n").map {|l|
        key, value = l.split(/\s+contains:\s+/)
        key = key.split[-1].gsub(/[^a-z0-9_]/i, '').to_sym
        [key, value]
      }
      Hash[wset]
    end

    def media_size(sfile)
      output = `set -x; atomicparsley #{sfile} -T 1`.
        encode("UTF-8", invalid: :replace).split("\n").
        grep(/Media data:/)
      output[0].split[2].to_i
    end

    def is_mp4_tagged?(excuser=nil)
      wset    = mp4_tags
      album   = @info[:created].strftime("Smule-%Y.%m")
      year    = @info[:created].strftime("%Y")
      release = @info[:created].iso8601
      aartist = @info[:record_by].gsub(/(,?)#{excuser}(,?)/, '')
      if wset[:nam] == 'ver:1' || wset[:alb] != album || \
          (wset[:day] != year && wset[:day] != release) || \
          wset[:aART].to_s != aartist
        wset.delete(:lyr)
        Plog.dump_info(msg:"Tagging #{ssfile}",
                       wset:wset, title:@info[:title],
                       record_by:@info[:record_by])
        return false
      end
      true
    end

    def update_mp4tag(excuser=nil)
      if is_mp4_tagged?(excuser)
        return :was_tagged
      end
      ofile = ssfile
      if ofile && test(?f, ofile)
        href    = 'https://www.smule.com' + @info[:href]
        date    = @info[:created].strftime("%Y-%m-%d")
        album   = @info[:created].strftime("Smule-%Y.%m")
        artist  = @info[:record_by].gsub(',', ', ')
        release = @info[:created].iso8601
        comment = "#{date} - #{href}"
        title   = clean_emoji(@info[:title]).gsub(/\'/, "")

        command = "set -x; atomicparsley #{ofile}"

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
        command += " --year '#{release}'"
        command += " --comment '#{comment}'"

        if lyric = @info[:lyrics] || self.get_asset[:lyrics]
          tmpf = Tempfile.new("lyric")
          tmpf.puts(lyric)
          tmpf.close
          l_flag = " --lyricsFile #{tmpf.path}"
        else
          l_flag = ''
        end

        output = `(#{command} --overWrite #{l_flag}) | tee /dev/tty`.
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

    def check_and_download(f, user)
      puts "\n%-40.40s %12d" % [File.basename(f), File.size(f)]
      puts "%s %-40.40s %s" % [@info[:sid], @info[:stitle], @info[:record_by]]

      sfile = ssfile
      if test(?f, sfile)
        unless @options[:verify] 
          sofile
          return
        end
        csize  = self.media_size(sfile)
        fmsize = self.media_size(f)
        if (csize == fmsize) && self.is_mp4_tagged?(user)
          Plog.info("Verify same media size and tags: #{csize}")
          sofile
          return
        end
        Plog.info("Size: #{csize} <>? #{fmsize}")
      end

      Plog.info("Song missing or bad tag on local disk.  Create")
      FileUtils.cp(f, sfile, verbose:true)
      self.update_mp4tag(user)
      sofile

      if @options[:open]
        system("set -x; open -g #{sfile}")
        sleep(2)
      end
    end

    def self.collect_collabs(user, days)
      days        = days.to_i
      last_date   = (Time.now - days*24*3600)
      collab_list = Performance.
        where(Sequel.like(:record_by, user)).
        where(Sequel.like(:href, '%/ensembles')).
        where(created:Date.today-days..(Date.today + 1)).
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

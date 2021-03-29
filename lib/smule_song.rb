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
      watch_dir   = `find #{tmpdir} -name 'rust_mozprofile*' 2>/dev/null`.
        split("\n").sort_by{ |d| File.mtime(d)}[-1]
      @watch_dir  = watch_dir
      @csong_file = csong_file
      @logger     = options[:logger] || PLogger.new($stderr)
      @options    = options

      @logger.info("Watching #{@watch_dir}")
      @logger.dump_info(msg:"Watching #{@watch_dir}")
    end

    def change_handler(added)
      return if added.size <= 0
      added.each do |f|
        begin
          SmuleSong.check_and_download(@csong_file, f, @user, @options)
        rescue Errno::ENOENT
          # Ignore this error.  Just glitch b/c I could not see fast
          # enough.  Likely non-mp4 file anyway
        rescue => e
          p e
        end
      end
    end

    def dirchange_handler(added)
      logger.info("Dir is added: #{added.inspect}")
    end

    def start
      require 'listen'

      @listener = Listen.to(@watch_dir + '/cache2') do
        |_modified, added, _removed|
        change_handler(added) if added.size > 0
      end
      @listener.start
      @listener
    end
  end

  class SmulePage < SelPage
    Locators = {
      sc_auto_play:           ['div.sc-qWfkp',            0],
      sc_comment_close:       ['div.sc-gsBrbv.dgedbA',    0],
      sc_comment_open:        ['div.sc-iitrsy',           2],
      sc_cont_after_arch:     ['a.sc-cvJHqN',             1],
      sc_expose_play_control: ['div.sc-pZCuu',            0],
      sc_favorite_toggle:     ['span.sc-ptfmh.gtVEMN',    -1],
      sc_like:                ['div.sc-oTNDV.jzKNzB',     0],
      sc_play_continue:       ['a.sc-hYZPRl.gumLkx',      0],
      sc_play_toggle:         ['div.sc-fiKUUL',           0],
      sc_song_menu:           ['button.sc-jbiwVq.dqCLEx', 1],
      sc_star:                ['div.sc-hYAvag.jfgTmU',    0],
    }

    def click_smule_page(elem, delay: 2)
      elem = Locators[elem]
      unless elem
        raise "#{elem} not defined in Locators"
      end
      clickit(elem[0], wait:delay, index:elem[1], move:true)
      refresh if delay > 0
      true
    end

    def set_song_favorite(setit: true)
      click_smule_page(:sc_song_menu, 1)

      locator = 'div.sc-hKKeuH.kXQUbk'
      cval = css("#{locator} svg path")[0][:fill]

      if setit && cval == "#FFCE42"
        Plog.info("Already fav, skip it")
        return false
      elsif !setit && cval != "#FFCE42"
        Plog.info("Already not-fav, skip it")
        return false
      end
      cpos    = find_elements(:css, locator).size / 2
      click_and_wait(locator, 1, cpos)
      find_element(:xpath, "//html").click
      true
    end

    def set_like
      click_smule_page(:sc_like, 0, 0)
    end

    def set_song_tag(tag)
      if song_note =~ /#{tag}/
        Plog.debug "Message already containing #{tag}"
        return false
      end
      text = ' ' + tag

      click_smule_page(:sc_song_menu)
      locator = 'span.sc-jgHCyG.jYOAjG'
      if page.css(locator).text !~ /Edit performance/
        find_element(:xpath, "//html").click
        return false
      end
      cpos = (find_elements(:css, locator).size + 1)/2
      click_and_wait(locator, 1, cpos)

      type("textarea#message", text, append:true)  # Enter tag
      click_and_wait("input#recording-save")

      toggle_play(true)
    end

    def star_song(href)
      goto(href, 3)
      elem = Locators[:sc_star]
      unless elem
        raise "#{elem} not defined in Locators"
      end

      fill = (css("#{elem[0]} svg path")[0] || {})[:fill]
      unless fill
        return false
      end
      if fill == "#FD286E"
        Plog.error("Already starred")
        return false
      end
      click_smule_page(:sc_star, 1)
      return true
    end

    # Play or pause song
    def toggle_play(doplay=true, options={})
      remain = 0
      refresh

      paths    = css('div.sc-fiKUUL svg path').size
      toggling = true
      if doplay && paths == 2
        Plog.debug("Already playing.  Do nothing")
        toggling = false
      elsif !doplay && paths == 1
        Plog.debug("Already stopped.  Do nothing")
        toggling = false
      end

      play_locator = 'span.sc-lgqmxq.FGHoO'

      if toggling
        Plog.debug("Think play = #{doplay}, remain: #{remain}")
        click_smule_page(:sc_play_toggle, 0)
        if doplay
          if css(play_locator).size == 2
            sleep_round = 0
            while true
              endtime = css(play_locator)[1]
              if endtime
                if endtime.text != "00:00"
                  if options[:href]
                    if sleep_round > 2
                      sleep(1)
                      click_smule_page(:sc_play_continue, 0)
                      click_smule_page(:sc_play_continue, 0)
                    else
                      sleep(1)
                      click_smule_page(:sc_play_toggle, 0)
                    end
                  end
                  break
                end
              end
              sleep 2
              sleep_round += 1
              refresh
            end
          else
            Plog.error("Can't see time elememt.  Just pause and guess")
            sleep 2
          end
        end
      end

      if doplay
        if css(play_locator).size == 2
          curtime   = css(play_locator)[0].text.split(':')
          curtime_s = curtime[0].to_i*60 + curtime[1].to_i

          endtime   = css(play_locator)[1].text.split(':')
          endtime_s = endtime[0].to_i*60 + endtime[1].to_i

          remain    = endtime_s - curtime_s
        else
          remain    = 300
        end
      else
        remain = 0
      end
      remain
    end

    def get_comments
      click_smule_page(:sc_comment_open, 0.5)
      res = []
      #css('div.sc-ksPlPm.fiBdLJ').reverse.each do |acmt|
      css('div.sc-hBmvGb.gugxcI').reverse.each do |acmt|
        comment = acmt.text.split
        user = comment[0]
        msg  = (comment[1..-1] || []).join(' ')
        res << [user, msg]
      end
      click_smule_page(:sc_comment_close, 0)
      click_smule_page(:sc_play_toggle, 0)
      res
    end

    def toggle_autoplay
      click_smule_page(:sc_auto_play)
    end

    def song_note
      locator = 'span.sc-jgHCyG.koUJIA'
      if css(locator).size > 0
        css(locator)[0].text
      else
        Plog.error("#{locator} not found (song note)")
        ''
      end
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
          sinfo = YAML.safe_load_file(info_file)
        end
        SmuleSong.new(sinfo, options).
          check_and_download(media_file, user)
      end

      def update_from_url(url, options)
        sid   = File.basename(url)
        href  = url.sub(%r[^https://www.smule.com], '')
        sinfo = Performance.first(sid:sid) || Performance.new(sid:sid, href:href)
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
      @logger        = options[:logger] || PLogger.new($stderr)

      @info[:created] ||= Date.today
      if @info[:created].is_a?(String)
        @info[:created] = Date.parse(@info[:created])
      end
      @ssl_context = OpenSSL::SSL::SSLContext.new
      @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    def ssfile
      File.join(SmuleSong.song_dir, 'STORE', @info[:sid] + '.m4a')
    end

    def sofile
      odir  = SmuleSong.song_dir +
        "/#{@info[:record_by].split(',').sort.join('-')}"
      FileUtils.mkdir_p(odir, verbose:true) unless test('d', odir)
      title = @info[:title].strip.gsub(/[\/\"]/, '-')
      ofile = File.join(odir, title.gsub(/\&/, '-').gsub(/\'/, '-') + '.m4a')
      sfile = ssfile
      @logger.dump_info(sfile:sfile, ofile:ofile)
      if File.exist?(sfile) && !File.symlink?(ofile)
        FileUtils.remove(ofile, verbose:true, force:true)
        FileUtils.ln_s(sfile, ofile, verbose:true, force:true)
      end
      ofile
    end

    def move_song(old_name, new_name)
      cur_record = @info[:record_by]
      new_record = cur_record.gsub(old_name, new_name)
      if new_record == cur_record
        @logger.info("No change in data")
        return false
      end
      @info[:record_by] = new_record
      sofile
      true
    end

    def [](key)
      @info[key]
    end

    def []=(key, value)
      @info[key] = value
    end

    def _extract_info(perf)
      lyrics = nil
      if perf[:lyrics]
        lyrics = JSON.parse(perf[:lyrics], symbolize_names:true).
          map { |line| line.map { |w| w[:text] }.join }.join("\n")
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
        operf = perf[:other_performers][0]
        if operf
          output.update(
            other_city:  operf ? (operf[:city] || {}).values.join(', ') : nil,
            record_by:   [perf[:performed_by], operf[:handle]].join(','),
          )
        end
      end
      output
    end

    def get_ensemble_asset
      source    = HTTP.follow.get(@surl, ssl_context:@ssl_context).to_s 
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
      source   = HTTP.follow.get(olink, ssl_context:@ssl_context).to_s 
      document = Nokogiri::HTML(source)
      asset_str    = nil

      if !(stream = document.at('meta[name="twitter:player:stream"]')).nil?
        asset_str = document.css('head script')[0].text.split("\n").
          grep(/Recording:/)[0].sub(/^\s*Recording: /, '')[0..-2]
      elsif !(stream = document.css('script')[0]).nil?
        asset_str = stream.text.split("\n").grep(/^\s+Recording: /)[0]
        if asset_str
          asset_str = asset_str.sub(/^\s+Recording: /, '').sub(/,$/, '')
        end
      end
      unless asset_str
        return {}
      end
      res  = JSON.parse(asset_str, symbolize_names:true) || {}
      perf = res[:performance]
      unless perf
        @logger.dump_error(msg:"No performance data found", olink:olink)
        return {}
      end

      lyrics = nil
      if perf[:lyrics]
        lyrics = JSON.parse(perf[:lyrics], symbolize_names:true).
          map { |line| line.map { |w| w[:text] }.join }.join("\n")
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
      spinner = TTY::Spinner.new("[:spinner] Loading ...",
                                 format: :pulse_2)
      spinner.auto_spin      

      spage.goto(href)
      %w(div.error-gone div.page-error).each do |acss|
        if spage.css(acss).size > 0
          Plog.info("Song is gone")
          spinner.stop('Done!')
          return :deleted
        end
      end

      msgs = spage.get_comments
      spage.toggle_play(true, href:href)
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
      [@info[:psecs], msgs]
    end

    def mp4_tags
      sfile = ssfile
      if !sfile || !test('s', sfile)
        @logger.error("#{@info[:stitle]}:#{sfile} empty or not exist")
        return nil
      end
      wset = _run_command("atomicparsley #{sfile} -t").
        split("\n").map { |l|
        key, value = l.split(/\s+contains:\s+/)
        key = key.split[-1].gsub(/[^a-z0-9_]/i, '').to_sym
        [key, value]
      }
      Hash[wset]
    end

    def media_size(sfile)
      output = _run_command("atomicparsley #{sfile} -T 1").
        split("\n").grep(/Media data:/)
      output[0].split[2].to_i
    end

    def is_mp4_tagged?(excuser: nil)
      wset = mp4_tags
      unless wset
        return false
      end
      album   = @info[:created].strftime("Smule-%Y.%m")
      release = @info[:created].iso8601
      aartist = @info[:record_by].gsub(/(,?)#{excuser}(,?)/, '')
      if wset[:nam] == 'ver:1' || wset[:alb] != album || \
          wset[:day] != release || wset[:aART].to_s != aartist
        wset.delete(:lyr)
        @logger.dump_info(msg:"Tagging not matched for #{ssfile}",
                          wset:wset, title:@info[:title],
                          record_by:@info[:record_by])
        return false
      end
      true
    end

    def _run_command(command)
      @logger.info(command)
      `#{command}`.chomp.encode("UTF-8", invalid: :replace, replace: "")
    end

    def update_mp4tag(excuser: nil)
      if is_mp4_tagged?(excuser)
        return :was_tagged
      end
      ofile = ssfile
      if ofile && test('f', ofile)
        href    = 'https://www.smule.com' + @info[:href]
        date    = @info[:created].strftime("%Y-%m-%d")
        album   = @info[:created].strftime("Smule-%Y.%m")
        artist  = @info[:record_by].gsub(',', ', ')
        release = @info[:created].iso8601
        comment = "#{date} - #{href}"
        title   = clean_emoji(@info[:title]).gsub(/\'/, "")

        command = "atomicparsley #{ofile}"

        # Get the artwork
        lcfile  = File.basename(@info[:avatar])
        curl(@info[:avatar], lcfile)
        if test('f', lcfile) && `file #{lcfile}` =~ /JPEG/
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

        lyric = @info[:lyrics] || self.get_asset[:lyrics]
        if lyric
          tmpf = Tempfile.new("lyric")
          tmpf.puts(lyric)
          tmpf.close
          l_flag = " --lyricsFile #{tmpf.path}"
        else
          l_flag = ''
        end

        output = _run_command("#{command} --overWrite #{l_flag}")
        if output =~ /insufficient space to retag the source file/io
          return :error
        end
        FileUtils.remove(lcfile, verbose:true)
        :updated
      else
        :notfound
      end
    end

    def check_and_download(file, user)
      @logger.info format("%<file>s %<size>d", file: File.basename(file),
                          size: File.size(file))
      @logger.info format("%<sid>s %<title>s %<record>s", sid: @info[:sid],
                          title: @info[:stitle], record: @info[:record_by])

      sfile = ssfile
      if test('f', sfile)
        unless @options[:verify] 
          sofile
          #_run_command("open -g #{sfile}") if @options[:open]
          return
        end
        csize  = self.media_size(sfile)
        fmsize = self.media_size(file)
        if (csize == fmsize) && self.is_mp4_tagged?(user)
          @logger.info("Verify same media size and tags: #{csize}")
          sofile
          #_run_command("open -g #{sfile}") if @options[:open]
          return
        end
        @logger.info("Size: #{csize} <>? #{fmsize}")
      end

      @logger.info("Song missing or bad tag on local disk.  Create")
      FileUtils.cp(file, sfile, verbose:true)
      self.update_mp4tag(user)
      sofile

      if @options[:open]
        _run_command("open -g #{sfile}")
        sleep(2)
      end
    end

    def self.collect_collabs(user, days)
      days        = days.to_i
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
      progress_set(collab_list, "Checking collabs") do |sinfo, _bar|
        result.concat(SmuleSong.new(sinfo, verbose:true).get_ensemble_asset)
        true
      end
      result
    end
  end
end

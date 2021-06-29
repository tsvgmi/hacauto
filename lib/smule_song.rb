#!/usr/bin/env ruby
# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        smule_song.rb
# Date:        2020-08-23 11:40:00 -0700
# Copyright:   E*Trade, 2020
# $Id$
#---------------------------------------------------------------------------
#++

module SmuleAuto
  # Docs for FirefoxWatch
  class FirefoxWatch
    def initialize(user, tmpdir, csong_file='cursong.yml', options={})
      @user         = user
      watch_dir     = `find #{tmpdir} -name 'rust_mozprofile*' 2>/dev/null`
                      .split("\n").max_by { |d| File.mtime(d) }
      @watch_dir    = watch_dir
      @csong_source = csong_file
      @logger       = options[:logger] || PLogger.new($stderr)
      @options      = options

      @logger.info("Watching #{@watch_dir}")
      @logger.dump_info(msg: "Watching #{@watch_dir}")
    end

    def change_handler(added)
      return if added.size <= 0

      added.each do |f|
        SmuleSong.check_and_download(@csong_source, f, @user, @options)
      rescue Errno::ENOENT
        # Ignore this error.  Just glitch b/c I could not see fast
        # enough.  Likely non-mp4 file anyway
      rescue StandardError => e
        Plog.error(e)
      end
    end

    def dirchange_handler(added)
      logger.info("Dir is added: #{added.inspect}")
    end

    def start
      require 'listen'

      @listener = Listen.to("#{@watch_dir}/cache2") do |_modified, added, _removed|
        change_handler(added) unless added.empty?
      end
      @listener.start
      @listener
    end
  end

  # Docs for SmulePage
  class SmulePage < SelPage
    LOCATORS = {
      sc_auto_play:           ['div.sc-qWfkp',            0],
      sc_comment_close:       ['div.sc-gsBrbv.dgedbA',    0],
      sc_comment_open:        ['div.sc-hYAvag.jfgTmU',    2],
      sc_cont_after_arch:     ['a.sc-cvJHqN',             1],
      sc_expose_play_control: ['div.sc-pZCuu',            0],
      sc_favorite_toggle:     ['span.sc-ptfmh.gtVEMN',    -1],
      sc_like:                ['div.sc-oTNDV.jzKNzB',     0],
      sc_play_continue:       ['a.sc-hYZPRl.gumLkx',      0],
      sc_play_toggle:         ['div.sc-fiKUUL',           0],
      sc_song_menu:           ['button.sc-eUWgFQ.hcHFJT', 1],
      sc_star:                ['div.sc-hYAvag.jfgTmU',    0],
    }.freeze

    def click_smule_page(elem, delay: 2)
      elem = LOCATORS[elem]
      raise "#{elem} not defined in Locators" unless elem

      clickit(elem[0], wait: delay, index: elem[1], move: true)
      refresh if delay > 0
      true
    end

    def is_song_fav?
      click_smule_page(:sc_song_menu, delay: 1)
      locator = 'div.sc-cRcunm.kXGAjw'
      cval = css("#{locator} svg path")[0][:fill]
      find_element(:xpath, '//html').click
      cval == '#FFCE42'
    end

    def toggle_song_favorite(fav: true)
      click_smule_page(:sc_song_menu, delay: 1)

      locator = 'div.sc-cRcunm.kXGAjw'
      cval = css("#{locator} svg path")[0][:fill]

      if fav && cval == '#FFCE42'
        Plog.info('Already fav, skip it')
        return false
      elsif !fav && cval != '#FFCE42'
        Plog.info('Already not-fav, skip it')
        return false
      end
      cpos = find_elements(:css, locator).size / 2
      click_and_wait(locator, 1, cpos)
      find_element(:xpath, '//html').click
      true
    end

    def set_like
      click_smule_page(:sc_like, delay: 0)
    end

    def add_song_tag(tag, sinfo=nil, _options={})
      otag  = tag
      snote = ''
      if sinfo
        tag += sinfo[:created].strftime('_%y')
        if (snote = sinfo[:message]).nil?
          snote = sinfo[:message] = song_note
        end
        if snote =~ /#{tag}/
          Plog.debug "Message already containing #{tag}"
          return false
        end
      end
      click_smule_page(:sc_song_menu)
      locator = 'span.sc-gTgzIj.brYKCX'
      if page.css(locator).text !~ /Edit performance/
        find_element(:xpath, '//html').click
        return false
      end
      cpos = (find_elements(:css, locator).size + 1) / 2
      click_and_wait(locator, 1, cpos)

      text = snote.strip.gsub(/ #{otag}/, '').gsub(/ #{tag}/, '') + " #{tag}"
      type('textarea#message', text, append: false) # Enter tag
      sinfo[:message] = text if sinfo
      Plog.info("Setting note to: #{text}")
      click_and_wait('input#recording-save')
    end

    def star_song(href)
      goto(href, 3)
      elem = LOCATORS[:sc_star]
      raise "#{elem} not defined in Locators" unless elem

      fill = (css("#{elem[0]} svg path")[0] || {})[:fill]
      return false unless fill

      if fill == '#FD286E'
        Plog.error('Already starred')
        return false
      end
      click_smule_page(:sc_star, delay: 1)
      true
    end

    # Play or pause song
    def toggle_play(doplay: true, href: nil)
      remain = 0
      refresh

      # paths    = css('div.sc-iumJyn svg path').size
      paths    = css('div.sc-fiKUUL svg path').size
      toggling = true
      if doplay && paths == 2
        Plog.debug('Already playing.  Do nothing')
        toggling = false
      elsif !doplay && paths == 1
        Plog.debug('Already stopped.  Do nothing')
        toggling = false
      end

      play_locator = 'span.sc-lgqmxq.FGHoO'

      if toggling
        Plog.debug("Think play = #{doplay}")
        click_smule_page(:sc_play_toggle, delay: 0)
        if doplay
          if css(play_locator).size == 2
            sleep_round = 0
            while true
              endtime = css(play_locator)[1]
              if endtime && (endtime.text != '00:00')
                if href
                  sleep(1)
                  # This means it pulled from archive.  It needs another
                  # click to continue
                  if sleep_round > 2
                    click_smule_page(:sc_play_continue, delay: 0)
                    click_smule_page(:sc_play_continue, delay: 0)
                    # else
                    # click_smule_page(:sc_play_toggle, delay: 0)
                  end
                end
                break
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
          curtime_s = curtime[0].to_i * 60 + curtime[1].to_i

          endtime   = css(play_locator)[1].text.split(':')
          endtime_s = endtime[0].to_i * 60 + endtime[1].to_i

          remain    = endtime_s - curtime_s
        else
          remain    = 300
        end
      else
        remain = 0
      end
      remain
    end

    def comment_from_page
      click_smule_page(:sc_comment_open, delay: 0.5)
      res = []
      css('div.sc-hBmvGb.gugxcI').reverse.each do |acmt|
        # css('div.sc-iLcRNb.idNCQo').reverse.each do |acmt|
        comment = acmt.text.split
        user = comment[0]
        msg  = (comment[1..] || []).join(' ')
        res << [user, msg]
      end
      click_smule_page(:sc_comment_close, delay: 0)
      res
    end

    def toggle_autoplay
      click_smule_page(:sc_auto_play)
    end

    def song_note
      locator = 'span.sc-gTgzIj.dLCNLt'
      if css(locator).empty?
        Plog.error("#{locator} not found (song note)")
        ''
      else
        css(locator)[0].text
      end
    end
  end

  # Docs for SmuleSong
  class SmuleSong
    class << self
      def check_and_download(info_source, media_file, user, options={})
        fsize = File.size(media_file)
        return if fsize < 1_000_000 || `file #{media_file}` !~ /Apple.*Audio/

        sinfo = case info_source
                when Hash
                  info_source
                when Queue
                  cqueue = info_source
                  entry  = nil
                  entry = cqueue.pop until cqueue.empty?
                  Plog.dump(entry: entry)
                  entry
                else
                  YAML.safe_load_file(info_file)
                end
        SmuleSong.new(sinfo, options)
                 .check_and_download(media_file, user)
      end

      def update_from_url(url, options)
        sid   = File.basename(url)
        href  = url.sub(%r{^https://www.smule.com}, '')
        sinfo = Performance.first(sid: sid) || Performance.new(sid: sid, href: href)
        song  = SmuleSong.new(sinfo, options)
        result = if url =~ /ensembles$/
                   song.ensemble_asset_from_page
                 else
                   [song.asset_from_page]
                 end
        if options[:update]
          result.each do |sdata|
            sdata.delete(:lyrics)
            Plog.dump_info(title: sdata[:title], record_by: sdata[:record_by])
            sinfo = Performance.first(sid: sdata[:sid]) ||
                    Performance.new(sid: sdata[:sid])
            Plog.dump_info(data: sdata[:href], info: sinfo[:href],
                           sid: sinfo[:sid])
            sinfo.update(sdata)
            sinfo.save
          end
        end
        result
      end

      def song_dir
        @song_dir ||= '/Volumes/Voice/SMULE'
      end

      attr_writer :song_dir
    end

    def initialize(sinfo, options={})
      @info          = sinfo
      @options       = options
      @surl          = "https://www.smule.com#{@info[:href]}"
      @logger        = options[:logger] || PLogger.new($stderr)

      @info[:created] ||= Date.today
      @info[:created]          = Date.parse(@info[:created]) if @info[:created].is_a?(String)
      @ssl_context             = OpenSSL::SSL::SSLContext.new
      @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    def ssfile
      File.join(SmuleSong.song_dir, 'STORE', "#{@info[:sid]}.m4a")
    end

    def sofile
      odir = SmuleSong.song_dir +
             "/#{@info[:record_by].split(',').sort.join('-')}"
      FileUtils.mkdir_p(odir, verbose: true) unless test('d', odir)
      title = @info[:title].strip.gsub(%r{[/"]}, '-')
      ofile = File.join(odir, "#{title.gsub(/&/, '-').gsub(/'/, '-')}.m4a")
      sfile = ssfile
      @logger.dump_info(sfile: sfile, ofile: ofile)
      if File.exist?(sfile) && !File.symlink?(ofile)
        FileUtils.remove(ofile, verbose: true, force: true)
        FileUtils.ln_s(sfile, ofile, verbose: true, force: true)
      end
      ofile
    end

    def move_song(old_name, new_name)
      cur_record = @info[:record_by]
      new_record = cur_record.gsub(old_name, new_name)
      if new_record == cur_record
        @logger.info('No change in data')
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
        lyrics = JSON.parse(perf[:lyrics], symbolize_names: true)
                     .map { |line| line.map { |w| w[:text] }.join }.join("\n")
      end

      output = {
        sid:           perf[:key],
        title:         perf[:title],
        stitle:        to_search_str(perf[:title]),
        href:          perf[:web_url],
        message:       perf[:message],
        psecs:         perf[:song_length],
        created:       Time.parse(perf[:created_at]),
        avatar:        perf[:cover_url],
        orig_city:     (perf[:orig_track_city] || {}).values.join(', '),
        listens:       perf[:stats][:total_listens],
        loves:         perf[:stats][:total_loves],
        gifts:         perf[:stats][:total_gifts],
        record_by:     perf[:performed_by_url].sub(%r{^/}, ''),
        song_info_url: perf[:song_info_url],
        lyrics:        lyrics,
      }
      if perf[:child_count] <= 0
        operf = perf[:other_performers][0]
        if operf
          output.update(
            # other_city:  operf ? (operf[:city] || {}).values.join(', ') : nil,
            record_by: [perf[:performed_by], operf[:handle]].join(',')
          )
        end
      end
      output
    end

    def ensemble_asset_from_page
      Plog.dump(url: @surl)
      source    = HTTP.follow.get(@surl, ssl_context: @ssl_context).to_s
      asset_str = (source.split("\n").grep(/DataStore.Pages.Duet/)[0] || '')
                  .sub(/^\s+DataStore.Pages.Duet = {/, '{').sub(/;$/, '')
      outputs   = []
      begin
        res = JSON.parse(asset_str, symbolize_names: true) || {}
        main_out = _extract_info(res[:recording])
        outputs << main_out
        res[:performances][:list].each do |jinfo|
          collab_out = _extract_info(jinfo).update(
            psecs:         main_out[:psecs],
            song_info_url: main_out[:song_info_url],
            orig_city:     main_out[:orig_city],
            lyrics:        main_out[:lyrics]
          )
          outputs << collab_out
        end
      rescue JSON::ParserError => e
        Plog.dump_error(url: @surl, errmsg: e)
      end
      outputs
    end

    def asset_from_page
      olink = @surl.sub(%r{/ensembles$}, '')
      begin
        source = HTTP.follow.get(olink, ssl_context: @ssl_context).to_s
      rescue HTTP::Redirector::EndlessRedirectError => e
        Plog.error(errmsg: e)
        return {}
      end

      document = Nokogiri::HTML(source)
      asset_str = nil

      if !(stream = document.at('meta[name="twitter:player:stream"]')).nil?
        asset_str = document.css('head script')[0].text.split("\n")
                            .grep(/Recording:/)[0].sub(/^\s*Recording: /, '')[0..-2]
      elsif !(stream = document.css('script')[0]).nil?
        asset_str = stream.text.split("\n").grep(/^\s+Recording: /)[0]
        asset_str = asset_str.sub(/^\s+Recording: /, '').sub(/,$/, '') if asset_str
      end
      return {} unless asset_str

      res  = JSON.parse(asset_str, symbolize_names: true) || {}
      perf = res[:performance]
      unless perf
        @logger.dump_error(msg: 'No performance data found', olink: olink)
        return {}
      end

      lyrics = nil
      if perf[:lyrics]
        lyrics = JSON.parse(perf[:lyrics], symbolize_names: true)
                     .map { |line| line.map { |w| w[:text] }.join }.join("\n")
      end

      Plog.dump(perf: perf.reject { |k, _v| k == :lyrics }, _ofmt: 'Y')
      output = {
        sid:           perf[:key],
        title:         perf[:title],
        stitle:        to_search_str(perf[:title]),
        href:          perf[:web_url],
        message:       perf[:message],
        psecs:         perf[:song_length],
        created:       Time.parse(perf[:created_at]),
        expire_at:     perf[:expire_at] ? Time.parse(perf[:expire_at]) : nil,
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
          record_by:   [perf[:performed_by], operf[:handle]].join(',')
        )
      end
      output.update(res: res) if @options[:verbose]
      output
    end

    def play(spage, to_play: true)
      href = @info[:href].sub(%r{/ensembles$}, '')
      spinner = TTY::Spinner.new('[:spinner] Loading ...',
                                 format: :pulse_2)
      spinner.auto_spin

      count = 0
      loop do
        spage.goto(href)
        unless spage.css('.error-gone').empty?
          Plog.info('Song is gone')
          spinner.stop('Done!')
          return :deleted
        end
        # Keep retry if there are server error
        unless spage.css('.page-error').empty?
          count += 1
          if count >= 10
            spinner.stop('Done!')
            return :deleted
          end

          Plog.info("Page error [#{count}]: #{spage.css('.page-error').text}")
          sleep(2)
          redo
        end
        break
      end

      msgs = spage.comment_from_page

      # click_smule_page(:sc_play_toggle, delay: 0)
      spage.toggle_play(doplay: true, href: href) if to_play
      spinner.stop('Done!')

      # Should pickup for joined file where info was not picked up
      # at first
      if (asset = asset_from_page).nil?
        return 0
      end

      if !asset.empty?
        @info[:other_city] = asset[:other_city] if @info[:href] !~ /ensembles$/ && @info[:other_city].to_s != ''

        # Click on play
        @info.update(listens: asset[:listens], loves: asset[:loves],
                     psecs: asset[:psecs], message: asset[:message],
                     other_city: asset[:other_city],
                     expire_at: asset[:expire_at])
      end
      [@info[:psecs], msgs]
    end

    def mp4_tags
      sfile = ssfile
      if !sfile || !test('s', sfile)
        @logger.error("#{@info[:stitle]}:#{sfile} empty or not exist")
        return nil
      end
      wset = _run_command("atomicparsley #{sfile} -t")
             .split("\n").map do |l|
        key, value = l.split(/\s+contains:\s+/)
        key = key.split[-1].gsub(/[^a-z0-9_]/i, '').to_sym
        [key, value]
      end
      Hash[wset]
    end

    def media_size(sfile)
      output = _run_command("atomicparsley #{sfile} -T 1")
               .split("\n").grep(/Media data:/)
      output[0].split[2].to_i
    end

    def mp4_tagged?(excuser: nil)
      wset = mp4_tags
      return false unless wset

      album   = @info[:created].strftime('Smule-%Y.%m')
      release = @info[:created].iso8601
      aartist = @info[:record_by].gsub(/(,?)#{excuser}(,?)/, '')
      if wset[:nam] == 'ver:1' || wset[:alb] != album || \
         wset[:day] != release || wset[:aART].to_s != aartist
        wset.delete(:lyr)
        @logger.dump_info(msg: "Tagging not matched for #{ssfile}",
                          wset: wset, title: @info[:title],
                          record_by: @info[:record_by])
        return false
      end
      true
    end

    def _run_command(command)
      @logger.info(command)
      `#{command}`.chomp.encode('UTF-8', invalid: :replace, replace: '')
    end

    def update_mp4tag(excuser: nil)
      return :was_tagged if mp4_tagged?(excuser: excuser)

      ofile = ssfile
      if ofile && test('f', ofile)
        href    = "https://www.smule.com#{@info[:href]}"
        date    = @info[:created].strftime('%Y-%m-%d')
        album   = @info[:created].strftime('Smule-%Y.%m')
        artist  = @info[:record_by].gsub(',', ', ')
        release = @info[:created].iso8601
        comment = "#{date} - #{href}"
        title   = clean_emoji(@info[:title]).gsub(/'/, '')

        # Get the artwork
        command = "atomicparsley #{ofile}"
        lcfile  = File.basename(@info[:avatar])
        curl(@info[:avatar], ofile: lcfile)
        command += " --artwork REMOVE_ALL --artwork #{lcfile}" if test('f', lcfile) && `file #{lcfile}` =~ /JPEG/
        command += " --title '#{title}'"
        command += " --artist '#{artist}'"
        command += " --album '#{album}'"
        if excuser
          aartist = @info[:record_by].gsub(/(,?)#{excuser}(,?)/, '')
          command += " --albumArtist '#{aartist}'"
        end
        command += " --year '#{release}'"
        command += " --comment '#{comment}'"

        lyric = @info[:lyrics] || asset_from_page[:lyrics]
        if lyric
          tmpf = Tempfile.new('lyric')
          tmpf.puts(lyric)
          tmpf.close
          l_flag = " --lyricsFile #{tmpf.path}"
        else
          l_flag = ''
        end

        output = _run_command("#{command} --overWrite #{l_flag}")
        return :error if output =~ /insufficient space to retag the source file/io

        FileUtils.remove(lcfile, verbose: true)
        :updated
      else
        :notfound
      end
    end

    def check_and_download(file, user)
      @logger.info format('%<file>s %<size>d', file: File.basename(file),
                          size: File.size(file))
      @logger.info format('%<sid>s %<title>s %<record>s', sid: @info[:sid],
                          title: @info[:stitle], record: @info[:record_by])

      sfile = ssfile
      if test('f', sfile)
        unless @options[:verify]
          sofile
          # _run_command("open -g #{sfile}") if @options[:open]
          return
        end
        csize  = media_size(sfile)
        fmsize = media_size(file)
        if (csize == fmsize) && mp4_tagged?(excuser: user)
          @logger.info("Verify same media size and tags: #{csize}")
          sofile
          # _run_command("open -g #{sfile}") if @options[:open]
          return
        end
        @logger.info("Size: #{csize} <>? #{fmsize}")
      end

      @logger.info('Song missing or bad tag on local disk.  Create')
      FileUtils.cp(file, sfile, verbose: true)
      update_mp4tag(excuser: user)
      sofile

      return unless @options[:open]

      _run_command("open -g #{sfile}")
      sleep(2)
    end

    def self.collect_collabs(user, days)
      days        = days.to_i
      collab_list = Performance
                    .where(Sequel.like(:record_by, user))
                    .where(Sequel.like(:href, '%/ensembles'))
                    .where(created: Date.today - days..(Date.today + 1))
                    .reverse(:created)
      if collab_list.count <= 0
        Plog.info("No collabs found in last #{days} days")
        return []
      end
      result = []
      progress_set(collab_list, 'Checking collabs') do |sinfo, _bar|
        result.concat(SmuleSong.new(sinfo, verbose: true).ensemble_asset_from_page)
        true
      end
      result
    end
  end
end

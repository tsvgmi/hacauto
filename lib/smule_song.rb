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
      # @logger       = options[:logger] || PLogger.new($stderr)
      @options      = options

      Plog.info("Watching #{@watch_dir}")
      Plog.dump_info(msg: "Watching #{@watch_dir}")
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
    LOCATORS_3 = {
      sc_auto_play_off:   ['div.sc-dtwoBo.kLzgfZ',    0],  # 
      sc_comment_close:   ['div.sc-ksXhwv.iVzzFR',    0],  # Fixed
      sc_comment_open:    ['div.sc-hJxCPi.bERasM',    2],  # Fixed
      sc_play_toggle:     ['div.sc-eJBYSJ.csTlMB svg path', 0], # Fixed
      sc_song_menu:       ['button.sc-iLcRNb.idNCQo', 0],  # Fixed
      sc_heart:           ['div.sc-cuWcWY.jmonRw',    0],  # 

      sc_favorite_toggle: ['li.sc-jnHOtz.gLsOLI'],         # Fixed
      sc_comment_text:    ['div.sc-cAmlYy.jJRrEL'],        # Fixed
      sc_play_time:       ['span.sc-fFYUoA.FCJNq'],       # 
      sc_play_continue:   ['span.sc-gTgzIj.jLdwwx', 1], 
      sc_song_menu_text:  ['span.sc-ezipRf.bSkNQK'],       # Fixed
      sc_song_note:       ['span.sc-laRPJI.jDaPvs'],       # 
      sc_loves:           ['button.sc-cHjxUU.kKIftN', 0],   # Fixed
    }.freeze

    def click_smule_page(elem, delay: 2)
      if (elem = LOCATORS_3[elem]).nil?
        Plog.error "#{elem} not defined in Locators"
        return false
      end
      unless clickit(elem[0], wait: delay, index: elem[1], move: true)
        Plog.error "Error clicking #{elem}"
        return false
      end
      refresh if delay > 0
      true
    end

    def toggle_song_favorite(fav: true)
      click_smule_page(:sc_song_menu, delay: 1)

      locator = LOCATORS_3[:sc_favorite_toggle].first
      cval = (css("#{locator} svg path")[0] || {})[:fill]
      return false unless cval

      if fav && cval == '#FFCE42'
        Plog.info('Already fav, skip it')
        find_element(:css, 'body').click
        return false
      elsif !fav && cval != '#FFCE42'
        Plog.info('Already not-fav, skip it')
        find_element(:css, 'body').click
        return false
      end
      click_and_wait(locator, 1, 0)
      find_element(:css, 'body').click
      true
    end

    def add_any_song_tag(user, sinfo=nil, _options={})
      return unless sinfo

      locator = LOCATORS_3[:sc_loves][0]
      page.css(locator).each do |entry|
        case entry.text
        when /love/
          sinfo[:loves] = entry.text.to_i
        when /gifts/
          sinfo[:gifts] = entry.text.to_i
        end
      end

      tagset = []
      if sinfo[:isfav]
        toggle_song_favorite(fav: true)
        tagset << '#thvfavs_%y'
      end
      return unless sinfo[:record_by]
      return unless sinfo[:record_by].start_with?(user)

      if (sinfo[:record_by] == user) &&
         (sinfo[:created] < Time.now - 8 * 24 * 3600)
        tagset << '#thvopen_%y'
      end
      if sinfo[:record_by] == "#{user},#{user}" &&
         (!sinfo[:message] || !sinfo[:message].include?('#thvduets'))
        tagset << '#thvduets'
      end
      dbtags = ((SongTag.first(name: sinfo[:stitle]) || {})[:tags] || '')
               .split(',')
      smtags = Tag.where(sname: dbtags).map { |r| r[:lname] }.compact
      tagset += smtags

      add_song_tag(tagset, sinfo)
      # toggle_play(doplay: true)
    end

    def add_song_tag(tags, sinfo=nil)
      # Get the current note
      snote = ''
      if sinfo && (snote = sinfo[:message]).nil?
        snote = sinfo[:message] = song_note
      end

      osnote  = snote
      newnote = snote
      tags.each do |tag_t|
        if sinfo
          tag = sinfo[:created].strftime(tag_t)
          newnote += " #{tag}" if snote !~ /#{tag}/
        else
          tag = Time.now.strftime(tag_t)
          newnote += " #{tag}"
        end
      end

      # Nothing change - just return
      return true if osnote == newnote

      click_smule_page(:sc_song_menu)

      locator = LOCATORS_3[:sc_song_menu_text][0]
      if page.css(locator).text !~ /Edit performance/
        find_element(:xpath, '//html').click
        return false
      end

      # cpos = (find_elements(:css, locator).size + 1) / 2
      click_and_wait(locator, 1, 2)

      type('textarea#message', newnote, append: false) # Enter tag
      sinfo[:message] = newnote if sinfo
      Plog.info("Setting note to: #{newnote}")
      click_and_wait('input#recording-save')
    end

    def like_song(href=nil)
      goto(href, 3) if href
      elem = LOCATORS_3[:sc_heart]
      raise "#{elem} not defined in Locators" unless elem

      fill = (css("#{elem[0]} svg path")[0] || {})[:fill]
      return false unless fill

      if fill == '#FD286E'
        Plog.error('Already starred')
        return false
      end
      click_smule_page(:sc_heart, delay: 1)
      true
    end

    def _toggle_play(doplay: true, href: nil)
      Plog.debug("Think play = #{doplay}")

      play_locator = LOCATORS_3[:sc_play_time][0]
      click_smule_page(:sc_play_toggle, delay: 0)
      if doplay
        if css(play_locator).size == 2
          sleep_round = 0
          while true
            endtime = css(play_locator)[1]
            if endtime && (endtime.text != '00:00')
              if href && (sleep_round > 5)
                click_smule_page(:sc_play_continue, delay: 0)
                click_smule_page(:sc_play_continue, delay: 0)
              end
              break
            end
            sleep 1
            sleep_round += 1
            refresh
          end
        else
          Plog.error("Can't see time elememt.  Just pause and guess")
          sleep 2
        end
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

    # Play or pause song
    def toggle_play(doplay: true, href: nil)
      refresh
      limit = 5
      paths = nil

      Plog.dump_info(doplay:doplay)
      while limit > 0
        paths = css(LOCATORS_3[:sc_play_toggle].first).size
        break if paths > 0

        click_smule_page(:sc_play_time, delay: 1)
        limit -= 1
      end
      toggling = true
      if doplay && paths == 2
        Plog.debug("Already playing [#{paths}].  Do nothing")
        toggling = false
      elsif !doplay && paths == 1
        Plog.debug("Already stopped [#{paths}].  Do nothing")
        toggling = false
      else
        Plog.dump(paths: paths)
      end
      toggling ? _toggle_play(doplay: doplay, href: href) : 5
    end

    def comment_from_page
      click_smule_page(:sc_comment_open, delay: 0.5)
      res = []
      css(LOCATORS_3[:sc_comment_text].first).reverse.each do |acmt|
        comment = acmt.text.split
        user = comment[0]
        msg  = (comment[1..] || []).join(' ')
        res << [user, msg]
      end
      click_smule_page(:sc_comment_close, delay: 0)
      res
    end

    def autoplay_off
      click_smule_page(:sc_auto_play_off)
    end

    def song_note
      locator = LOCATORS_3[:sc_song_note].first
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
        return if fsize < 1_000_000

        ftype = `file #{media_file}`
        Plog.dump(media_file: media_file, ftype: ftype)

        return if ftype !~ /Apple.*(Audio|Video)/

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
        if url =~ /ensembles$/
          result = song.ensemble_asset_from_page
        else
          rdata = song.asset_from_page
          if rdata.empty?
            return []
          end
          result = [rdata]
        end

        singer = options[:singer]
        result = result.select { |r| r[:record_by] =~ /#{singer}/ } if singer

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
      # @logger        = options[:logger] || PLogger.new($stderr)

      @info[:created] ||= Date.today
      @info[:created]          = Date.parse(@info[:created]) if @info[:created].is_a?(String)
      @ssl_context             = OpenSSL::SSL::SSLContext.new
      @ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
    end

    def ssfile
      sid     = @info[:sid]
      new_loc = File.join(SmuleSong.song_dir, 'STORE', "#{sid[0..1]}/#{sid}.m4a")
      return new_loc if test(?f, new_loc)

      old_loc = File.join(SmuleSong.song_dir, 'STORE', "#{sid}.m4a")
      if test(?f, old_loc)
        if true
          return old_loc
        end
        new_dir = File.dirname(new_loc)
        FileUtils.mkdir_p(new_dir, verbose: true) unless test('d', new_dir)
        FileUtils.move(old_loc, new_loc, verbose: true)
        return new_loc
      end
      new_loc
    end

    def sofile
      odir = SmuleSong.song_dir +
             "/#{@info[:record_by].split(',').sort.join('-')}"
      FileUtils.mkdir_p(odir, verbose: true) unless test('d', odir)
      title = @info[:title].strip.gsub(%r{[/"]}, '-')
      #ofile = File.join(odir, "#{title.gsub(/[&']/, '-')}.m4a")
      ofile = File.join(odir, "#{@info[:stitle]}.m4a")
      sfile = ssfile
      #Plog.dump_info(sfile: sfile, ofile: ofile)

      if File.exist?(sfile) &&
          (!File.symlink?(ofile) || (File.readlink(ofile) != sfile))
        FileUtils.remove(ofile, verbose: true, force: true)
        FileUtils.ln_s(sfile, ofile, verbose: true, force: true)
        Plog.info(sfile:sfile, ofile:ofile)
        return [ofile, true]
      end
      return [ofile, false]
    end

    def move_song(old_name, new_name)
      cur_record = @info[:record_by]
      new_record = cur_record.gsub(old_name, new_name)
      if new_record == cur_record
        Plog.info('No change in data')
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

      record_by_ids = ([perf[:owner][:account_id]] +
                        perf[:other_performers].map { |r| r[:account_id] })
                      .join(',')

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
        record_by_ids: record_by_ids,
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
      rescue Errno::ECONNRESET, HTTP::ConnectionError => e
        Plog.error(errmsg: e)
        return {}
      end

      document = Nokogiri::HTML(source)
      stream   = document.css('script')[1]
      if !stream || stream.text.empty?
        Plog.dump_error(msg: 'No performance data found', olink: olink)
        return {}
      end

      begin
        new_asset = JSON.parse(stream, symbolized: true)
      rescue => errmsg
        Plog.dump_error(stream:stream)
        return {}
      end
      Plog.dump(new_asset:new_asset, _ofmt:'Y')
      website   = new_asset.find { |r| r['@type'] == 'Website' }
      audio     = new_asset.find { |r| r['@type'] =~ /(Audio|Video)Object/ }
      recording = new_asset.find { |r| r['@type'] == 'MusicRecording' }
      minsec    = recording['duration'][2..-2].split(':')

      descr     = (document.css('meta[name="description"]')[0] || {})['content']
      record_by = nil
      record_by = [Regexp.last_match(1), Regexp.last_match(2)].join(',') if descr =~ /recorded by (\S+) and (\S+)/
      authors = audio['author']
      authors = [authors] if authors.is_a?(Hash)
      record_by_ids = authors.map { |r| File.basename(r['url']) }.join(',')
      {
        sid:           File.basename(website['url']).sub(%r{/ensembles}, ''),
        title:         website['name'],
        stitle:        to_search_str(website['name']),
        href:          audio['url'].sub(%r{^https://www.smule.com}, ''),
        message:       audio['description'],
        psecs:         minsec[0].to_i * 60 + minsec[1].to_i,
        created:       Time.parse(audio['datePublished']),
        avatar:        audio['thumbnailUrl'],
        listens:       audio['interactionCount'],
        record_by:     record_by,
        record_by_ids: record_by_ids,
      }
      # output.update(res: new_asset) if Plog.debug?
    end

    def play(spage, to_play: true)
      href = @info[:href].sub(%r{/ensembles$}, '')
      spinner = TTY::Spinner.new('[:spinner] Loading ...', format: :pulse_2)
      spinner.auto_spin

      count = 0
      loop do
        spage.goto(href)
        if spage.css('header').text =~ /Recording (Deleted|Disabled)/o
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

      spage.toggle_play(doplay: true, href: href) if to_play
      spinner.stop('Done!')

      # Should pickup for joined file where info was not picked up
      # at first
      if (asset = asset_from_page).nil?
        return 0
      end

      unless asset.empty?
        @info[:other_city] = asset[:other_city] if @info[:href] !~ /ensembles$/ && @info[:other_city].to_s != ''

        # Click on play
        @info.update(listens: asset[:listens],
                     psecs: asset[:psecs], message: asset[:message],
                     other_city: asset[:other_city])
      end
      [@info[:psecs], msgs]
    end

    def mp4_tags
      sfile = ssfile
      if !sfile || !test('s', sfile)
        Plog.error("#{@info[:stitle]}:#{sfile} empty or not exist")
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
        Plog.dump_info(msg: "Tagging not matched for #{ssfile}",
                       wset: wset, title: @info[:title],
                       record_by: @info[:record_by])
        return false
      end
      true
    end

    def _run_command(command)
      Plog.debug(command)
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
      # Plog.dump_info(file:File.basename(file), size: File.size(file))
      Plog.dump_info(sid: @info[:sid],
                     title: @info[:stitle], record: @info[:record_by])

      sfile = ssfile
      if test('f', sfile)
        unless @options[:verify]
          sofile
          return
        end
        csize  = media_size(sfile)
        fmsize = media_size(file)
        if (csize == fmsize) && mp4_tagged?(excuser: user)
          Plog.info("Verify same media size and tags: #{csize}")
          if sofile && @options[:open]
            _run_command("open -g '#{sfile}'")
            sleep(2)
          end
          return
        end
      end

      #Plog.info('Song missing/ wrong size/ or bad tag on local disk.  Create')
      wdir = File.dirname(sfile)
      FileUtils.mkdir_p(wdir, verbose:true) unless test(?d, wdir)
      FileUtils.cp(file, sfile, verbose: true)
      update_mp4tag(excuser: user)
      ofile, changed = sofile

      return unless @options[:open]

      _run_command("open -g '#{sfile}'")
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

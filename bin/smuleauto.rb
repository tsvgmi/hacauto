#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hacauto.rb
# Date:        2017-07-29 09:54:48 -0700
# Copyright:   E*Trade, 2017
# $Id$
#---------------------------------------------------------------------------
#++
require File.dirname(__FILE__) + "/../etc/toolenv"
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'http'
require 'ruby-progressbar'
require 'core'
require 'site_connect'

def clean_emoji(str='')
  str=str.force_encoding('utf-8').encode
  arr_regex=[/[\u{1f600}-\u{1f64f}]/,/[\u{2702}-\u{27b0}]/,/[\u{1f680}-\u{1f6ff}]/,/[\u{24C2}-\u{1F251}]/,/[\u{1f300}-\u{1f5ff}]/]
  arr_regex.each do |regex|
          str = str.gsub regex, ''
  end
  return str
end

def time_since(since)
  case since
  when /(min|m)$/
    sincev = since.to_i * 60.0
  when /hr?$/
    sincev = since.to_i * 3600
  when /d$/
    sincev = since.to_i * 24*3600
  when /mo$/
    sincev = since.to_i * 24 * 30 * 3600
  when /yr$/
    sincev = since.to_i * 24 * 365 * 3600
  else
    0
  end
end

module SmuleAuto
  extendCli __FILE__

  class AudioHandler
    def initialize(link)
      @olink   = link.sub(/\/ensembles$/, '')
      source   = HTTP.follow.get(@olink).to_s 
      document = Nokogiri::HTML(source)
      if stream = document.at('meta[name="twitter:player:stream"]')
        @link = stream['content']
        asset = document.css('head script')[0].text.split("\n").
          grep(/Recording:/)[0].sub(/^\s*Recording: /, '')[0..-2]
        @song_info_url = 'https://www.smule.com' +
          JSON.parse(asset).dig('performance', 'song_info_url')
      else
        Plog.error("Link no longer contain song - #{link}")
      end
    end

    def get_audio(ofile)
      if @link
        audio = HTTP.follow.get(@link)
        File.open(ofile, 'wb') do |f|
          f.write(audio.body)
        end
      end
    end

    def get_lyric
      unless @song_info_url
        return nil
      end
      sdoc  = Nokogiri::HTML(`curl -s '#{@song_info_url}'`)
      asset = sdoc.css('head script')[0].text.split("\n").grep(/Song:/)[0].
        sub(/^\s*Song: /, '')[0..-2]
      CGI.unescapeHTML(JSON.parse(asset).dig('lyrics')).
                  gsub(/<br>/, "\n").
                  gsub(/<p>/, "\n\n")
    end
  end

  class Content
    attr_reader :content, :singers

    def initialize(user, cdir='.')
      @user  = user
      @cdir  = cdir
      @cfile = "#{cdir}/content-#{user}.yml"
      @sfile = "#{cdir}/singers.yml"
      if test(?f, @cfile)
        @content = YAML.load_file(@cfile)
      else
        @content = {}
      end

      @content.each do |k, r|
        r[:sincev] = time_since(r[:since]) / 3600.0
      end

      @singers = test(?f, @sfile) ? YAML.load_file(@sfile) : {}
    end

    def _write_with_backup(mfile, content)
      bakfile = File.join(ENV['HOME'], File.basename(mfile))
      [mfile, bakfile].each do |afile|
        b2file = afile + ".bak"
        if test(?f, afile)
          FileUtils.move(afile, b2file, verbose:true)
        end
        File.open(afile, 'w') do |fod|
          Plog.info("Writing #{content.size} entries to #{afile}")
          fod.puts content.to_yaml
        end
      end
    end

    def writeback
      _write_with_backup(@cfile, @content)
      _write_with_backup(@sfile, @singers)
      self
    end

    def set_follows(followings, followers)
      followings.each do |singer|
        @singers[singer[:name]] ||= singer
        @singers[singer[:name]][:following] = true
      end
      followers.each do |singer|
        @singers[singer[:name]] ||= singer
        @singers[singer[:name]][:follower] = true
      end
      self
    end

    def add_new_songs(block, isfav=false)
      now = Time.now
      block.each do |r|
        r[:updated_at] = now
        r[:isfav]      = isfav if isfav
        # Keep the 1st created, b/c it is more accurate
        if old_content = @content[r[:sid]]
          r[:created] = old_content[:created]
        end
        @content[r[:sid]] = r
      end
      self
    end

    def list
      block = []
      @content.each do |href, r|
        title          = r[:title].scrub
        record_by      = r[:record_by].join(', ')
        block << [title, record_by]
      end
      block.sort_by {|t, r| "#{t.downcase}:#{r}"}.each do |title, record_by|
        puts "%-50.50s %s" % [title, record_by]
      end
      self
    end

    def each(options={})
      filter = options[:filter] || {}
      if filter.is_a?(String)
        if filter.include?('=@')
          fname, ffile = filter.split('=@')
          filter[fname] = File.read(ffile).split("\n")
        else
          filter  = Hash[(filter || '').split(',').map{|f| f.split('=')}]
        end
      end
      econtent = []
      @content.each do |k, v|
        if filter.size > 0
          pass = true
          filter.each do |fk, fv|
            if fv.is_a?(Array)
              unless fv.include?(v[fk.to_sym].to_s)
                pass = false
                break
              end
            else
              unless v[fk.to_sym].to_s =~ /#{fv}/i
                pass = false
                break
              end
            end
          end
          next unless pass
        end
        econtent << [k, v]
      end
      if options[:pbar]
        bar = ProgressBar.create(title:options[:pbar], total:econtent.size,
                                format:'%t %B %c/%C')
      end
      econtent.each do |k, v|
        yield k, v
        bar.increment if options[:pbar]
      end
      true
    end
  end

  class SmuleSong
    def initialize(sinfo, options={})
      @info    = sinfo
      @options = options
      @surl    = "https://smule.com#{@info[:href]}"
    end

    def [](key)
      @info[key]
    end

    def [](key, value)
      @info[key] = value
    end
    
    def download_audio(ofile)
      olink    = @surl.sub(/\/ensembles$/, '')
      Plog.info("Getting audio from #{olink}")
      source   = HTTP.follow.get(olink).to_s 
      Plog.info("Got audio from #{olink}")
      document = Nokogiri::HTML(source)
      if stream = document.at('meta[name="twitter:player:stream"]')
        mp4_url = stream['content']
        audio   = HTTP.follow.get(mp4_url)
        File.open(ofile, 'wb') do |f|
          f.write(audio.body)
        end
      else
        Plog.error("Link no longer contain song - #{link}")
        return false
      end

      # Get the recording JSON object
      asset         = document.css('head script')[0].text.split("\n").
        grep(/Recording:/)[0].sub(/^\s*Recording: /, '')[0..-2]
      recording     = JSON.parse(asset)
      song_info_url = 'https://www.smule.com' +
        recording.dig('performance', 'song_info_url')

      # Get the lyric
      sdoc      = Nokogiri::HTML(HTTP.get(song_info_url).to_s)
      asset     = sdoc.css('head script')[0].text.split("\n").grep(/Song:/)[0].
                    sub(/^\s*Song: /, '')[0..-2]
      song_info = JSON.parse(asset)
      lyric     = song_info['lyrics'].gsub(/<br>/, "\n").gsub(/<p>/, "\n\n")
      lyric     = CGI.unescapeHTML(lyric)
    end

    def download
      #begin
        if @options[:force] || !test(?f, @info[:sfile])
          audio_handler = AudioHandler.new(@surl)
          audio_handler.get_audio(@info[:sfile])
          @lyric = audio_handler.get_lyric
          update_mp4tag
        end
        unless test(?l, @info[:ofile])
          unless test(?d, File.dirname(@info[:ofile]))
            FileUtils.mkdir_p(File.dirname(@info[:ofile]), verbose:true)
          end
          FileUtils.symlink(@info[:sfile], @info[:ofile],
                            verbose:true, force:true)
        end
      #rescue => errmsg
        #Plog.dump_error(errmsg:errmsg)
      #end
    end

    def update_mp4tag
      ofile = @info[:sfile]
      cdate = @info[:created] || Time.now
      if ofile && test(?f, ofile)
        href    = 'https://www.smule.com' + @info[:href]
        date    = cdate.strftime("%Y-%m-%d")
        album   = cdate.strftime("Smule-%Y.%m")
        artist  = @info[:record_by].join(', ')
        comment = "#{date} - #{href}"
        year    = cdate.year
        title   = clean_emoji(@info[:title]).gsub(/\'/, "")

        command = "atomicparsley #{@info[:sfile]} --overWrite"

        # Get the artwork
        lcfile  = File.basename(@info[:avatar])
        system("set -x; curl -s -o #{lcfile} #{@info[:avatar]}")
        command += " --artwork #{lcfile}"
        command += " --title '#{title}'"
        command += " --artist '#{artist}'"
        command += " --album '#{album}'"
        command += " --year '#{year}'"
        command += " --comment '#{comment}'"

        if @lyric
          tmpf = Tempfile.new("lyric")
          tmpf.puts(@lyric)
          tmpf.close
          command += " --lyricsFile #{tmpf.path}"
        end

        system("set -x; #{command}; rm -f #{lcfile}")
        true
      else
        false
      end
    end

  end

  class SmuleScanner
    def initialize(user, options={})
      @user      = user
      @options   = options
      @connector = SiteConnect.new(:smule, @options)
      @spage     = SelPage.new(@connector.driver)
      at_exit {
        @connector.close
      }
    end

    def scan_collab_list(collab_links)
      result    = []
      s_singers = (@options[:singers] || "").split(',').sort
      bar       = ProgressBar.create(title:"Checking collabs",
                                   total:collab_links.size)
      collab_links.each do |alink|
        @spage.goto(alink)
        sitems = @spage.page.css(".duets.content .recording-listItem")
        sitems.each do |sitem|
          next unless sinfo = _scan_a_collab_song(sitem)
          if s_singers.size > 0
            record_by = sinfo[:record_by]
            if (s_singers & record_by) != record_by
              Plog.dump_info(msg:'Skip download for singers',
                             s_singers:s_singers, record_by:record_by)
              next
            end
          end
          sinfo.update(parent:alink)
          result << sinfo
        end
        bar.increment
      end
      Plog.info("Found #{result.size} songs in collabs")
      result
    end

    def scan_favs
      @spage.goto(@user)
      @spage.click_and_wait('._bovhcl:nth-child(3)')
      _scan_songs
    end

    def play_set(cselect, pduration=1.0)
      pduration = pduration.to_f
      if pduration > 1.0
        pduration = 1.0
      end
      sort_by, order = (@options[:order] || "listens:a").split(':')
      order = 'a' unless order

      cselect = cselect.sort_by {|r| r[sort_by.to_sym]}
      if order == 'd'
        cselect = cselect.reverse
      end
      size    = (@options[:size] || 100).to_i
      cselect = cselect[0..size-1]
      Plog.info("Playing #{cselect.size} songs")
      cselect.each do |sitem|
        @spage.goto(sitem[:href])
        duration_s = @spage.page.css("._vln25l")[0]
        if duration_s
          duration = @spage.page.css("._vln25l")[0].text.split(':')
          secs     = duration[0].to_i * 60 + duration[1].to_i
          psecs    = secs * pduration
        else
          psecs    = 210 * pduration
        end
        Plog.dump_info(title:sitem[:title], record:sitem[:record_by],
                       listens:sitem[:listens], psecs:psecs)
        sitem[:listens] += 1
        sleep psecs
      end
    end
    
    def scan_followers
      @spage.goto(@user)
      @spage.click_and_wait('._bovhcl:nth-child(4)')
      _scan_users
    end

    def scan_followings
      @spage.goto(@user)
      @spage.click_and_wait('._bovhcl:nth-child(5)')
      _scan_users
    end

    def scan_songs
      @spage.goto(@user)
      _scan_songs
    end

    def scan_songs_and_favs
      {
        songs: scan_songs,
        favs:  scan_favs,
      }
    end

    def _scroll_to_bottom
      pages  = (@options[:pages] || 20).to_i
      bar    = ProgressBar.create(title:"Scroll to end", total:pages)
      @spage.execute_script("window.scrollTo(0,2500)")
      sleep 1
      (1..pages).each_with_index do |apage, index|
        @spage.execute_script("window.scrollTo(0,1000000)")
        sleep 0.5
        bar.increment
      end
      @spage.refresh
    end

    def _scan_users
      _scroll_to_bottom
      result = []
      sitems = @spage.page.css("._1mcyx7uu")
      sitems.each do |sitem|
        name   = sitem.css("._409m7v").text.strip
        avatar = sitem.css("._1eeaa3cb")[0]['style']
        avatar = avatar.sub(/^.*url\("/, '').sub(/".*$/, '')
        if name.empty? || avatar.empty?
          raise ("No name or avatar detected for #{sitem.inspect}")
        end
        result << {
          name:   name,
          avatar: avatar,
        }
      end
      result
    end

    def _each_main_song
      _scroll_to_bottom
      sitems       = @spage.page.css("._8u57ot")
      result       = []
      collab_links = []
      bar          = ProgressBar.create(title:"Checking songs",
                                        total:sitems.size)
      sitems.each do |sitem|
        plink = sitem.css('a._1sgodipg')[0]
        next unless plink
        next if sitem.css('._1wii2p1').size <= 0
        yield sitem
        bar.increment
      end
    end

    def _scan_songs
      result       = []
      collab_links = []
      _each_main_song do |sitem|
        sentry = _scan_a_main_song(sitem)
        next unless sentry
        result << sentry
        if @options[:mysongs] && (collab_url = sentry[:collab_url])
          if (sentry[:since] =~ /(hr|d)$/)
            collab_links << collab_url
          end
        end
      end

      if collab_links.size > 0
        result += scan_collab_list(collab_links)
      end
      Plog.info("Found #{result.size} songs")
      result
    end

    def _scan_a_main_song(sitem)
      plink = sitem.css('a._1sgodipg')[0]
      if !plink || (sitem.css('._1wii2p1').size <= 0)
        return nil
      end
      since       = sitem.css('._1wii2p1')[2].text
      record_by   = nil
      collab_url  = nil
      is_ensemble = false
      if collabs = sitem.css('a._api99xt')[0]
        href = collabs['href']
        if href =~ /ensembles$/
          collab_url  = href
          is_ensemble = true
          record_by   = [@user]
        end
      end
      unless record_by
        s1 = sitem.css('._1bho7ie')[0]
        s1 = s1 ? s1.text.strip : nil
        s2 = sitem.css('._1t74rwnk')[0]
        s2 = s2 ? s2.text.strip : nil
        record_by ||= [s1, s2].compact
      end
      play_div = sitem.css('._1xmmk8d1')[0]
      phref    = plink['href'].split('/')
      sid      = phref[-1] == 'ensembles' ? phref[-2] : phref[-1]
      created  = Time.now - time_since(since)
      title    = clean_emoji(plink.text).strip
      {
        title:       title,
        href:        plink['href'],
        record_by:   record_by,
        listens:     sitem.css('._1wii2p1')[0].text.to_i,
        loves:       sitem.css('._1wii2p1')[1].text.to_i,
        since:       since,
        avatar:      (sitem.css('img')[0] || {})['src'],
        is_ensemble: is_ensemble,
        collab_url:  collab_url,
        sid:         sid,
        created:     created,
      }
    end

    def _scan_a_collab_song(sitem)
      unless plink = sitem.css('a.playable')[0]
        return nil
      end
      record_by = sitem.css('.recording-by a').map{|rb| rb['title']}
      phref     = plink['href'].split('/')
      sid       = phref[-1] == 'ensembles' ? phref[-2] : phref[-1]
      since     = sitem.css('.stat-timeago').first.text.strip
      created   = Time.now - time_since(since)
      title    = clean_emoji(plink['title']).strip
      {
        title:       title,
        href:        plink['href'],
        record_by:   record_by,
        listens:     sitem.css('.stat-listens').first.text.to_i,
        loves:       sitem.css('.stat-loves').first.text.to_i,
        since:       sitem.css('.stat-timeago').first.text.strip,
        avatar:      plink['data-src'],
        is_ensemble: false,
        sid:         sid,
        created:     created,
      }
    end
  end

  class << self
    def _ofile(afile, tdir)
      odir  = tdir + "/#{afile[:record_by].sort.join('-')}"
      title = afile[:title].strip.gsub(/[\/\"]/, '-')
      ofile = File.join(odir,
                        title.gsub(/\&/, '-').gsub(/\'/, '-') + '.m4a')

      sfile = File.join(tdir, "STORE", afile[:sid] + '.m4a')
      [ofile, sfile]
    end

    def _prepare_download(flist, tdir)
      options = getOption
      bar     = ProgressBar.create(title:"Preparing list", total:flist.size)
      flist   = flist.select do |afile|
        afile[:ofile], afile[:sfile] = _ofile(afile, tdir)
        odir          = File.dirname(afile[:ofile])
        FileUtils.mkdir_p(odir, verbose:true) unless test(?d, odir)
        begin
          if test(?f, afile[:ofile]) && !test(?l, afile[:ofile])
            FileUtils.move(afile[:ofile], afile[:sfile],
                           verbose:true, force:true)
            FileUtils.symlink(afile[:sfile], afile[:ofile],
                              verbose: true, force:true)
          end
        rescue ArgumentError => errmsg
          Plog.dump_error(errmsg:errmsg, sfile:afile[:sfile],
                          ofile:afile[:ofile])
        end
        bar.increment
        res = test(?f, afile[:sfile]) && test(?l, afile[:ofile])
        !res
      end
      if options[:limit]
        limit = options[:limit].to_i
        flist = flist[0..limit-1]
      end
      if flist.size <= 0
        Plog.info "No new files to download"
        return nil
      end
      flist
    end

    def _download_list(flist, tdir)
      unless flist = _prepare_download(flist, tdir)
        return
      end
      bar = ProgressBar.create(title:"Downloading songs", total:flist.size)
      flist.each do |afile|
        SmuleSong.new(afile).download
        bar.increment
      end
    end

    def _connect_site(site=:smule)
      if @sconnector
        do_close = false
      else
        @sconnector = SiteConnect.new(site, getOption)
        do_close    = true
      end
      yield SelPage.new(@sconnector.driver)
      if do_close
        @sconnector.close
        @sconnector = nil
      end
    end

    def download_for_user(user, tdir='.')
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end

      result  = scan_songs_and_favs(user, tdir)
      _download_list(result[:songs], tdir)

      content = Content.new(user, tdir)
      content.add_new_songs(result[:songs], false)
      content.add_new_songs(result[:favs],  true)
      content.writeback
      true
    end

    def scan_songs_and_favs(user, tdir=nil)
      SmuleScanner.new(user, getOption).scan_songs_and_favs
    end

    def scan_favs(user, tdir=nil)
      result = SmuleScanner.new(user, getOption).scan_favs
      Content.new(user, tdir).add_new_songs(result, true).writeback if tdir
      result.to_yaml
    end

    def scan_follows(user, tdir=nil)
      scanner    = SmuleScanner.new(user, getOption)
      followings = scanner.scan_followings
      followers  = scanner.scan_followers
      if tdir
        Content.new(user, tdir).set_follows(followings, followers).writeback
      end
      {
        followings: followings,
        followers:  followers,
      }.to_yaml
    end

    def show_content(user, tdir='.')
      Content.new(user, tdir).list
      true
    end

    def play_favs(user, tdir='.', pduration="1.0")
      options = getOption
      cselect = []
      content = Content.new(user, tdir)
      at_exit { content.writeback }
      options[:pbar] = "Collect favs"
      content.each(options) do |k, v|
        cselect << v if v[:isfav]
      end
      SmuleScanner.new(user, getOption).play_set(cselect, pduration)
    end

    def play_recents(user, tdir='.', pduration="1.0")
      options = getOption
      cselect = []
      content = Content.new(user, tdir)
      at_exit { content.writeback }
      options[:pbar] = "Collect recents"
      content.each(options) do |k, v|
        cselect << v if (v[:sincev] < 24*7)
      end
      SmuleScanner.new(user, getOption).play_set(cselect, pduration)
    end

    def play_singer(user, singer, tdir='.', pduration="1.0")
      options = getOption
      cselect = []
      content = Content.new(user, tdir)
      options[:pbar] = "Collect records by #{singer}"
      content.each(options) do |k, v|
        cselect << v if (v[:record_by].grep(/#{singer}/i).size > 0)
      end
      Plog.info("Select #{cselect.size} songs")
      if cselect.size > 0
        at_exit { content.writeback; exit 0 }
        SmuleScanner.new(user, getOption).play_set(cselect, pduration)
      end
    end

    def add_mp3_comment(user, tdir='.')
      options        = getOption
      content        = Content.new(user, tdir)
      changed        = false
      options[:pbar] = "Add missing mp4 tags"
      content.each(options) do |k, v|
        unless @options[:force]
          if v[:ofile] && test(?l, v[:ofile]) &&
             v[:sfile] && test(?f, v[:sfile])
            next
          end
        end
        v[:ofile], v[:sfile] = _ofile(v, tdir)
        if !test(?f, v[:sfile]) || (File.size(v[:sfile]) < 1_000_000) ||
            !test(?l, v[:ofile])
          SmuleSong.new(v, force:true).download
        else
          SmuleSong.new(v, force:true).update_mp4tag
        end

        # Remove content, if I could not get the source.  Could be
        # removed from smule already
        unless test(?f, v[:sfile])
          Plog.info("Removing #{v[:sfile]}")
          content.content.delete(k)
        end

        Plog.dump_info(v:v)
        changed = true
      end
      if changed
        content.writeback
      end
      true
    end

    # Singer changes login all the times.  That would change control
    # data as well as storage folder.  This needs to run to track user
    def move_singer(user, old_name, new_name, tdir='.')
      changed = false
      content = Content.new(user, tdir)
      options = getOption
      options.update(
        pbar:   "Move content from #{old_name}",
        filter: "record_by=#{old_name}",
      )
      content.each(options) do |k, v|
        if pos = v[:record_by].index(old_name)
          v[:record_by][pos] = new_name
          v[:ofile], v[:sfile] = _ofile(v, tdir)
          SmuleSong.new(v).download
          changed = true
        end
      end
      if changed
        content.writeback
      end
    end
  end
end

if (__FILE__ == $0)
  SmuleAuto.handleCli(
    ['--auth',    '-a', 1],
    ['--browser', '-b', 1],
    ['--filter',  '-f', 1],
    ['--limit',   '-l', 1],
    ['--mysongs', '-m', 0],
    ['--order',   '-o', 1],
    ['--pages',   '-p', 1],
    ['--quick',   '-q', 0],
    ['--singers', '-s', 1],
    ['--size',    '-S', 1],
    ['--verbose', '-v', 0],
  )
end

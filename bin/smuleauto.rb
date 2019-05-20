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
require 'core'
require 'site_connect'

module SmuleAuto
  extendCli __FILE__

  class Content
    attr_reader :content

    def initialize(user, cdir='.')
      @user  = user
      @cdir  = cdir
      @cfile = "#{cdir}/content-#{user}.yml"
      @ffile = "#{cdir}/follows-#{user}.yml"
      if test(?f, @cfile)
        @content = YAML.load_file(@cfile)
      else
        @content = {}
      end
      # Tempo to purge bad data
      if true
        plist = []
        @content.each do |k, v|
          if v[:sid] && (k != v[:sid])
            plist << k
          end
        end
        plist.each do |pk|
          Plog.info("Purging #{pk}")
          v = @content[pk]
          @content.delete(pk)
          @content[v[:sid]] = v
        end
      end
      if test(?f, @ffile)
        content     = YAML.load_file(@ffile)
        @followers  = content[:followers]
        @followings = content[:followings]
      else
        @followers  = {}
        @followings = {}
      end
    end

    def _write_with_backup(mfile, content)
      bakfile = File.join(ENV['HOME'], File.basename(mfile))
      [mfile, bakfile].each do |afile|
        File.open(afile, 'w') do |fod|
          Plog.info("Writing #{content.size} entries to #{afile}")
          fod.puts content.to_yaml
        end
      end
    end

    def writeback
      _write_with_backup(@cfile, @content)
      _write_with_backup(@ffile,
                         followers: @followers, followings: @followings)
      self
    end

    def set_follows(followings, followers)
      @followings, @followers = {}, {}
      followings.each do |e|
        @followings[e[:name]] = e
      end
      followers.each do |e|
        @followers[e[:name]] = e
      end
      self
    end

    def add_new_songs(block, isfav=false)
      now = Time.now
      block.each do |r|
        r[:updated_at] = now
        fs             = r[:href].split('/')
        r[:sid]        = (fs[-1] == 'ensembles') ? fs[-2] : fs[-1]
        r[:isfav]      = isfav if isfav
        @content.delete(r[:href])
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
      result = []
      s_singers = (@options[:singers] || "").split(',').sort
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
      end
      Plog.info("Found #{result.size} songs in collabs")
      result
    end

    def scan_favs
      @spage.goto(@user)
      @spage.click_and_wait('._bovhcl:nth-child(3)')
      _scan_songs
    end

    def play_favs(pduration=1.0)
      pduration = pduration.to_f
      if pduration > 1.0
        pduration = 1.0
      end
      @spage.goto(@user)
      @spage.click_and_wait('._bovhcl:nth-child(3)')
      index    = 0
      playlist = []
      _each_main_song do |sitem|
        playlist << _scan_a_main_song(sitem)
      end
      playlist.each_with_index do |pentry, index|
        pentry[:play_path] = (playlist[index+1] || {})[:play_path]
      end

      playlist = playlist.sort_by {|r| r[:listens]}
      playlist.each do |pentry|
        next unless pentry[:play_path]
        element = @spage.find_element(:css, pentry[:play_path])
        @spage.execute_script("arguments[0].scrollIntoView()", element)
        sleep 1
        @spage.execute_script("window.scrollBy(0, -200)")
        @spage.click_and_wait(pentry[:play_path])
        @spage.refresh
        duration = @spage.page.css("._vln25l")[0].text.split(':')
        secs     = duration[0].to_i * 60 + duration[1].to_i
        psecs = secs * pduration

        Plog.dump_info(title:pentry[:title], record:pentry[:record_by],
                       listens:pentry[:listens], psecs:psecs)
        sleep psecs
      end
    end

    def play_recents(pduration=1.0)
      pduration = pduration.to_f
      if pduration > 1.0
        pduration = 1.0
      end
      @spage.goto(@user)
      playlist = []
      _each_main_song do |sitem|
        sentry             = _scan_a_main_song(sitem)
        play_div           = sitem.css('._1xmmk8d1')[0]
        sentry[:play_path] = play_div.css_path
        unless sentry[:collab_url]
          playlist << sentry
        end
      end
      playlist.each_with_index do |pentry, index|
        pentry[:play_path] = (playlist[index+1] || {})[:play_path]
      end
      playlist = playlist.sort_by {|r| r[:listens]}
      psize    = (@options[:size] || playlist.size).to_i
      playlist[0..psize-1].each do |pentry|
        next unless pentry[:play_path]
        element = @spage.find_element(:css, pentry[:play_path])
        @spage.execute_script("arguments[0].scrollIntoView()", element)
        sleep 1
        @spage.execute_script("window.scrollBy(0, -200)")
        @spage.click_and_wait(pentry[:play_path])
        @spage.refresh
        duration = @spage.page.css("._vln25l")[0].text.split(':')
        secs     = duration[0].to_i * 60 + duration[1].to_i
        psecs = secs * pduration

        Plog.dump_info(title:pentry[:title], record:pentry[:record_by],
                       listens:pentry[:listens], psecs:psecs)
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
      Plog.info "Scroll to end of page"
      (1..pages).each_with_index do |apage, index|
        @spage.execute_script("window.scrollTo(0,1000000)")
        sleep 0.5
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
      sitems.each do |sitem|
        plink = sitem.css('a._1sgodipg')[0]
        next unless plink
        next if sitem.css('._1wii2p1').size <= 0
        yield sitem
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
      play_div  = sitem.css('._1xmmk8d1')[0]
      {
        title:       plink.text.strip,
        href:        plink['href'],
        record_by:   record_by,
        listens:     sitem.css('._1wii2p1')[0].text.to_i,
        loves:       sitem.css('._1wii2p1')[1].text.to_i,
        since:       since,
        avatar:      (sitem.css('img')[0] || {})['src'],
        is_ensemble: is_ensemble,
        collab_url:  collab_url,
        play_path:   play_div.css_path,
      }
    end

    def _scan_a_collab_song(sitem)
      unless plink = sitem.css('a.playable')[0]
        return nil
      end
      record_by = sitem.css('.recording-by a').map{|rb| rb['title']}
      {
        title:       plink['title'].strip,
        href:        plink['href'],
        record_by:   record_by,
        listens:     sitem.css('.stat-listens').first.text.to_i,
        loves:       sitem.css('.stat-loves').first.text.to_i,
        since:       sitem.css('.stat-timeago').first.text.strip,
        avatar:      plink['data-src'],
        is_ensemble: false,
        play_path:   plink.css_path,
      }
    end
  end

  class << self
    def _download_list(flist, tdir)
      options = getOption
      flist   = flist.select do |afile|
        odir  = tdir + "/#{afile[:record_by].sort.join('-')}"
        FileUtils.mkdir_p(odir, verbose:true) unless test(?d, odir)
        title = afile[:title].strip.gsub(/\//, '-')
        afile[:ofile] = File.join(odir, title.gsub(/\&/, '-') + '.m4a')
        !test(?s, afile[:ofile])
      end
      if options[:limit]
        limit = options[:limit].to_i
        flist = flist[0..limit-1]
      end
      if flist.size <= 0
        Plog.info "No new files to download"
        return
      end
      Plog.info "Downloading #{flist.size} songs"
      _connect_site(:smule_download) do |spage|
        flist.each do |afile|
          Plog.dump_info(afile:afile)
          surl   = "https://smule.com#{afile[:href]}"
          spage.goto('smule-downloader')
          spage.find_element(id:'url').clear
          spage.type('#url', surl)
          spage.click_and_wait('form input.ipsButton')
          spage.execute_script("window.scrollTo(0,1000)")
          spage.click_and_wait('a[download]')
          media_url = spage.current_url

          # Route to null in case quote causing -o to not take effect
          command   = "curl -o \"#{afile[:ofile]}\" \"#{media_url}\" >/dev/null"
          Plog.info("+ #{command}")
          system command
        end
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
      options = getOption
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
      result = scan_songs_and_favs(user, tdir)
      _download_list(result[:songs], tdir)
    end

    def download_from_file(sfile, tdir='.')
      _download_list(YAML.load_file(sfile), tdir)
    end

    def scan_songs_and_favs(user, tdir=nil)
      result = SmuleScanner.new(user, getOption).scan_songs_and_favs
      if tdir
        content = Content.new(user, tdir)
        content.add_new_songs(result[:songs], false)
        content.add_new_songs(result[:favs],  true)
        content.writeback
      end
      result
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

    def play_favs(user, pduration="1.0")
      SmuleScanner.new(user, getOption).play_favs(pduration)
    end

    def play_recents(user, pduration="1.0")
      SmuleScanner.new(user, getOption).play_recents(pduration)
    end

  end
end

if (__FILE__ == $0)
  SmuleAuto.handleCli(
    ['--auth',    '-a', 1],
    ['--browser', '-b', 1],
    ['--limit',   '-l', 1],
    ['--mysongs', '-m', 0],
    ['--pages',   '-p', 1],
    ['--quick',   '-q', 0],
    ['--singers', '-s', 1],
    ['--size',    '-S', 1],
  )
end

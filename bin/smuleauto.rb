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

      @content.each do |k, r|
        r[:sincev] = time_since(r[:since]) / 3600.0
      end

      if test(?f, @ffile)
        content     = YAML.load_file(@ffile)
        @followers  = content[:followers]
        @followings = content[:followings]
        @fothers    = content[:fothers]
      else
        @followers  = {}
        @followings = {}
        @fothers    = {}
      end
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
      _write_with_backup(@ffile,
                         followers: @followers, followings: @followings,
                         fothers: @fothers)
      self
    end

    def set_follows(followings, followers)
      # Save and reset the following/follower set at each call
      @fothers.update(@followers)
      @fothers.update(@followings)
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
        r[:isfav]      = isfav if isfav
        #@content.delete(r[:href])
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

    def each(filter={})
      if !filter || filter.is_a?(String)
        filter  = Hash[(filter || '').split(',').map{|f| f.split('=')}]
      end
      @content.each do |k, v|
        if filter.size > 0
          pass = true
          filter.each do |fk, fv|
            unless v[fk.to_sym].to_s =~ /#{fv}/i
              pass = false
              break
            end
          end
          next unless pass
        end
        yield k, v
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
      Plog.info "Scroll to end of page"
      @spage.execute_script("window.scrollTo(0,2500)")
      sleep 1
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
      play_div = sitem.css('._1xmmk8d1')[0]
      phref    = plink['href'].split('/')
      sid      = phref[-1] == 'ensembles' ? phref[-2] : phref[-1]
      created  = Time.now - time_since(since)
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
      {
        title:       plink['title'].strip,
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
      ofile = File.join(odir, title.gsub(/\&/, '-') + '.m4a')
      sfile = File.join(tdir, "STORE", afile[:sid] + '.m4a')
      [ofile, sfile]
    end

    def _download_list(flist, tdir)
      options = getOption
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
        !test(?f, afile[:sfile])
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
          command   = "curl -o \"#{afile[:sfile]}\" \"#{media_url}\" >/dev/null"
          Plog.info("+ #{command}")
          system command
          FileUtils.symlink(afile[:sfile], afile[:ofile],
                            verbose:true, force:true)
          _update_mp4tag(afile)
        end
      end
    end

    def _update_mp4tag(afile)
      require 'taglib'

      ofile = afile[:sfile]
      if ofile && test(?f, ofile)
        date = Time.now.strftime("%Y-%m-%d")
        mp4  = TagLib::MP4::File.new(afile[:sfile])
        if mp4.tag
          mp4.tag.title   = afile[:title]
          mp4.tag.artist  = afile[:record_by].join(', ')
          mp4.tag.album   = Time.now.strftime("Smule-%Y.%m")
          mp4.tag.comment = "Download from smule on #{date} - #{afile[:sid]}"
          mp4.tag.year    = Time.now.year
          mp4.save
        else
          Plog.dump_error(msg:"No MP4 tag found", afile:afile)
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
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end

      result  = scan_songs_and_favs(user, tdir)
      _download_list(result[:songs], tdir)

      content = Content.new(user, tdir)
      content.add_new_songs(result[:songs], false)
      content.add_new_songs(result[:favs],  true)
      content.writeback
    end

    def download_from_file(sfile, tdir='.')
      _download_list(YAML.load_file(sfile), tdir)
      content = Content.new(user, tdir)
      content.add_new_songs(result[:songs], false)
      content.add_new_songs(result[:favs],  true)
      content.writeback
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
      content.each(options[:filter]) do |k, v|
        cselect << v if v[:isfav]
      end
      SmuleScanner.new(user, getOption).play_set(cselect, pduration)
    end

    def play_recents(user, tdir='.', pduration="1.0")
      options = getOption
      cselect = []
      content = Content.new(user, tdir)
      at_exit { content.writeback }
      content.each(options[:filter]) do |k, v|
        cselect << v if (v[:sincev] < 24*7)
      end
      SmuleScanner.new(user, getOption).play_set(cselect, pduration)
    end

    def play_singer(user, singer, tdir='.', pduration="1.0")
      options = getOption
      cselect = []
      content = Content.new(user, tdir)
      content.each(options[:filter]) do |k, v|
        cselect << v if (v[:record_by].grep(/#{singer}/i).size > 0)
      end
      Plog.info("Select #{cselect.size} songs")
      if cselect.size > 0
        at_exit { content.writeback; exit 0 }
        SmuleScanner.new(user, getOption).play_set(cselect, pduration)
      end
    end

    def relink_files(user, tdir='.')
      options = getOption
      content = Content.new(user, tdir)
      content.each(options[:filter]) do |k, v|
        ofile, sfile = _ofile(v, tdir)
        Plog.dump_info(ofile:ofile, sfile:sfile)
        unless test(?f, ofile)
          Plog.warn(msg:"File not found", title:v[:title], ofile:ofile)
          FileUtils.symlink(sfile, ofile, verbose:true, force:true)
        end
      end
    end

    def set_ofile(user, tdir='.')
      options = getOption
      content = Content.new(user, tdir)
      changed = false
      dllist  = []
      content.each(options[:filter]) do |k, v|
        ofile, sfile = _ofile(v, tdir)
        unless v[:ofile]
          v[:ofile] = ofile
          changed = true
        end
        unless v[:sfile]
          v[:sfile] = sfile
          changed = true
        end
        if sfile && !test(?f, sfile)
          dllist << v
          Plog.dump_info(dsize:dlist.size, sfile:sfile)
        end
        if changed 
          Plog.dump_info(dsize:dlist.size, ofile:ofile, sfile:sfile)
        end
      end
      if changed 
        Plog.dump_info(changed:changed)
        content.writeback
      end
      if dllist.size > 0
        _download_list(dllist, tdir)
      end
    end

    def set_mp4info(user, tdir='.')
      require 'taglib'

      options = getOption
      content = Content.new(user, tdir)
      content.each(options[:filter]) do |k, v|
        ofile   = v[:sfile]
        album   = Time.now.strftime("Smule-%Y.%m")
        comment = Time.now.strftime("Download from smule on %Y-%m-%d")
        if ofile && test(?f, ofile)
          mp4 = TagLib::MP4::File.new(ofile)
          next if (!mp4.tag || mp4.tag.title != 'ver:1')
          title           = clean_emoji(v[:title])
          mp4.tag.title   = title
          mp4.tag.artist  = v[:record_by].join(', ')
          mp4.tag.album   = album
          mp4.tag.comment = comment
          mp4.save
          Plog.dump_info(title:mp4.tag.title, sid:v[:sid])
          Plog.info("Updated #{ofile}")
        end
      end
      true
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
  )
end

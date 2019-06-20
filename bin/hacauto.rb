#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hacauto.rb
#---------------------------------------------------------------------------
#++
require File.dirname(__FILE__) + "/../etc/toolenv"
require 'selenium-webdriver'
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'byebug'
require 'progress_bar'
require 'core'
require 'site_connect'
require_relative 'hac-base'
require_relative 'hac-nhac'

class SPage < SelPage
  #attr_reader :sdriver, :page, :auser, :clicks
  attr_reader :auser

  def initialize(sdriver)
    super(sdriver)
    @auser   = sdriver.auser
    @clog    = ClickLog.new(@auser)
  end

  def find_and_click_song_links(lselector, rselector, options={})
    if exclude_user = options[:exclude_user]
      exclude_user = exclude_user.split(',')
    end
    pcount = options[:pcount].to_i
    links  = []
    song_items = @page.css("#{lselector} .song-item")
    song_items.each do |item|
      if exclude_user
        poster = File.basename(item.css('a.song-poster')[0]['href'])
        if exclude_user.include?(poster)
          Plog.info "Skipping with exclude user: #{poster}"
          next
        end
      end
      if pcount > 0
        rcount = item.css('.song-comment')[0].text.strip.gsub(/,/, '')
        if rcount =~ /k$/
          rcount = rcount.to_i * 1000
        else
          rcount = rcount.to_i
        end
        next if (rcount < pcount)
      end
      links << item.css('a.song-title')[0]['href']
    end
    click_links(links, rselector, options)
    song_items
  end

  def click_links(links, rselector, options={})
    limit = (options[:limit] || 1000).to_i
    links = links.select {|r| !@clog.was_clicked?(@auser, r, rselector)}
    if links.size <= 0
      return
    end
    Plog.info("Click #{links.size} links")
    links.each do |link|
      goto(link)
      @sdriver.click_and_wait(rselector, 3)
      @clicks += 1
      @clog.log_click(@auser, link, rselector)
      break if @clicks >= limit
    end
  end
end

# Connection functions
class SiteConnect
  def self.connect_hac(options)
    Plog.info "Connect to HAC"
    auth    = options[:auth] || 'thienv:kKtx75LUY9GA'
    identity, password = auth.split(':')
    hac_source = HacSource.new(options)
    sdriver    = SDriver.new(hac_source.base_url, user:identity,
                             browser:options[:browser])
    Plog.info("Wait a bit for CDN verification")
    sleep(10)
    sdriver.click_and_wait('#login-link', 5)
    sdriver.type('#identity', identity)
    sdriver.type('#password', password)
    sdriver.click_and_wait('#submit-btn')
    sdriver
  end

  def self.connect_gmusic(options)
    Plog.info "Connect to Google Music"
    auth    = options[:auth]
    identity, password = auth.split(':')
    sdriver = SDriver.new('https://play.google.com/music', user:identity,
                           browser:options[:browser])
    sdriver.click_and_wait('paper-button[data-action="signin"]')
    sdriver.type('#identifierId', identity + "\n")
    sdriver.type('input[name="password"]', password + "\n")

    STDERR.puts "Confirm authentication on cell phone and continue"
    STDIN.gets
    sdriver
  end

  def self.connect_zing(options)
    Plog.info "Connect to Zing"
    sdriver = SDriver.new('https://mp3.zing.vn', browser:options[:browser])
    sdriver
  end

  def self.connect_nhacvn(options)
    Plog.info "Connect to NhacVN"
    sdriver = SDriver.new('https://nhac.vn', browser:options[:browser])
    sdriver
  end
end

class AutoFill
  include HtmlRes

  def initialize(options={})
    @hac_source = HacSource.new(options)
  end

  def missing?(sname)
    query = CGI.escape(sname.sub(/\s*\(.*$/, ''))
    url   = "#{@hac_source.base_url}/search?q=#{query}"
    page  = get_page(url)
    fsize = page.css('.song-item').size
    if fsize > 0
      #Plog.info("Found #{fsize} for #{sname}")
      return false
    end
    return true
  end

  def find_missing_song(slist)
    missing = []
    bar = ProgressBar.new(slist.size)
    slist.each do |sinfo|
      sname = sinfo[:name]
      if missing?(sname)
        missing << sinfo
        Plog.info "Missing #{sname} (#{missing.size})"
      end
      bar.increment!
    end
    missing
  end

  def get_page_lyric(url)
    begin
      MusicSource.mk_source(url).lyric_info(url)
    rescue => errmsg
      Plog.error "Error retrieving #{url} - #{errmsg}"
      nil
    end
  end

  HelpText = <<EOH
b       - Debug program
h       - Show this info
p       - Redo previous
r       - Reload script
s       - Skip next
t       - Text mode
w       - Write current list
x       - Exit program
EOH

  def get_command_from_user
    while true
      STDERR.print "Command [b|h|p|r|s|t|w|x]? "
      STDERR.flush
      ans = STDIN.gets.strip
      case ans
      when /^b/io
        require 'byebug'
        byebug
      when /^(h|\?)/io
        STDERR.puts HelpText
      when /^p/io
        return :previous
      when /^r/io
        $0 = 'Running'
        file = __FILE__
        begin
          eval "load '#{file}'", TOPLEVEL_BINDING
        rescue => errmsg
          Plog.error errmsg
        end
      when /^s/io
        return :skip
      when /^w/io
        return :write
      when /^x/io
        return nil
      when /^t/io
        return :text_mode
      else
        return ans
      end
    end
  end

  SongSite = [
    'http://amnhac.fm',
    'http://amusic.vn',
    'http://chacha.vn',
    'http://chiasenhac.vn',
    'http://conmatviet.com',
    'http://hatvoinhau.xyz',
    'http://keeng.vn',
    'http://lyric.tkaraoke.com',
    'http://m1.chiasenhac.vn',
    'http://m2.chiasenhac.vn',
    'http://mp3eg.com',
    'http://nhac.hay365.com',
    'http://nhachay.mobi',
    'http://nhacpro.net',
    'http://nhacvang.org',
    'http://www.chacha.vn',
    'http://www.nhaccuatui.com',
    'http://yeunhacvang.org',
    'https://102tube.com',
    'https://khonhac.net',
    'https://nghenhacxua.com',
    'https://nhac.vn',
    'https://nhacvang24.com',
    'https://soundcloud.com',
    'https://tinhcaviet.com',
    'https://vavomusic.com',
    'https://www.nhaccuatui.com',
    'https://www.youtube.com',
  ]
  def google_for_song(query)
    Plog.info "Searching Google for [#{query}]"
    query  = CGI.escape(query)
    page   = get_page("https://www.google.com/search?q=#{query}")
    links  = []
    links0 = []
    page.css('.r a').each do |l|
      href = l['href'].sub(%r{^/url\?q=}, '').sub(/\&.*$/, '')
      href = CGI.unescape(href)
      links0 << href
      SongSite.select do |asite|
        next unless href.start_with?(asite)
        links << href
        break
      end
    end
    Plog.info({links0:links0}.to_yaml)
    links
  end

  def play_song(sinfo, spage=nil)
    # Origin link is music already
    source = sinfo[:source]
    if source =~ /nhaccuatui|zing/
      spage.type('#song-link', source, clear:true)
      system "open '#{source}'"
    else
      work_link = nil
      title     = sinfo[:title].sub(/\(.*$/, '')
      lset      = google_for_song("#{title} #{sinfo[:artist]}")
      if lset.size > 0
        # Default to 1st one.  If not working, we could select next
        slink = lset[0]
        loop do
          work_link = slink
          if spage
            begin
              spage.type('#song-link', work_link, clear:true)
            rescue => errmsg
              Plog.error errmsg
            end
          end
          system "open '#{work_link}'"
          slink = Cli.select(lset, "Select a music link")
          break unless slink
        end
      end
    end
  end

  def create_plist(spage, plname)
    spage.click_and_wait('#song-action-add > i.fa.fa-plus')
    spage.click_and_wait('#playlist-add-label > i.fa.fa-plus')
    spage.type('#playlist-add-name', plname)
    spage.click_and_wait('#playlist-add-btn')
    spage.click_and_wait('#song-action-add > i.fa.fa-plus')
  end

  def add_to_plist(spage, plname, sinfo, options={})
    spage.goto(sinfo[:href])
    begin
      spage.click_and_wait('#song-action-add > i.fa.fa-plus')
      if options[:newlist]
        spage.click_and_wait('#playlist-add-label > i.fa.fa-plus')
        spage.type('#playlist-add-name', plname)
        spage.click_and_wait('#playlist-add-btn')

        # Collect the new list id
        spage.refresh
        new_id = spage.page.css('.playlist-item')[0].css('input')[0]['id']
        options[:new_id] = new_id.sub(/^playlist-/, '')
        options.delete(:newlist)
      end
      if plname =~ /^\d+$/
        spage.click_and_wait("label[for=\"playlist-#{plname}\"]")
      else
        spage.click_and_wait("label[title=\"#{plname}\"]")
      end
    rescue => errmsg
      Plog.error errmsg
    end
  end

  def create_song(spage, sinfo, options={})
    surl = sinfo[:href]
    info = sinfo[:lyrics] ? sinfo : get_page_lyric(surl)
    unless info
      return nil
    end
    Plog.dump_info(pcount:info[:pcount])
    #Plog.dump_info(info:info)
    begin
      spage.click_and_wait('#create-song-link')
      spage.click_and_wait('#auto-caret-btn', 0)
      spage.type('#song-name',    info[:title])
      lnote = info[:lnote] || ""
      if options[:addn_note]
        lnote += "\n#{options[:addn_note]}"
      end
      if !lnote.empty?
        spage.type('#song-lyric', lnote.strip + "\n===\n" + info[:lyric])
      else
        spage.type('#song-lyric', info[:lyric])
      end
      spage.type('#song-authors', info[:author])
      spage.type('#song-genres',  info[:genre])
      spage.type('#singer-names', info[:artist])
      spage.type('#singer-key',   info[:chord])
      spage.type('#song-link',    info[:source])
      Plog.info "Review page to fill in remaining info and submit afterward"
      play_song(info, spage)
    rescue => errmsg
      Plog.error errmsg
    end
    info
  end

  def create_from_site(spage, store, coptions={})
    donelist = []
    loop do
      sinfo = store.peek
      break unless sinfo
      input = nil
      text_mode = false
      loop do
        if sinfo[:name]
          Plog.info "Next to import is #{sinfo[:name]} - [#{store.curptr+1}/#{store.songs.size}]"
        end

        input = get_command_from_user
        return unless input
        if input == :skip
          sinfo = {}
          store.advance
          break
        end

        case input
        when :text_mode
          text_mode = true
          break
        when :previous
          store.advance(-1)
          break
        when :write
          store.save
          next
        end
        break if input != :next
      end

      Plog.dump_info(sinfo:sinfo, text_mode:text_mode)
      if sinfo[:href]
        if text_mode
          puts sinfo.to_yaml
        else
          create_song(spage, sinfo, coptions)
        end
        store.advance
      end
    end
  end
end

class SongStore
  attr_reader :file, :songs, :curptr

  def initialize(files, options={})
    @options = options
    @files   = files
    @curptr  = 0
    @songs   = []
    @files.each do |file|
      if test(?s, file)
        songs = YAML.load_file(file)
        Plog.info "Reading #{songs.size} entries from #{file}"
        @songs += songs
      else
        Plog.info "#{file} not available (or empty)"
      end
    end
    if @options[:pcount]
      @songs = @songs.sort_by{|e| e[:pcount] || 0}.reverse
    elsif @options[:random]
      @songs = @songs.sort_by{rand}
    end
    self
  end

  def save
    if @files.size <= 0
      Plog.info("Skip saving.  No original input files")
      return
    end
    if @curptr < @songs.size
      csize = @songs.size - @curptr
      wfile = @files[0]
      Plog.info "Writing remaining #{csize} entries to #{wfile}"
      File.open(wfile, "w") do |fod|
        fod.puts @songs[@curptr..-1].to_yaml
      end
      rmfiles = @files[1..-1]
    else
      rmfiles = @files
    end
    if rmfiles.size > 0
      Plog.info "Complete list from #{rmfiles}.  Removing"
      rmfiles.each do |afile|
        File.delete(afile)
      end
    end
  end

  # Overwrite everything here
  def write(slist)
    @songs  = slist
    @curptr = 0
    save
  end

  def advance(offset=1)
    @curptr += offset
  end

  def peek
    if @files.size <= 0
      STDERR.print "URL/File to retrieve song: "
      STDERR.flush
      url = STDIN.gets.strip
      if url.empty? || url =~ /^x/i
        return {}
      end
      if test(?f, url)
        @songs[@curptr] = YAML.load_file(url)
      elsif url =~ /hopamchuan/
        sinfo = {href:url}
        @hac_source ||= HacSource.new(@options)
        sinfo.update(@hac_source.lyric_info(sinfo[:href]) || {})
        @songs[@curptr] = sinfo
      elsif url =~ /^http/i
        if url !~ /hopamviet.vn/
          havinfo = HACAuto.hav_find_matching_song(url)
          @songs[@curptr] = {href: havinfo ? havinfo[:href] : url}
        else
          @songs[@curptr] = {href:url}
        end
        @songs[@curptr][:name] = File.basename(@songs[@curptr][:href])
      else
        Plog.error "Unsupported location: #{url}"
        return {}
      end
    end
    @songs[@curptr]
  end
end

class HACAuto
  extendCli __FILE__

  class << self
    def hav_find_matching_song(url)
      options = getOption
      linfo   = AutoFill.new(options).get_page_lyric(url)
      HavSource.new.find_matching_song(linfo[:title]).first
    end

    def _connect_site(site=:hac)
      if @sdriver
        do_close = false
      else
        case site
        when :gmusic
          @sdriver = SiteConnect.connect_gmusic(getOption)
        when :zing
          @sdriver = SiteConnect.connect_zing(getOption)
        when :nhacvn
          @sdriver = SiteConnect.connect_nhacvn(getOption)
        else
          @sdriver = SiteConnect.connect_hac(getOption)
        end
        do_close = true
      end
      yield SPage.new(@sdriver)
      if do_close
        @sdriver.close
        @sdriver = nil
      end
    end

    def gmusic_plist(plist)
      _connect_site(:gmusic) do |spage|
        path = "listen#/app/#{plist}"
        spage.goto(path)
        spage.page.css('tr.song-row td[data-col="title"]')
      end
    end

    def _each_page(link)
      options = getOption
      if value = options[:page]
        page, incr = value.split(',')
        page = value.to_i
        incr = (incr || 1).to_i
      else
        page = 0
        incr = 1
      end
      limit   = (options[:limit] || 1000).to_i
      _connect_site do |spage|
        loop do
          offset = page * 10
          spage.goto("#{link}?offset=#{offset}")
          links = yield spage
          break if !links || links.size <= 0
          break if spage.clicks >= limit
          page += incr
          break if (page < 0)
        end
      end
    end

    def rate_today
      options = getOption
      _connect_site do |spage|
        spage.find_and_click_links('a.hot-today-item-song',
                          '#contribute-rating-control', options)
      end
    end

    def rate_week
      options = getOption
      _connect_site do |spage|
        spage.find_and_click_song_links('div#weekly-monthly-list',
                          '#contribute-rating-control', options)
      end
    end

    def rate_new(level=3)
      options = _getOptions
      _connect_site do |spage|
        1.upto(5).each do |page|
          spage.goto("/")
          spage.click_and_wait("#recent-list-pagination li:nth-child(#{page})")
          spage.refresh
          spage.find_and_click_song_links('div#recent-list',
                            "#contribute-rating-control li:nth-child(#{level})",
                                    options)
        end
      end
    end

    def rate_path(path, level=3)
      options    = getOption
      hac_source = HacSource.new(options)
      path       = path.sub(/#{hac_source.base_url}/i, '')
      _each_page(path) do |spage|
        spage.find_and_click_song_links('div.song-list',
                          "#contribute-rating-control li:nth-child(#{level})",
                                  options)
      end
    end

    def rate_user(user, level)
      rate_path("profile/posted/#{user}", level)
    end

    def rate_rhymth(rhymth, level=3)
      rate_path("rhymth/v/#{rhymth}", level)
    end

    def rate_genre(genre, level=3)
      rate_path("genre/v/#{genre}", level)
    end

    def rate_artist(artist, level=3)
      rate_path("artist/#{artist}", level)
    end

    def like_user(user)
      options = getOption
      _each_page("/profile/posted/#{user}") do |spage|
        nlinks = []
        sitems = spage.page.css(".song-item")
        sitems.each do |sitem|
          iclasses = sitem.css('.song-like')[0].attr('class').split
          next if iclasses.include?('starred')
          nlinks << sitem.css('.song-title')[0]['href']
        end
        spage.click_links(nlinks, "#song-favorite-star-btn", options)
        sitems
      end
    end

    def approve_versions(user)
      options = getOption
      _each_page("/profile/posted/#{user}") do |spage|
        nlinks = []
        sitems = spage.page.css(".song-item")
        sitems.each do |sitem|
          purl   = sitem.css('a.song-poster')[0]['href']
          poster = purl.split('/')[-1]
          next if poster == user
          url = sitem.css('.song-title')[0]['href']
          _review_version(url, spage)
        end
      end
    end

    def _review_version(url, spage=nil)
      spage.goto(url)

      # Is in the approved list?
      *_tmp, song, user = url.split('/')
      tgroup = 0
      spage.page.css('#version-list tr').each do |tr|
        if p_a = tr.css('a')[0]
          puser = p_a['href'].split('/').last
          if puser == user
            Plog.info "#{song} approved for #{user} already.  Skip"
            return
          end
        else
          break if tgroup >= 1
          tgroup += 1
        end
      end

      Plog.info "Approving #{song} for #{user}."
      cdefault = spage.page.css('#other-versions a')[0]['href']
      spage.click_and_wait("#set-as-default")
      begin
        spage.alert.accept
      rescue Selenium::WebDriver::Error::NoSuchAlertError => errmsg
        Plog.error errmsg
      end

      1.upto(5) do |repeat|
        spage.goto(cdefault)
        spage.click_and_wait("#set-as-default")
        begin
          spage.alert.accept
        rescue Selenium::WebDriver::Error::NoSuchAlertError => errmsg
          Plog.error errmsg
          next
        end
        break
      end
    end

    def create_from_site(*sfiles)
      options          = getOption
      options[:random] = true
      coptions         = options[:with_attribution] ? {addn_note:'Source: hopamviet.vn'} : {}
      store            = SongStore.new(sfiles, options)
      _connect_site do |spage|
        AutoFill.new(options).create_from_site(spage, store, coptions)
        store.save if store
      end
    end

    # Get the song from hav but missing from hac.  Optionally create the songs on hac
    def hav_find_missing(curl)
      options = getOption
      slist   = HavSource.new.scan_song_list(curl, options)
      slist   = AutoFill.new(options).find_missing_song(slist)
      options[:ofile] ||= File.basename(curl).sub(/\..*$/, '') + '.yml'
      slist.each do |sinfo|
        sinfo.update(HavSource.new.lyric_info(sinfo[:href]))
      end
      _output_data(slist, options)
    end

    def hav_load_songs(sfile)
      options = getOption
      slist   = YAML.load_file(sfile)
      bar     = ProgressBar.new(slist.size)
      slist.each do |sinfo|
        unless sinfo[:lyric]
          begin
            sinfo.update(HavSource.new.lyric_info(sinfo[:href]))
          rescue => errmsg
            Plog.error errmsg
          end
        end
        bar.increment!
      end
      options[:ofile] ||= sfile
      _output_data(slist, options)
    end
    
    def hav_new_songs
      xem_nhieu('https://hopamviet.vn/chord/latest')
    end

    def hah_xem_nhieu(list_no=0)
      options = getOption
      options[:list_no] = list_no
      xem_nhieu('https://hopamhay.com')
    end

    def hav_xem_nhieu
      xem_nhieu('https://hopamviet.vn')
    end

    def keeng_xem_nhieu
      xem_nhieu('http://keeng.vn/')
    end

    def nhac_xem_nhieu
      xem_nhieu('https://nhac.vn/')
    end

    def xem_nhieu(url)
      options = getOption
      slist, nlist = _collect_and_filter do
        MusicSource.mk_source(url).song_list_with_filter(url, options)
      end
      _post_song_list(slist, options)
    end

    def _collect_and_filter
      options = getOption
      slist   = yield
      if slist && (slist[0] || {})[:href]
        slist   = slist.uniq {|r| r[:href]}
      end

      Plog.info "Filter against HAC current content"
      slist.each do |sentry|
        sname, surl = sentry[:name], sentry[:href]
        sname = sname.strip.split(/\s*-\s*/)[0].sub(/^\d+\.\s*/, '')
        sentry[:name] = sname
      end

      save_missing = false
      case options[:site_filter]
      when 'hav'
        slist, nlist = HavSource.new.find_matching_songs(slist)
        save_missing = true
      when 'hac'
        slist, nlist = HacSource.new(options).find_matching_songs(slist)
        save_missing = true
      when '-hac'
        _tmp, slist = HacSource.new(options).find_matching_songs(slist)
      end
      Plog.info "Collect #{slist.size} matching songs"

      if options[:ofile]
        return _output_data(slist, options)
      end
      if save_missing && nlist && nlist.size > 0
        Plog.info "Writing missing list to missing.yml"
        File.open("missing.yml", 'a') do |fod|
          fod.puts nlist.to_yaml
        end
      end

      [slist, nlist]
    end

    def filter_slist
    end

    def update_pl_desc(spage, plno, title, description)
      path = "/playlist/v/#{plno}"
      spage.goto(path)
      spage.click_and_wait('#edit-playlist')
      spage.refresh
      if title != '.'
        spage.type('.playlist-detail-title input', title, clear:true)
      end
      if description != '.'
        spage.type('.playlist-detail-description input', description, clear:true)
      end
      spage.click_and_wait('#save-playlist')
    end

    # Create a playlist on hac
    def _post_playlist(plname, slist, options)
      if slist.size <= 0
        Plog.info "Nothing to post"
        return
      end
      source  = HacSource.new(options)
      ref_url = "#{source.base_url}/playlist/v/#{plname}"
      if options[:newlist]
        curlist = []
      else
        unless plname =~ /^\d+$/
          raise "You must give a numeric list to update"
        end
        curlist = source.playlist("playlist/v/#{plname}").
                  map {|r| r[:href].split('/')[4]}
      end
      slist = slist.select do |sentry|
        sname, surl = sentry[:name], sentry[:href].sub(/\?.*$/, '')
        curlist.include?(surl.split('/')[4]) ? false : true
      end

      hacfill = AutoFill.new(options)
      _connect_site do |spage|
        bar = ProgressBar.new(slist.size)
        slist.each_with_index do |sentry, index|
          sname, _surl = sentry[:name], sentry[:href].sub(/\?.*$/, '')
          Plog.info "Next to add is #{sname} - [#{index+1}/#{slist.size}]"
          hacfill.add_to_plist(spage, plname, sentry, options)
          bar.increment!
        end
        if options[:src_url]
          plno = options[:new_id] || plname
          update_pl_desc(spage, plno, '.', options[:src_url])
        end
      end
    end

    def _post_song_list(slist, options)
      if slist.size <= 0
        return
      end
      hacfill = AutoFill.new(options)
      coptions = options[:with_attribution] ? {addn_note:'Source: hopamviet.vn'} : {}
      _connect_site do |spage|
        slist.each_with_index do |sentry, index|
          sname, surl = sentry[:name], sentry[:href]
          Plog.info "Next to import is #{sname} - [#{index+1}/#{slist.size}]"
          input = hacfill.get_command_from_user
          break unless input
          if input.is_a?(Symbol)
            if input == :text_mode
            end
          else
            hacfill.create_song(spage, sentry, coptions)
          end
        end
      end
    end

    def _output_data(data, options={})
      ofile = options[:ofile] || "work.yml"

      if data.size > 0
        Plog.info "Writing #{data.size} entries to #{ofile}"
        File.open(ofile, "w") do |fod|
          fod.puts(data.to_yaml)
        end
      end
    end

    def zing_song_list(url=nil)
      base_url ||= 'https://nhac.vn'
      options = getOption
      slist   = []
      _connect_site(:zing) do |spage|
        slist = ZingSource.new.browser_song_list(spage, url, options)
      end
      slist   = AutoFill.new(options).find_missing_song(slist)
      if options[:check_lyrics]
        slist.each do |alink|
          puts ZingSource.new.lyric_info(alink[:href]).to_yaml
        end
      end
      _output_data(slist, options)
    end

    def zing_xem_nhieu(url=nil)
      options = getOption
      slist   = []
      _connect_site(:zing) do |spage|
        slist, nlist = _collect_and_filter do
          ZingSource.new.browser_song_list(spage, url, options)
        end
      end
      _post_song_list(slist, options)
    end

    def hac_chords(sfile, minc, maxc=nil)
      minc    = minc.to_i
      maxc    = maxc ? maxc.to_i : minc
      content = YAML.load_file(sfile).values
      result = content.select do |r|
        csize = r[:chords].split.size
        (csize >= minc) && (csize <= maxc)
      end
      result.to_yaml
    end

    # Saving my stuff locally
    def hac_download_songs(user='thienv')
      options = getOption
      HacSource.new(options).download_songs(user, options)
    end

    def hac_download_song(url)
      options = getOption
      HacSource.new(options).download_song(url, options)
    end

    def hac_download_lyrics_for_slist(slfile)
      options    = getOption
      hac_source = HacSource.new(options)
      YAML.load_file(slfile).each do |e|
        hrefs = e[:href].split('/')
        sno, sname, suser = hrefs[4], hrefs[5], hrefs[6]
        if suser
          lfile = "#{suser}/#{sno}::#{sname}.yml"
        else
          lfile = Dir.glob("*/#{sno}::#{sname}.yml")[0]
        end

        if !lfile || !test(?s, lfile)
          hac_source.download_song(e[:href])
        end
      end
      true
    end

    def hac_classify_waiting(user='thienv')
      options    = getOption
      hac_source = HacSource.new(options)
      url        = "#{hac_source.base_url}/manage/song/approving"
      _each_page(url) do |spage|
        sitems = spage.page.css(".song-item").select do |sitem|
          poster = sitem.css('a.song-poster')[0]['href'].split('/').last
          poster == user
        end
        sitems.each do |sitem|
          song_url = sitem.css('a.song-title')[0]['href']
          spage.goto(song_url)
          spage.click_and_wait('#edit-approve-song')
          spage.type('#song-note', 'Hop an co ban', clear:true)
          spage.click_and_wait('#submit-edit-song')
        end
      end
    end

    def lyric_info(url)
      begin
        MusicSource.mk_source(url, getOption).lyric_info(url)
      rescue => errmsg
        Plog.error "Error retrieving #{url} - #{errmsg}"
        nil
      end
    end

    def song_list(url)
      options = getOption
      begin
        MusicSource.mk_source(url, options).song_list(url, options)
      rescue => errmsg
        Plog.error "Error retrieving #{url} - #{errmsg}"
        nil
      end
    end

    def monitor_lyric(url, ofile='monitor-out.yml')
      options       = getOption
      source        = MusicSource.mk_source(url, options)
      mcontent      = []
      checked_lists = []
      last_time = Time.at(0)
      if test(?s, ofile)
        notified = YAML.load_stream(File.open(ofile)).map{|r| r[:name]}
      else
        notified = []
      end
      while true
        if Time.now > (last_time + 3600)
          Plog.info("Reloading #{url}")
          mcontent = []
          source.song_list(url).each do |r|
            if r[:href] =~ /playlist/
              unless checked_lists.include?(r[:href])
                mcontent += source.song_list(r[:href]).select{|r| r[:href] =~ /bai-hat/}
                checked_lists << r
              end
            elsif r[:href] =~ /bai-hat/
              mcontent << r
            end
          end
          last_time = Time.now
          mcontent.delete_if{|r| notified.include?(r[:name])}
        end
        if mcontent.size > 0
          Plog.info("Checking #{mcontent.size} entries")
          mcontent.each do |r|
            sinfo = source.lyric_info(r[:href])
            if sinfo[:lyric] && (sinfo[:lyric].size > 100)
              Plog.info("Lyric found for #{sinfo[:title]}")
              r[:updated_at] = Time.now
              File.open(ofile, "a") do |fod|
                fod.puts(r.to_yaml)
              end
              mcontent.delete(r)
              notified << r[:name]
            end
          end

          slist, nlist = HacSource.new.find_matching_songs(mcontent)
          puts nlist.to_yaml
          Plog.info("Waiting for 60s")
          sleep(60)
        else
          Plog.info("Waiting for 1 hour")
          sleep(3600)
        end
      end
    end

    def playlist(url)
      options = getOption
      source  = MusicSource.mk_source(url)
      result, _tmp = _collect_and_filter do
        source.song_list(url, options)
      end
      result.to_yaml
    end

    def playfile_to_hac(plname, file)
      options = getOption
      options[:site_filter] = 'hac'
      slist   = File.read(file).split("\n").map do |r|
        {name: r.sub(/,.*$/,'')}
      end
      slist, nlist = HacSource.new(options).find_matching_songs(slist)
      _post_playlist(plname, slist, options)
    end

    # Convert a playlist to HAC (find matching song and build list)
    def playlist_to_hac(plname, url)
      options = getOption
      plname  = CGI.unescape(plname) if plname.include?('%')
      options[:site_filter] = 'hac'
      options[:src_url]     = url
      if test(?f, url)
        slist  = YAML.load_file(url)
      else
        source = MusicSource.mk_source(url)
        slist, nlist = _collect_and_filter do
          if source.is_a?(ZingSource)
            slist = nil
            _connect_site(:zing) do |spage|
              slist = source.browser_song_list(spage, url, options)
            end
            slist
          elsif source.is_a?(NhacSource)
            slist = nil
            _connect_site(:nhacvn) do |spage|
              slist = source.browser_song_list(spage, url, options)
            end
            slist
          else
            source.song_list(url, options)
          end
        end
      end
      _post_playlist(plname, slist, options)
    end

    # Find list of matching songs from HAV.  List is normally from NCT
    def hav_matching_songs(cfile)
      slist, nlist = HavSource.new.find_matching_songs(YAML.load_file(cfile))
      _output_data(slist, getOption)
    end

    def youtube_dl(url)
      require 'tempfile'

      options = getOption
      odir    = options[:odir] || '.'
      ofile   = options[:ofile] || '%(title)s-%(creator)s-%(release_date)s'
      tmpf    = Tempfile.new('youtube')
      ofmt    = "#{odir}/#{ofile}.%(ext)s"
      command = "youtube-dl --extract-audio --audio-format mp3 --audio-quality 0 --embed-thumbnail"
      command += " -o '#{ofmt}' '#{url}'"
      system "set -x; #{command} | tee #{tmpf.path}"

      if options[:split]
        fline  = File.read(tmpf.path).split("\n").
                    find{|l| l.start_with?('[ffmpeg] Adding thumbnail')}
        if fline
          mp3file = fline.scan(/".*"/)[0][1..-2]
          system "set -x; mp3splt -s \"#{mp3file}\""
        end
      end
    end

    def mylist(dir='./SLIST')
      total = 0
      fentries = Dir.glob("#{dir}/*.yml").map do |f|
        content = YAML.load_file(f)
        fsize   = File.size(f)
        total  += content.size
        {name:f, fsize:fsize, count:content.size}
      end
      fentries.sort_by{|e| e[:count]}.each do |e|
        puts "%-30s %6d %3d" % [e[:name], e[:fsize], e[:count]]
      end
      puts "%-30s %6d %3d" % ['Total', 0, total]
      true
    end

    RatingUsers = %w(mbtc9522 metacritic kelichi ceenee)
    AdminUsers  = %w(gau307 kabigon91 trungdq88)
    def _getOptions
      options = getOption
      if options[:top_exclude]
        top_users = HacSource.new(options).thanh_vien(options[:top_exclude].to_i)
        options[:exclude_user] = (top_users + RatingUsers + AdminUsers).join(',')
      end
      options
    end

    def lineup_chords(ifile)
      if ifile == '-'
        lines = STDIN.read.split(/\n/)
      else
        lines = File.read(ifile).split(/\n/)
      end
      chords = []
      result = []
      lines.each do |l|
        words = l.split
        cline = true
        words.each do |w|
          if w !~ /^\[?[-A-G][Mmb#ajdimsu0-9]*(\/[A-Gb#]*)?\]?$/o
            cline = false
            break
          end
        end
        cline = false if words.size <= 0
        if cline
          s_space = true
          cword   = ''
          cindex  = 0
          # Pad the end so I don't have to handle end of text condition
          (l.gsub(/[\]\[]/, ' ') + ' ').split('').each_with_index do |c, index|
            if s_space
              if c !~ /\s/
                cword   = c
                cindex  = index
                s_space = false
              end
            else
              if c =~ /\s/
                chords << [cword, cindex]
                cword   = ''
                s_space = true
              else
                cword += c
              end
            end
          end
        else
          if l =~ /^\[(.*)\]$/
            l = "#{$1}:"
          end
          l = l.tr('[]', '<>')
          if chords.size > 0
            # Reverse to avoid changing the disturbing existing text until touched
            chords.reverse.each do |text, pos|
              begin
                if l.size <= pos
                  l += ' ' * 80
                end
                l.insert(pos, "[#{text}]")
              rescue => errmsg
                Plog.error errmsg
              end
            end
            chords = []
          end
          l = l.strip.gsub(/\s+/, ' ')
          #Plog.dump_info(cline:cline, l:l)
          result << ' ' + l
        end
      end
      result
    end

    def sendto(url, method, *args)
      options = getOption
      MusicSource.mk_source(url, options).send(method, url, options, *args)
    end
  end
end

if (__FILE__ == $0)
  HACAuto.handleCli(
    ['--auth',             '-a', 1],
    ['--with_attribution', '-A', 0],
    ['--browser',          '-b', 1],
    ['--odir',             '-d', 1],
    ['--force',            '-f', 0],
    ['--site_filter',      '-F', 1],
    ['--hac_url',          '-H', 1],
    ['--check_lyrics',     '-k', 0],
    ['--limit',            '-l', 1],
    ['--lyrics',           '-L', 0],
    ['--newlist',          '-n', 0],
    ['--ofile',            '-o', 1],
    ['--pcount',           '-p', 1],        # Play count
    ['--page',             '-P', 1],        # Start page
    ['--split',            '-s', 0],        # Start page
    ['--verbose',          '-v', 0],        # Start page
    ['--exclude_user',     '-x', 1],
    ['--top_exclude',      '-X', 1],
  )
end

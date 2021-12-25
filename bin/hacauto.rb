#!/usr/bin/env ruby
# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        hacauto.rb
#---------------------------------------------------------------------------
#++
require "#{File.dirname(__FILE__)}/../etc/toolenv"
require 'selenium-webdriver'
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'pry-byebug'
require 'tty-progressbar'
require 'thor'
require 'core'
require 'site_connect'
require_relative 'hac-base'
require_relative 'hac-nhac'

# Docs for class SPage < SelPage
class SPage < SelPage
  # attr_reader :sdriver, :page, :auser, :clicks
  attr_reader :auser

  def initialize(sdriver)
    super(sdriver)
    @auser   = sdriver.auser
    @clog    = ClickLog.new(@auser)
  end

  def find_and_click_song_links(lselector, rselector, options={})
    unless (exclude_user = options[:exclude_user]).nil?
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
        rcount = if rcount =~ /k$/
                   rcount.to_i * 1000
                 else
                   rcount.to_i
                 end
        next if rcount < pcount
      end
      # Only click from real song link
      link = item.css('a.song-title')[0]['href']
                 .sub(%r{/manage/song/approve/}, '/song/')
      links << link
    end
    click_links(links, rselector, options)
    song_items
  end

  def click_links(links, rselector, options={})
    limit = (options[:limit] || 1000).to_i
    cwait = options[:click_wait].to_i
    links = links.reject { |r| @clog.was_clicked?(@auser, r, rselector) } unless options[:force]
    return if links.size <= 0

    Plog.info("Click #{links.size} links")
    links.each do |link|
      goto(link)
      @sdriver.click_and_wait(rselector, 3)
      @clicks += 1
      @clog.log_click(@auser, link, rselector)
      break if @clicks >= limit

      if cwait
        puts "... Wait #{cwait} ..."
        sleep(cwait)
      end
    end
  end
end

# Docs for class AutoFill
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
      # Plog.info("Found #{fsize} for #{sname}")
      return false
    end

    true
  end

  def find_missing_song(slist)
    missing = []
    bar = TTY::ProgressBar.new('Missing [:bar] :percent', slist.size)
    slist.each do |sinfo|
      sname = sinfo[:name]
      if missing?(sname)
        missing << sinfo
        bar.log "Missing #{sname} (#{missing.size})"
      end
      bar.advance
    end
    missing
  end

  def get_page_lyric(url)
    MusicSource.mk_source(url).lyric_info(url)
  rescue StandardError => e
    Plog.error "Error retrieving #{url} - #{e}"
    nil
  end

  HELP_TEXT = <<~EOH
    b       - Debug program
    h       - Show this info
    p       - Redo previous
    r       - Reload script
    s       - Skip next
    t       - Text mode
    w       - Write current list
    x       - Exit program
  EOH

  # rubocop:disable Security/Eval
  def read_command_from_user
    loop do
      $stderr.print 'Command [b|h|p|r|s|t|w|x]? '
      $stderr.flush
      ans = $stdin.gets.strip
      case ans
      when /^b/io
        require 'pry-byebug'
        # byebug
        binding.pry
      when /^(h|\?)/io
        warn HELP_TEXT
      when /^p/io
        return :previous
      when /^r/io
        $0 = 'Running'
        file = __FILE__
        begin
          eval "load '#{file}'", TOPLEVEL_BINDING, __FILE__, __LINE__
        rescue StandardError => e
          Plog.error e
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
  # rubocop:enable Security/Eval

  SONG_SITES = [
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
    'https://www.youtube.com'
  ].freeze
  def google_for_song(query)
    Plog.info "Searching Google for [#{query}]"
    query  = CGI.escape(query)
    page   = get_page("https://www.google.com/search?q=#{query}")
    links  = []
    links0 = []
    page.css('.r a').each do |l|
      href = l['href'].sub(%r{^/url\?q=}, '').sub(/&.*$/, '')
      href = CGI.unescape(href)
      links0 << href
      SONG_SITES.select do |asite|
        next unless href.start_with?(asite)

        links << href
        break
      end
    end
    Plog.info({links0: links0}.to_yaml)
    links
  end

  def play_song(sinfo, spage=nil)
    # Origin link is music already
    source = sinfo[:source]
    if source =~ /nhaccuatui|zing/
      spage.type('#song-link', source, clear: true)
      system "open '#{source}'"
    else
      work_link = nil
      title     = sinfo[:title].sub(/\(.*$/, '')
      lset      = google_for_song("#{title} #{sinfo[:artist]}")
      unless lset.empty?
        # Default to 1st one.  If not working, we could select next
        slink = lset[0]
        loop do
          work_link = slink
          if spage
            begin
              spage.type('#song-link', work_link, clear: true)
            rescue StandardError => e
              Plog.error e
            end
          end
          system "open '#{work_link}'"
          slink = Cli.select(lset, 'Select a music link')
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
  rescue StandardError => e
    Plog.error e
  end

  def create_song(spage, sinfo, options={})
    surl = sinfo[:href]
    if !sinfo[:lyric] && !(info = get_page_lyric(surl)).nil?
      return nil unless sinfo[:lyrics]

      sinfo.update(info)
    end

    Plog.dump_info(pcount: sinfo[:pcount])
    begin
      spage.click_and_wait('#create-song-link', 4)
      spage.click_and_wait('#auto-caret-btn', 0)
      spage.type('#song-name', sinfo[:title])
      lnote = sinfo[:lnote] || ''
      lnote += "\n#{options[:addn_note]}" if options[:addn_note]
      if !lnote.empty?
        spage.type('#song-lyric', "#{lnote.strip}\n===\n#{sinfo[:lyric]}")
      else
        spage.type('#song-lyric', sinfo[:lyric])
      end
      spage.type('#song-authors', sinfo[:author])
      spage.type('#song-genres',  sinfo[:genre])
      spage.type('#singer-names', sinfo[:artist])
      spage.type('#singer-key',   sinfo[:chord])
      spage.type('#song-link',    sinfo[:source])
      Plog.info 'Review page to fill in remaining info and submit afterward'
      play_song(sinfo, spage)
    rescue StandardError => e
      Plog.error e
    end
    info
  end

  def create_from_site(spage, store, coptions={})
    loop do
      sinfo = store.peek
      break unless sinfo

      input = nil
      text_mode = false
      loop do
        Plog.info "Next to import is #{sinfo[:name]} - [#{store.curptr + 1}/#{store.songs.size}]" if sinfo[:name]

        input = read_command_from_user
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

      Plog.dump_info(sinfo: sinfo, text_mode: text_mode)
      next unless sinfo[:href]

      if text_mode
        puts sinfo.to_yaml
      else
        create_song(spage, sinfo, coptions)
      end
      store.advance
    end
  end
end

# Docs for class SongStore
class SongStore
  attr_reader :file, :songs, :curptr

  def initialize(files, options={})
    @options = options
    @files   = files
    @curptr  = 0
    @songs   = []
    @files.each do |file|
      if test('s', file)
        songs = YAML.safe_load_file(file)
        Plog.info "Reading #{songs.size} entries from #{file}"
        @songs += songs
      else
        Plog.info "#{file} not available (or empty)"
      end
    end
    if @options[:pcount]
      @songs = @songs.sort_by { |e| e[:pcount] || 0 }.reverse
    elsif @options[:random]
      @songs = @songs.sort_by { rand }
    end
  end

  def save
    if @files.size <= 0
      Plog.info('Skip saving.  No original input files')
      return
    end
    if @curptr < @songs.size
      csize = @songs.size - @curptr
      wfile = @files[0]
      Plog.info "Writing remaining #{csize} entries to #{wfile}"
      File.open(wfile, 'w') do |fod|
        fod.puts @songs[@curptr..].to_yaml
      end
      rmfiles = @files[1..]
    else
      rmfiles = @files
    end
    return if rmfiles.empty?

    Plog.info "Complete list from #{rmfiles}.  Removing"
    rmfiles.each do |afile|
      File.delete(afile)
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
      $stderr.print 'URL/File to retrieve song: '
      $stderr.flush
      url = $stdin.gets.strip
      return {} if url.empty? || url =~ /^x/i

      if test('f', url)
        @songs[@curptr] = YAML.safe_load_file(url)
      elsif url =~ /hopamchuan/
        sinfo = {href: url}
        @hac_source ||= HacSource.new(@options)
        sinfo.update(@hac_source.lyric_info(sinfo[:href]) || {})
        @songs[@curptr] = sinfo
      elsif url =~ /^http/i
        if url !~ /hopamviet.vn/
          havinfo = HACAuto.hav_find_matching_song(url)
          @songs[@curptr] = {href: havinfo ? havinfo[:href] : url}
        else
          @songs[@curptr] = {href: url}
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

module HACCommon
  def _connect_site(site: :hac)
    if @sdriver
      do_close = false
    else
      @sdriver = case site
                 when :gmusic
                   SiteConnect.connect_gmusic(_get_options)
                 when :zing
                   SiteConnect.connect_zing(_get_options)
                 when :nhacvn
                   SiteConnect.connect_nhacvn(_get_options)
                 when :singsalon
                   SiteConnect.connect_singsalon(_get_options)
                 else
                   SiteConnect.connect_hac(_get_options)
                 end
      do_close = true
    end
    yield SPage.new(@sdriver)
    return unless do_close

    @sdriver.close
    @sdriver = nil
  end

  def _each_page(link)
    options = _get_options
    if (value = options[:page]).nil?
      page = 0
      incr = 1
    else
      page, incr = value.split(',')
      page = value.to_i
      incr = (incr || 1).to_i
    end
    limit = (options[:limit] || 1000).to_i
    _connect_site do |spage|
      loop do
        offset = page * 10
        spage.goto("#{link}?offset=#{offset}")
        links = yield spage
        break if !links || links.size <= 0
        break if spage.clicks >= limit

        page += incr
        break if page < 0
      end
    end
  end

  def _collect_and_filter
    options = _get_options
    slist   = yield
    slist = slist.uniq { |r| r[:href] } if slist && (slist[0] || {})[:href]

    Plog.info 'Filter against HAC current content'
    slist.each do |sentry|
      sname = sentry[:name]
      _surl = sentry[:href]
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

    return _output_data(slist, options) if options[:ofile]

    if save_missing && nlist && !nlist.empty?
      Plog.info 'Writing missing list to missing.yml'
      File.open('missing.yml', 'a') do |fod|
        fod.puts nlist.to_yaml
      end
    end

    [slist, nlist]
  end

  def _output_data(data, options={})
    return if data.empty?

    ofile = options[:ofile] || 'work.yml'
    Plog.info "Writing #{data.size} entries to #{ofile}"
    File.open(ofile, 'w') do |fod|
      fod.puts(data.to_yaml)
    end
  end

  RATING_USERS = %w[mbtc9522 metacritic kelichi ceenee].freeze
  ADMIN_USERS  = %w[gau307 kabigon91 trungdq88].freeze
  def _get_options
    moptions = writable_options
    if moptions[:top_exclude]
      top_users = HacSource.new(moptions).thanh_vien(moptions[:top_exclude].to_i)
      moptions[:exclude_user] = (top_users + RATING_USERS + ADMIN_USERS).join(',')
    end
    moptions
  end
end

class HACHAC < Thor
  include ThorAddition
  include HACCommon

  class_option :hac_url, aliases: '-H', type: :string

  no_commands do
    #
    # Create a playlist on hac
    def _post_playlist(plname, slist, moptions)
      if slist.size <= 0
        Plog.info 'Nothing to post'
        return
      end
      source = HacSource.new(moptions)
      if moptions[:newlist]
        curlist = []
      else
        raise 'You must give a numeric list to update' unless plname =~ /^\d+$/

        curlist = source.playlist("playlist/v/#{plname}")
                        .map { |r| r[:href].split('/')[4] }
      end
      slist = slist.select do |sentry|
        _sname = sentry[:name]
        surl = sentry[:href].sub(/\?.*$/, '')
        curlist.include?(surl.split('/')[4]) ? false : true
      end

      hacfill = AutoFill.new(moptions)
      _connect_site do |spage|
        bar = TTY::ProgressBar.new('Posting [:bar] :percent', slist.size)
        slist.each_with_index do |sentry, index|
          sname = sentry[:name]
          _surl = sentry[:href].sub(/\?.*$/, '')
          bar.log "Next to add is #{sname} - [#{index + 1}/#{slist.size}]"
          hacfill.add_to_plist(spage, plname, sentry, moptions)
          bar.advance
        end
        if moptions[:src_url]
          plno = moptions[:new_id] || plname
          update_pl_desc(spage, plno, '.', moptions[:src_url])
        end
      end
    end
  end

  desc 'chords(sfile, minc, maxc=nil)', 'chords'
  def chords(sfile, minc, maxc=nil)
    minc    = minc.to_i
    maxc    = maxc ? maxc.to_i : minc
    content = YAML.safe_load_file(sfile).values
    result = content.select do |r|
      csize = r[:chords].split.size
      (csize >= minc) && (csize <= maxc)
    end
    result.to_yaml
  end

  # Saving my stuff locally
  desc "download_songs(user='thienv')", 'download_songs'
  def download_songs(user='thienv')
    moptions = _get_options
    HacSource.new(moptions).download_songs(user, moptions)
  end

  desc 'download_song(url)', 'download_song'
  def download_song(url)
    moptions = _get_options
    source = HacSource.new(moptions).download_song(url, moptions)
    source[:lyric].gsub(/\[[^\]]+\]/, '')
  end

  desc 'download_lyrics_for_slist(slfile)', 'download_lyrics_for_slist'
  def download_lyrics_for_slist(slfile)
    moptions = _get_options
    hac_source = HacSource.new(moptions)
    YAML.safe_load_file(slfile).each do |e|
      hrefs = e[:href].split('/')
      sno = hrefs[4]
      sname = hrefs[5]
      suser = hrefs[6]
      lfile = if suser
                "#{suser}/#{sno}::#{sname}.yml"
              else
                Dir.glob("*/#{sno}::#{sname}.yml")[0]
              end

      hac_source.download_song(e[:href]) if !lfile || !test('s', lfile)
    end
    true
  end

  desc "classify_waiting(user='thienv')", 'classify_waiting'
  def classify_waiting(user='thienv')
    moptions = _get_options
    hac_source = HacSource.new(moptions)
    url        = "#{hac_source.base_url}/manage/song/approving"
    _each_page(url) do |spage|
      sitems = spage.page.css('.song-item').select do |sitem|
        poster = sitem.css('a.song-poster')[0]['href'].split('/').last
        poster == user
      end
      sitems.each do |sitem|
        song_url = sitem.css('a.song-title')[0]['href']
        spage.goto(song_url)
        spage.click_and_wait('#edit-approve-song')
        spage.type('#song-note', 'Hop an co ban', clear: true)
        spage.click_and_wait('#submit-edit-song')
      end
    end
  end

  desc 'rate_today', 'rate_today'
  def rate_today
    moptions = _get_options
    _connect_site do |spage|
      spage
        .find_and_click_links('a.hot-today-item-song',
                              '#contribute-rating-control', moptions)
    end
  end

  desc 'rate_week', 'rate_week'
  def rate_week
    moptions = _get_options
    _connect_site do |spage|
      spage
        .find_and_click_song_links('div#weekly-monthly-list',
                                   '#contribute-rating-control', moptions)
    end
  end

  desc 'rate_new(level=3)', 'rate_new'
  def rate_new(level=3)
    moptions = _get_options
    _connect_site do |spage|
      1.upto(5).each do |page|
        spage.goto('/')
        spage.click_and_wait("#recent-list-pagination li:nth-child(#{page})")
        spage.refresh
        spage
          .find_and_click_song_links('div#recent-list',
                                     "#contribute-rating-control li:nth-child(#{level})",
                                     moptions)
      end
    end
  end

  desc 'rate_path(path, level)', 'rate_path'
  def rate_path(path, level)
    moptions = _get_options
    hac_source = HacSource.new(moptions)
    path       = path.sub(/#{hac_source.base_url}/i, '')
    _each_page(path) do |spage|
      spage
        .find_and_click_song_links('div.song-list',
                                   "#contribute-rating-control li:nth-child(#{level})",
                                   moptions)
    end
  end

  desc 'rate_user(user, level)', 'rate_user'
  def rate_user(user, level)
    rate_path("profile/posted/#{user}", level)
  end

  desc 'rate_posted(level=3)', 'rate_posted'
  def rate_posted(level=3)
    rate_path('manage/song/approved', level)
  end

  desc 'rate_rhymth(rhymth, level=3)', 'rate_rhymth'
  def rate_rhymth(rhymth, level=3)
    rate_path("rhymth/v/#{rhymth}", level)
  end

  desc 'rate_genre(genre, level=3)', 'rate_genre'
  def rate_genre(genre, level=3)
    rate_path("genre/v/#{genre}", level)
  end

  desc 'rate_artist(artist, level=3)', 'rate_artist'
  def rate_artist(artist, level=3)
    rate_path("artist/#{artist}", level)
  end

  desc 'playfile_to_hac(plname, file)', 'playfile_to_hac'
  def playfile_to_hac(plname, file)
    moptions = _get_options
    moptions[:site_filter] = 'hac'
    slist = File.read(file).split("\n").map do |r|
      {name: r.sub(/,.*$/, '')}
    end
    slist, _nlist = HacSource.new(moptions).find_matching_songs(slist)
    _post_playlist(plname, slist, moptions)
  end

  # Convert a playlist to HAC (find matching song and build list)
  desc 'playlist_to_hac(plname, url)', 'playlist_to_hac'
  def playlist_to_hac(plname, url)
    moptions = _get_options
    plname = CGI.unescape(plname) if plname.include?('%')
    moptions[:site_filter] = 'hac'
    moptions[:src_url]     = url
    if test('f', url)
      slist  = YAML.safe_load_file(url)
    else
      source = MusicSource.mk_source(url)
      slist, _nlist = _collect_and_filter do
        case source
        when ZingSource
          slist = nil
          _connect_site(site: :zing) do |spage|
            slist = source.browser_song_list(spage, url, moptions)
          end
          slist
        when NhacSource
          slist = nil
          _connect_site(site: :nhacvn) do |spage|
            slist = source.browser_song_list(spage, url, moptions)
          end
          slist
        else
          source.song_list(url, moptions)
        end
      end
    end
    _post_playlist(plname, slist, moptions)
  end
end

# Docs for class HACAuto
class HACAuto < Thor
  include ThorAddition
  include HACCommon

  desc 'hac SUBCOMMAND', 'hac commands'
  subcommand 'hac', HACHAC

  class_option :auth,             aliases: '-a', type: :string
  class_option :with_attribution, aliases: '-A', type: :boolean
  class_option :browser,          aliases: '-b', type: :string
  class_option :odir,             aliases: '-d', type: :string
  class_option :force,            aliases: '-f', type: :boolean
  class_option :site_filter,      aliases: '-F', type: :string
  class_option :check_lyrics,     aliases: '-k', type: :boolean
  class_option :limit,            aliases: '-l', type: :string
  class_option :lyrics,           aliases: '-L', type: :boolean
  class_option :newlist,          aliases: '-n', type: :boolean
  class_option :ofile,            aliases: '-o', type: :string
  class_option :pcount,           aliases: '-p', type: :string
  class_option :page,             aliases: '-P', type: :string
  class_option :verbose,          aliases: '-v', type: :boolean
  class_option :click_wait,       aliases: '-w', type: :string
  class_option :exclude_user,     aliases: '-x', type: :string
  class_option :top_exclude,      aliases: '-X', type: :string

  no_commands do
    def _post_song_list(slist, moptions)
      return if slist.size <= 0

      hacfill = AutoFill.new(moptions)
      coptions = moptions[:with_attribution] ? {addn_note: 'Source: hopamviet.vn'} : {}
      _connect_site do |spage|
        slist.each_with_index do |sentry, index|
          sname = sentry[:name]
          _surl = sentry[:href]
          Plog.info "Next to import is #{sname} - [#{index + 1}/#{slist.size}]"
          input = hacfill.read_command_from_user
          break unless input

          hacfill.create_song(spage, sentry, coptions) unless input.is_a?(Symbol)
        end
      end
    end

    def _transpose(file, offset)
      offset = offset.sub(/^m/, '-') if offset.is_a?(String)
      Plog.info "Transpose #{file} by #{offset} semitone"
      ofile = file.sub(/\./, "-t#{offset}.")
      command = "sox \"#{file}\" \"#{ofile}\" pitch #{offset}00"
      system("set -x; #{command}")
    end
  end

  desc 'hav_find_matching_song(url)', 'hav_find_matching_song'
  def hav_find_matching_song(url)
    moptions = _get_options
    linfo = AutoFill.new(moptions).get_page_lyric(url)
    HavSource.new.find_matching_song(linfo[:title]).first
  end

  desc 'gmusic_plist(plist)', 'gmusic_plist'
  def gmusic_plist(plist)
    _connect_site(site: :gmusic) do |spage|
      path = "listen#/app/#{plist}"
      spage.goto(path)
      spage.page.css('tr.song-row td[data-col="title"]')
    end
  end

  desc 'like_user(user)', 'like_user'
  def like_user(user)
    moptions = _get_options
    _each_page("/profile/posted/#{user}") do |spage|
      nlinks = []
      sitems = spage.page.css('.song-item')
      sitems.each do |sitem|
        iclasses = sitem.css('.song-like')[0].attr('class').split
        next if iclasses.include?('starred')

        nlinks << sitem.css('.song-title')[0]['href']
      end
      spage.click_links(nlinks, '#song-favorite-star-btn', moptions)
      sitems
    end
  end

  desc 'approve_versions(user)', 'approve_versions'
  def approve_versions(user)
    _each_page("/profile/posted/#{user}") do |spage|
      sitems = spage.page.css('.song-item')
      sitems.each do |sitem|
        purl   = sitem.css('a.song-poster')[0]['href']
        poster = purl.split('/')[-1]
        next if poster == user

        url = sitem.css('.song-title')[0]['href']
        _review_version(url, spage)
      end
    end
  end

  desc 'create_from_site(*sfiles)', 'create_from_site'
  def create_from_site(*sfiles)
    moptions          = _get_options
    moptions[:random] = true
    coptions         = moptions[:with_attribution] ? {addn_note: 'Source: hopamviet.vn'} : {}
    store            = SongStore.new(sfiles, moptions)
    _connect_site do |spage|
      AutoFill.new(moptions).create_from_site(spage, store, coptions)
      store&.save
    end
  end

  # Get the song from hav but missing from hac.  Optionally create the songs on hac
  desc 'hav_find_missing(curl)', 'hav_find_missing'
  def hav_find_missing(curl)
    moptions = _get_options
    slist   = HavSource.new.scan_song_list(curl, moptions)
    slist   = AutoFill.new(moptions).find_missing_song(slist)
    moptions[:ofile] ||= "#{File.basename(curl).sub(/\..*$/, '')}.yml"
    slist.each do |sinfo|
      sinfo.update(HavSource.new.lyric_info(sinfo[:href]))
    end
    _output_data(slist, moptions)
  end

  desc 'hav_load_songs(sfile)', 'hav_load_songs'
  def hav_load_songs(sfile)
    moptions = _get_options
    slist   = YAML.safe_load_file(sfile)
    bar     = TTY::ProgressBar.new('Loading song [:bar] :percent', slist.size)
    slist.each do |sinfo|
      unless sinfo[:lyric]
        begin
          sinfo.update(HavSource.new.lyric_info(sinfo[:href]))
        rescue StandardError => e
          bar.log(e.to_s)
        end
      end
      bar.advance
    end
    moptions[:ofile] ||= sfile
    _output_data(slist, moptions)
  end

  desc 'hav_new_songs', 'hav_new_songs'
  def hav_new_songs
    xem_nhieu('https://hopamviet.vn/chord/latest')
  end

  desc 'hah_xem_nhieu(list_no=0)', 'hah_xem_nhieu'
  def hah_xem_nhieu(list_no=0)
    moptions = _get_options
    moptions[:list_no] = list_no
    xem_nhieu('https://hopamhay.com')
  end

  desc 'hav_xem_nhieu', 'hav_xem_nhieu'
  def hav_xem_nhieu
    xem_nhieu('https://hopamviet.vn')
  end

  desc 'keeng_xem_nhieu', 'keeng_xem_nhieu'
  def keeng_xem_nhieu
    xem_nhieu('http://keeng.vn/')
  end

  desc 'nhac_xem_nhieu', 'nhac_xem_nhieu'
  def nhac_xem_nhieu
    xem_nhieu('https://nhac.vn/')
  end

  desc 'xem_nhieu(url)', 'xem_nhieu'
  def xem_nhieu(url)
    moptions = _get_options
    slist, _nlist = _collect_and_filter do
      MusicSource.mk_source(url).song_list_with_filter(url, moptions)
    end
    _post_song_list(slist, moptions)
  end

  desc 'update_pl_desc(spage, plno, title, description)', 'update_pl_desc'
  def update_pl_desc(spage, plno, title, description)
    path = "/playlist/v/#{plno}"
    spage.goto(path)
    spage.click_and_wait('#edit-playlist')
    spage.refresh
    spage.type('.playlist-detail-title input', title, clear: true) if title != '.'
    spage.type('.playlist-detail-description input', description, clear: true) if description != '.'
    spage.click_and_wait('#save-playlist')
  end

  desc 'zing_song_list(url=nil)', 'zing_song_list'
  def zing_song_list(url=nil)
    moptions = _get_options
    slist = []
    _connect_site(site: :zing) do |spage|
      slist = ZingSource.new.browser_song_list(spage, url, moptions)
    end
    slist = AutoFill.new(moptions).find_missing_song(slist)
    if moptions[:check_lyrics]
      slist.each do |alink|
        puts ZingSource.new.lyric_info(alink[:href]).to_yaml
      end
    end
    _output_data(slist, moptions)
  end

  desc 'zing_xem_nhieu(url=nil)', 'zing_xem_nhieu'
  def zing_xem_nhieu(url=nil)
    moptions = _get_options
    slist = []
    _connect_site(site: :zing) do |spage|
      slist, _nlist = _collect_and_filter do
        ZingSource.new.browser_song_list(spage, url, moptions)
      end
    end
    _post_song_list(slist, moptions)
  end

  desc 'lyric_info(url)', 'lyric_info'
  def lyric_info(url)
    MusicSource.mk_source(url, _get_options).lyric_info(url)
  rescue StandardError => e
    Plog.error "Error retrieving #{url} - #{e}"
    nil
  end

  desc 'song_list(url)', 'song_list'
  def song_list(url)
    moptions = _get_options
    MusicSource.mk_source(url, moptions).song_list(url, moptions)
  rescue StandardError => e
    Plog.error "Error retrieving #{url} - #{e}"
    nil
  end

  desc "monitor_lyric(url, ofile='monitor-out.yml')", 'monitor_lyric'
  def monitor_lyric(url, ofile='monitor-out.yml')
    moptions = _get_options
    source        = MusicSource.mk_source(url, moptions)
    mcontent      = []
    checked_lists = []
    last_time = Time.at(0)
    notified = if test('s', ofile)
                 YAML.load_stream(File.open(ofile)).map { |r| r[:name] }
               else
                 []
               end
    loop do
      if Time.now > (last_time + 3600)
        Plog.info("Reloading #{url}")
        mcontent = []
        source.song_list(url).each do |r|
          case r[:href]
          when /playlist/
            unless checked_lists.include?(r[:href])
              mcontent += source.song_list(r[:href]).select { |r2| r2[:href] =~ /bai-hat/ }
              checked_lists << r
            end
          when /bai-hat/
            mcontent << r
          end
        end
        last_time = Time.now
        mcontent.delete_if { |r| notified.include?(r[:name]) }
      end
      if mcontent.empty?
        Plog.info('Waiting for 1 hour')
        sleep(3600)
      else
        Plog.info("Checking #{mcontent.size} entries")
        mcontent.each do |r|
          sinfo = source.lyric_info(r[:href])
          next unless sinfo[:lyric] && (sinfo[:lyric].size > 100)

          Plog.info("Lyric found for #{sinfo[:title]}")
          r[:updated_at] = Time.now
          File.open(ofile, 'a') do |fod|
            fod.puts(r.to_yaml)
          end
          mcontent.delete(r)
          notified << r[:name]
        end

        _slist, nlist = HacSource.new.find_matching_songs(mcontent)
        puts nlist.to_yaml
        Plog.info('Waiting for 60s')
        sleep(60)
      end
    end
  end

  desc 'playlist(url)', 'playlist'
  def playlist(url)
    moptions = _get_options
    source = MusicSource.mk_source(url)
    result, _tmp = _collect_and_filter do
      source.song_list(url, moptions)
    end
    result.to_yaml
  end

  # Find list of matching songs from HAV.  List is normally from NCT
  desc 'hav_matching_songs(cfile)', 'hav_matching_songs'
  def hav_matching_songs(cfile)
    slist, _nlist = HavSource.new.find_matching_songs(YAML.safe_load_file(cfile))
    _output_data(slist, _get_options)
  end

  desc 'transpose(file, offset)', 'transpose'
  def transpose(file, offset)
    _transpose(file, offset)
  end

  desc 'youtube_dl url', 'Download MP3 file from Youtube URL'
  option :odir,      type: :string, desc:'Directory to save file to'
  option :open,      type: :boolean, desc:'Open file after download (play)'
  option :split,     type: :boolean
  option :transpose, type: :numeric, desc:'Transpose by +- steps'
  long_desc <<~LONGDESC
    Download mp3 from youtube.  Optionally transpose, and/or split into
    multiple mp3 files
  LONGDESC
  def youtube_dl(url)
    require 'tempfile'

    moptions = _get_options
    tmpf     = Tempfile.new('youtube')
    ffmt     = '%(title)s - %(artist)s.%(ext)s'
    command  = "youtube-dl --get-filename -o '#{ffmt}' '#{url}'"
    basename = `set -x; #{command}`.chomp.split('.').first

    command = "youtube-dl --extract-audio --audio-format mp3 --audio-quality 0 --embed-thumbnail -o '#{ffmt}' '#{url}'"
    system "set -x; #{command} | tee #{tmpf.path}"

    mp3file = "#{basename}.mp3"
    raise "Failed to download mp3 from #{url}" unless test('s', mp3file)

    # Set the download date
    system("touch \"#{mp3file}\"")

    newfile = mp3file.sub(/-[a-z0-9_]+.*mp3/, '.mp3')
    if moptions[:odir]
      newfile = "#{moptions[:odir]}/#{newfile}"
    end
    if newfile != mp3file
      File.rename(mp3file, newfile)
      mp3file = newfile
    end

    if moptions[:split]
      fline = File.read(tmpf.path).split("\n")
                  .find { |l| l.start_with?('[ffmpeg] Adding thumbnail') }
      return unless fline

      # Split using silence detection.  See split_mp3 operation because you'd
      # wind up having to rename/adding metadata im this mode.  It could be
      # used. however. as a dry run to build the final cue file to be used
      # for split_mp3 operation
      system "set -x; mp3splt -s \"#{mp3file}\""
    end

    unless (offset = moptions[:transpose]).nil?
      _transpose(mp3file, offset)
    end

    system("set -x; open -a 'Sonic Visualiser' \"#{mp3file}\"") if moptions[:open]
  end

  desc "split_mp3(mp3file, cuefile)", "Split mp3 file using cuefile"
  def split_mp3(mp3file, cuefile)
    cli_wrap do
      # Convert a simple CSV input to the cue file to be used by mp3splt
      # Line is
      #   MM:SS:00 | Title | Performer
      if cuefile =~ /\.csv/
        tmpf = Tempfile.new(['', '.cue'])
        fdefs = File.read(cuefile).split("\n").map{|r| r.split('|')}
        trackno = 1
        tmpf.puts <<~EOH
REM GENRE Vietnamese
REM DATE #{Time.now.strftime('%Y')}
PERFORMER ""
TITLE ""
FILE "#{mp3file}" MP3
        EOH
        flist = fdefs.each do |time, title, performer|
          track_s = "%02d" % trackno
          tmpf.puts <<~EOD
  TRACK #{track_s} AUDIO
    TITLE     "#{title.strip}"
    PERFORMER "#{(performer || '').strip}"
    INDEX 01  #{time.strip}
          EOD
          trackno += 1
        end
        tmpf.close
        puts File.read(tmpf.path)
        cuefile = tmpf.path
      end
      
      # mp3split cannot deal with '/' in name.  So we have to remove
      ocuefile = File.basename(mp3file).sub(/\.mp3/, '.cue')
      system "set -x; mp3splt -c #{cuefile} -E \"#{ocuefile}\" -o \"@t - @p\" \"#{mp3file}\""
    end
  end

  desc "retag_mp3_from_vc(mp3file)", "retag_mp3_from_vc"
  def retag_mp3_from_vc(mp3file)
    cli_wrap do
      title, artist = File.basename(mp3file).split(' - ')

      # iTunes cannot deal with specia chars in id3lib - so have to strip it
      # down
      artist  = to_search_str(artist.sub(/\..*$/, ''), has_case:true)
      title   = to_search_str(title, has_case:true)
      command = "id3v2"
      command += " --song '#{title}'"
      command += " --artist '#{artist}'"
      command += " --album VC"
      command += " '#{mp3file}'"
      system("set -x; #{command}")
    end
  end

  desc "mylist(dir='./SLIST')", 'mylist'
  def mylist(dir='./SLIST')
    total = 0
    fentries = Dir.glob("#{dir}/*.yml").map do |f|
      content = YAML.safe_load_file(f)
      fsize   = File.size(f)
      total  += content.size
      {name: f, fsize: fsize, count: content.size}
    end
    fentries.sort_by { |e| e[:count] }.each do |e|
      puts format('%<name>-30s %<fsize>6d %<count>3d', name: e[:name],
                  fsize: e[:fsize], count: e[:count])
    end
    puts format('%<name>-30s %<fsize>6d %<count>3d', name: 'Total',
                fsize: 0, total: total)
    true
  end

  desc 'lineup_chords(ifile)', 'lineup_chords'
  def lineup_chords(ifile)
    lines = if ifile == '-'
              $stdin.read.split(/\n/)
            else
              File.read(ifile).split(/\n/)
            end
    chords = []
    result = []
    lines.each do |l|
      words = l.split
      cline = true
      words.each do |w|
        if w !~ %r{^\[?[-A-G][Mmb#ajdimsu0-9]*(/[A-Gb#]*)?\]?$}o
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
        ("#{l.gsub(/[\]\[]/, ' ')} ").split('').each_with_index do |c, index|
          if s_space
            if c !~ /\s/
              cword   = c
              cindex  = index
              s_space = false
            end
          elsif c =~ /\s/
            chords << [cword, cindex]
            cword   = ''
            s_space = true
          else
            cword += c
          end
        end
      else
        l = "#{Regexp.last_match(1)}:" if l =~ /^\[(.*)\]$/
        l = l.tr('[]', '<>')
        unless chords.empty?
          # Reverse to avoid changing the disturbing existing text until touched
          chords.reverse.each do |text, pos|
            l += ' ' * 80 if l.size <= pos
            l.insert(pos, "[#{text}]")
          rescue StandardError => e
            Plog.error e
          end
          chords = []
        end
        l = l.strip.gsub(/\s+/, ' ')
        # Plog.dump_info(cline: cline, l: l)
        result << " #{l}"
      end
    end
    result
  end
end

HACAuto.start(ARGV) if __FILE__ == $PROGRAM_NAME

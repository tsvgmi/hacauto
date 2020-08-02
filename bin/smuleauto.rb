#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hacauto.rb
#---------------------------------------------------------------------------
#++
require_relative "../etc/toolenv"
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'http'
require 'core'
require 'site_connect'
require 'smule_player'
require 'tty-spinner'
require 'tty-progressbar'
require 'thor'

require 'smule-content'

def clean_emoji(str='')
  str=str.force_encoding('utf-8').encode
  arr_regex=[/[\u{1f600}-\u{1f64f}]/,/[\u{2702}-\u{27b0}]/,/[\u{1f680}-\u{1f6ff}]/,/[\u{24C2}-\u{1F251}]/,/[\u{1f300}-\u{1f5ff}]/]
  arr_regex.each do |regex|
          str = str.gsub regex, ''
  end
  return str
end

AccentMap = {
  /[áàảãạâấầẩẫậăắằẳẵặ]/ => 'a',
  /[ÁÀẢÃẠÂẤẦẨẪẬĂẮẰẲẴẶ]/ => 'A',
  /[đ]/                 => 'd',
  /[Đ]/                 => 'D',
  /[éèẻẽẹêếềểễệ]/       => 'e',
  /[ÉÈẺẼẸÊẾỀỂỄỆ]/       => 'E',
  /[íìỉĩị]/             => 'i',
  /[ÍÌỈĨỊ]/             => 'I',
  /[óòỏõọôốồổỗộơớờởỡợ]/ => 'o',
  /[ÓÒỎÕỌÔỐỒỔỖỘƠỚỜỞỠỢ]/ => 'O',
  /[úùủũụưứừửữự]/       => 'u',
  /[ÚÙỦŨỤƯỨỪỬỮỰ]/       => 'U',
  /[ýỳỷỹỵ]/             => 'y',
  /[ÝỲỶỸỴ]/             => 'Y',
}

def to_search_str(str)
  stitle = clean_emoji(str).downcase.sub(/\s*\(.*$/, '').
    sub(/\s+[-=].*$/, '').sub(/"/, '').strip
  AccentMap.each do |ptn, rep|
    stitle = stitle.gsub(ptn, rep)
  end
  stitle
end

def curl(path, ofile=nil)
  cmd = 'curl -sA "Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:59.0) Gecko/20100101 Firefox/59.0"'
  cmd += " -o #{ofile}" if ofile
  `#{cmd} '#{path}'`
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

def created_value(value)
  if value.is_a?(String)
    value = Time.parse(value)
  elsif value.is_a?(Date)
    value = value.to_time
  end
  value
end

# Account to move songs to.  i.e. user close old account and open
# new one and we want to associate with new account
Alternate = {
  '__MinaTrinh__' => 'Mina_________',
}

def _record_by_map(record_by)
  record_by.map do |ri|
    Alternate[ri] || ri
  end
end


module SmuleAuto
  class AudioHandler
    attr_reader :exist

    def initialize(link, options={})
      @options = options
      @olink   = link.sub(/\/ensembles$/, '')
      @exist   = false

      source   = HTTP.follow.get(@olink).to_s 
      document = Nokogiri::HTML(source)
      asset    = nil
      if stream = document.at('meta[name="twitter:player:stream"]')
        @link = stream['content']
        asset = document.css('head script')[0].text.split("\n").grep(/Recording:/)[0].sub(/^\s*Recording: /, '')[0..-2]
      elsif stream = document.css('script')[0]
        if asset = stream.text.split("\n").grep(/^\s+Recording: /)[0]
          asset = asset.sub(/^\s+Recording: /, '').sub(/,$/, '')
        end
      end
      if asset
        song_info_url = (JSON.parse(asset) || {}).dig('performance', 'song_info_url')
        if song_info_url
          @song_info_url = 'https://www.smule.com' + song_info_url
          (JSON.parse(asset) || {}).dig('performance', 'song_info_url')
          @exist = true
        end
      end
      unless @exist
        Plog.error("Link no longer contain song - #{link}")
      end
    end

    def get_audio_from_singsalon(ofile, ssconnect)
      ssconnect.type('input.downloader-input', @olink)
      ssconnect.click_and_wait('input.ipsButton[value~=Fetch]')

      # This open up new window
      handles    = ssconnect.window_handles
      cur_handle = ssconnect.window_handle
      begin
        if handles.size > 1
          Plog.info("Switch to window #{handles[-1]} to download") if @options[:verbose]
          ssconnect.switch_to.window(handles[-1])
          sleep(4)
        end
        ssconnect.click_and_wait('a.ipsButton[download]')

        wait_time = 0
        while true
          if wait_time >= 60
            Plog.error("Timeout waitint for file to appear in Downloads")
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
        if handles.size > 1
          ssconnect.close
          ssconnect.switch_to.window(cur_handle)
        end
      end
      test(?s, ofile)
    end

    def get_lyric
      unless @song_info_url
        return nil
      end
      sdoc  = Nokogiri::HTML(curl(@song_info_url))
      asset = sdoc.css('head script')[0].text.split("\n").grep(/Song:/)[1].
        sub(/^\s*Song: /, '')[0..-2]
      if asset = JSON.parse(asset)
        CGI.unescapeHTML(asset.dig('lyrics')).gsub(/<br>/, "\n").
                    gsub(/<p>/, "\n\n")
      else
        nil
      end
    end
  end

  class ConfigFile
    def initialize(cfile)
      @cfile = cfile
      if test(?f, @cfile)
        @content = YAML.load_file(@cfile)
      else
        @content = {}
      end
    end
  end


  class SmuleSong
    def initialize(sinfo, options={})
      @info          = sinfo
      @options       = options
      @surl          = "https://www.smule.com#{@info[:href]}"
      @audio_handler = AudioHandler.new(@surl, @options)
    end

    def [](key)
      @info[key]
    end

    def [](key, value)
      @info[key] = value
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
          @info[:deleted] = true
          spinner.stop('Done!')
          return 0
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
    
    def download_from_singsalon(ssconnect=nil, force=false)
      begin
        if @options[:force] || !test(?f, @info[:sfile])
          if ssconnect
            @audio_handler = AudioHandler.new(@surl, @options)
            unless @audio_handler.exist
              return false
            end
            Plog.info("Downloading for #{@info[:title]}")
            if @audio_handler.get_audio_from_singsalon(@info[:sfile], ssconnect)
              update_mp4tag
            end
          else
            Plog.error("Need to download song, but there is no connection")
            return false
          end
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

    def update_mp4tag
      ofile = @info[:sfile]
      cdate = @info[:created] || Time.now
      if cdate.is_a?(String)
        cdate = Time.parse(cdate)
      end
      if ofile && test(?f, ofile)
        href    = 'https://www.smule.com' + @info[:href]
        date    = cdate.strftime("%Y-%m-%d")
        album   = cdate.strftime("Smule-%Y.%m")
        artist  = @info[:record_by].gsub(',', ', ')
        aartist = @info[:record_by].gsub(/(,?)#{}(,?)/, "\1\2")
        comment = "#{date} - #{href}"
        year    = cdate.year
        title   = clean_emoji(@info[:title]).gsub(/\'/, "")

        command = "atomicparsley #{@info[:sfile]}"

        # Get the artwork
        lcfile  = File.basename(@info[:avatar])
        curl(@info[:avatar], lcfile)
        if test(?f, lcfile) && `file #{lcfile}` =~ /JPEG/
          command += " --artwork #{lcfile}"
        end
        command += " --title '#{title}'"
        command += " --artist '#{artist}'"
        command += " --album '#{album}'"
        command += " --year '#{year}'"
        command += " --comment '#{comment}'"

        if lyric = @audio_handler.get_lyric
          tmpf = Tempfile.new("lyric")
          tmpf.puts(lyric)
          tmpf.close
          l_flag = " --lyricsFile #{tmpf.path}"
        else
          l_flag = ''
        end

        output = `(set -x; #{command} --overWrite #{l_flag}) | tee /dev/tty`

        # Not enough room - try drop the lyric part
        if output =~ /insufficient space to retag the source file/io
          system("set -x; #{command}")
        end
        FileUtils.remove(lcfile, verbose:true)
        true
      else
        false
      end
    end
  end

  class API
    def initialize(options={})
      @options = options
    end

    def get_songs(url, options)
      allset    = []
      offset    = 0
      limit     = (options[:limit] || 10_000).to_i
      first_day = Time.now - (options[:days] || 7).to_i*24*3600
      bar       = TTY::ProgressBar.new("Checking songs [:bar]", total:500)
      catch(:done) do
        while true
          ourl = "#{url}?offset=#{offset}"
          bar.log(ourl) if @options[:verbose]
          result = JSON.parse(curl(ourl))
          slist  = result['list']
          slist.each do |info|
            record_by = [info.dig('owner', 'handle')]
            info['other_performers'].each do |rinfo|
              record_by << rinfo['handle']
            end
            stats   = info['stats']
            created = Time.parse(info['created_at'])
            since   = ((Time.now - created)/60).to_i
            rec     = {
              title:       info['title'],
              href:        info['web_url'],
              record_by:   _record_by_map(record_by).join(','),
              listens:     stats['total_listens'],
              loves:       stats['total_loves'],
              gifts:       stats['total_gifts'],
              since:       "#{since} min",
              avatar:      info['cover_url'],
              is_ensemble: info['child_count'].to_i > 0,
              #collab_url:  collab_url,
              sid:         info['key'],
              created:     created,
              orig_city:   (info['orig_track_city'] || {}).values.join(', '),
              media_url:   info['media_url'],
            }
            allset << rec
            if created <= first_day
              bar.log("Created less than #{first_day}")
              throw :done
            end
            throw :done if (allset.size >= limit)
          end
          offset = result['next_offset']
          throw :done if offset < 0
          bar.advance(slist.size)
        end
      end
      bar.finish
      allset
    end

    def get_performances(user, options)
      get_songs("https://www.smule.com/#{user}/performances/json", options)
    end

    def get_favs(user)
      options = {limit:10_000, days:365*10}
      get_songs("https://www.smule.com/#{user}/favorites/json", options)
    end
  end

  class Scanner
    attr_reader :spage

    def initialize(user, options={})
      @user      = user
      @options   = options
      @connector = SiteConnect.new(:smule, @options)
      @spage     = SelPage.new(@connector.driver)
      sleep(1)
      at_exit {
        @connector.close
      }
    end

    def scan_collab_list(collab_links)
      result    = []
      bar       = TTY::ProgressBar.new("Checking collabs [:bar] :percent",
                                   total:collab_links.size)
      collab_links.each do |alink|
        @spage.goto(alink)
        sitems = @spage.css(".duets.content .recording-listItem")
        sitems.each do |sitem|
          next unless sinfo = _scan_a_collab_song(sitem)
          sinfo.update(parent:alink)
          result << sinfo
        end
        bar.advance
      end
      Plog.info("Found #{result.size} songs in collabs")
      result
    end

    def set_unfavs(songs, marking=true)
      prompt = TTY::Prompt.new
      songs.each do |asong|
        @spage.goto(asong[:href])
        @spage.click_and_wait('._13ryz2x')
        @spage.click_and_wait('._117spsl')
        if marking
          tag = '#thvfavs'
          if asong[:record_by].start_with?(@user)
            msg = @spage.page.css('div._1ck56r8').text
            if msg =~ /#{tag}/
              Plog.info "Message already containing #{tag}"
              next
            end
            text = ' ' + tag
            @spage.click_and_wait("button._13ryz2x")   # ...
            content  = @spage.refresh
            editable = @spage.page.css("div._8hpz8v")[2]
            if editable && editable.text == 'Edit'
              @spage.click_and_wait("a._117spsl", 2, 1)  # Edit
              @spage.type("textarea#message", text)  # Enter tag
              @spage.click_and_wait("input#recording-save")
            else
              Plog.info "Song is not editable"
              @spage.click_and_wait("._6ha5u0", 1)
            end
            @spage.click_and_wait('button._1oqc74f')
          end
        end
      end
    end

    def unfavs_old(count, result)
      new_size  = result.size - count
      set_unfavs(result[new_size..-1])
      result[0..new_size-1]
    end

    def _scroll_to_bottom(pages=nil)
      pages ||= 50
      bar    = TTY::ProgressBar.new("Scroll to end [:bar] :percent",
                                    total:pages)
      (1..pages).each_with_index do |apage, index|
        @spage.execute_script("window.scrollBy({top:700, left:0, behaviour:'smooth'})")
        # Scroll fast, and you'll be banned.  So slowly
        sleep 1
        bar.advance
      end
      @spage.refresh
    end

    def _scan_users
      _scroll_to_bottom
      result = []
      sitems = @spage.css("._aju92n9")
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
      Plog.dump_info(user:result.size)
      result
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
        record_by:   _record_by_map(record_by).join(','),
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

  class Main < Thor
    include ThorAddition

    no_commands do
      def _ofile(afile)
        tdir  = '/Volumes/Voice/SMULE'
        odir  = tdir + "/#{afile[:record_by].split(',').sort.join('-')}"
        title = afile[:title].strip.gsub(/[\/\"]/, '-')
        ofile = File.join(odir,
                          title.gsub(/\&/, '-').gsub(/\'/, '-') + '.m4a')

        sfile = File.join(tdir, "STORE", afile[:sid] + '.m4a')
        [ofile, sfile]
      end

      def _prepare_download(flist, tdir)
        bar     = TTY::ProgressBar.new("Preparing list [:bar] :percent",
                                       total:flist.size)
        flist   = flist.select do |afile|
          afile[:ofile], afile[:sfile] = _ofile(afile)
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
          bar.advance
          if options[:force]
            true
          else
            !(test(?f, afile[:sfile]) && test(?l, afile[:ofile]))
          end
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

      def _download_list(flist, tdir, user, ssconnect=nil)
        unless flist = _prepare_download(flist, tdir)
          return 0
        end
        FileUtils.rm(Dir.glob("#{ENV['HOME']}/Downloads/*.m4a"))
        bar = TTY::ProgressBar.new("Downloading songs [:bar] :percent",
                                   total:flist.size)
        ssconnect ||= SiteConnect.new(:singsalon, options).driver
        ssconnect.goto('/smule-downloader')
        fcount = 0
        flist.each do |afile|
          if SmuleSong.new(afile, options).download_from_singsalon(ssconnect)
            fcount += 1
            system("open -g #{afile[:sfile]}") if options[:open]
          end
          bar.advance
        end
        fcount
      end

      def _connect_site(site=:smule)
        if @sconnector
          do_close = false
        else
          @sconnector = SiteConnect.new(site, options)
          do_close    = true
        end
        yield SelPage.new(@sconnector.driver)
        if do_close
          @sconnector.close
          @sconnector = nil
        end
      end

      def _collect_collabs(user, content)
        days      = (options[:days] || 30).to_i
        last_date = (Time.now - days*24*3600)
        ensembles = []
        content.content.each do |sid, cinfo|
          cdate = created_value(cinfo[:created])
          if cinfo[:href] =~ /ensembles$/ && cdate > last_date
            ensembles << cinfo
          end
        end
        if ensembles.size <= 0
          Plog.info("No collabs found in last #{days} days")
          return []
        end
        collab_urls = ensembles.sort_by{|r| created_value(r[:created])}.reverse.map{|r| r[:href]}
        result      = Scanner.new(user, writable_options).
          scan_collab_list(collab_urls)
        content.add_new_songs(result, false)
        result
      end

      def _tdir_check(tdir)
        unless test(?d, tdir)
          raise "Target dir #{tdir} not accessible to download music to"
        end
        tdir
      end

      def _collect_songs(user, content)
        limit   = (options[:limit] || 10_000).to_i
        days    = (options[:days] || 7).to_i
        sapi    = API.new(options)
        perfset = sapi.get_performances(user, limit:limit, days:days)
        content.add_new_songs(perfset, false)
        favset  = sapi.get_favs(user)
        content.add_new_songs(favset, true)
        perfset
      end
    end

    class_option :browser,  type: :string, default:'firefox',
      desc:'Browser to use (firefox|chrome)'
    class_option :skip_auth,  type: :boolean, 
      desc:'Login account from browser (not anonymous)'
    class_option :days,     type: :numeric, default:7,
      desc:'Days to look back'
    class_option :download, type: :boolean, desc:'Downloading songs'
    class_option :data_dir, type: :string, default:'./data',
      desc:'Data directory to keep data base and file'
    class_option :limit,    type: :numeric, desc:'Max # of songs to process'
    class_option :song_dir, type: :string, default:'/Volumes/Voice/SMULE',
      desc:'Data directory to keep songs (m4a)'
    class_option :force,    type: :boolean
    class_option :verbose,  type: :boolean
    class_option :open,     type: :boolean, desc: 'Opening mp4 after download'

    desc "collect_collabs user", "Collect songs others join"
    def collect_collabs(user)
      cli_wrap do
        tdir    = _tdir_check(options[:data_dir])
        content = Content.new(user, tdir)
        collabs = _collect_collabs(user, content)
        if collabs.size <= 0
          return true
        end
        _download_list(collabs, tdir, user) if options[:download]
        content.writeback
        true
      end
    end

    desc "collect_songs user", "Collect songs user join"
    def collect_songs(user)
      cli_wrap do
        tdir    = _tdir_check(options[:data_dir])
        content = Content.new(user, tdir)
        perfset = _collect_songs(user, content)
        if perfset.size <= 0
          return true
        end
        _download_list(perfset, tdir, user) if options[:download]

        # Redo since download list will setup ofile field
        content.add_new_songs(perfset, false)

        # Favs must dump the whole thing
        content.writeback
        true
      end
    end

    desc "collect_songs_and_collabs user", "Collect all songs with user"
    def collect_songs_and_collabs(user)
      cli_wrap do
        tdir     = _tdir_check(options[:data_dir])
        content  = Content.new(user, tdir)
        newsongs = _collect_songs(user, content)
        collabs  = _collect_collabs(user, content)
        if (newsongs.size) <= 0 && (collabs.size <= 0)
          return true
        end
        if options[:download]
          _download_list(newsongs + collabs, tdir, user)
        end
        content.writeback
        true
      end
    end

    desc "download_songs(user, *filters)", "download_songs"
    def download_songs(user, *filters)
      cli_wrap do
        tdir     = _tdir_check(options[:data_dir])
        content  = Content.new(user, tdir)
        to_download = []
        content.each(filter:filters.join('/')) do |sid, sinfo|
          to_download << sinfo
        end
        _download_list(to_download, tdir, user)
        content.writeback
        true
      end
    end

    desc "scan_favs user", "Scan list of favorites for user"
    def scan_favs(user)
      cli_wrap do
        tdir    = _tdir_check(options[:data_dir])
        content = Content.new(user, tdir)
        allset  = API.new.get_favs(user)
        content.add_new_songs(allset, true)
        content.writeback
      end
    end

    desc "unfavs_old user [count=10]", "Remove earliest songs of favs"
    long_desc <<-LONGDESC
      Smule has limit of 500 favs.  So once in a while we need to remove
      it to enable adding more.  The removed one will be tagged with #thvfavs
      if possible
    LONGDESC
    def unfavs_old(user, count=10)
      cli_wrap do
        tdir = _tdir_check(options[:data_dir])
        if tdir && !test(?d, tdir)
          raise "Target dir #{tdir} not accessible to download music to"
        end
        favset  = API.new.get_favs(user)
        result  = Scanner.new(user, writable_options).
          unfavs_old(count.to_i, favset)
        Content.new(user, tdir).add_new_songs(result, true).writeback if tdir
        result
      end
    end

    desc "scan_follows user", "Scan the follower/following list"
    def scan_follows(user)
      cli_wrap do
        tdir = _tdir_check(options[:data_dir])
        fset = []
        %w(following followers).each do |agroup|
          users = JSON.parse(curl("https://www.smule.com/#{user}/#{agroup}/json"))
          users = users['list'].map{|r| 
            {
              name:       r['handle'],
              avatar:     r['pic_url'],
              account_id: r['account_id'],
            }
          }
          fset << users
        end
        Content.new(user, tdir).set_follows(fset[0], fset[1]).writeback
        true
      end
    end

    desc "open_on_itune(user, *filters)", "open_on_itune"
    option :time,  type: :numeric, default:10
    def open_on_itune(user, *filters)
      cli_wrap do
        tdir     = _tdir_check(options[:data_dir])
        content  = Content.new(user, tdir)
        to_download = []
        content.each(filter:filters.join('/')) do |sid, sinfo|
          sfile = sinfo[:sfile]
          if sfile && test(?f, sfile)
            Plog.dump_info(sinfo:sinfo, _ofmt:'Y')
            system("open -g #{sfile}")
            sleep(options[:time])
          elsif sfile
            Plog.info("#{sfile} not found.  Removing the stale name")
          end
        end
        true
      end
    end

    desc "fix_mp3_files(user, *filters)", "fix_mp3_meta"
    option :open,      type: :boolean, desc:'Open after fixing to check'
    option :overwrite, type: :boolean, desc:'Open after fixing to check'
    def fix_mp3_files(user, *filters)
      cli_wrap do
        moptions = writable_options.update(
          pbar:  'Correct MP3 meta',
          force: true,
          filter: filters.join('/'),
        )
        tdir      = _tdir_check(moptions[:data_dir])
        content   = Content.new(user, tdir)
        ssconnect = SiteConnect.new(:singsalon, moptions).driver
        ssconnect.goto('/smule-downloader')
        content.each(moptions) do |sid, sinfo|
          sfile = sinfo[:sfile]
          do_download = false

          if sfile =~ /Voice-\d+/
            sfile = sinfo[:sfile] = sfile.sub(/Voice-1/, 'Voice')
          end

          if options[:overwrite]
            do_download = true
          else
            if sfile && test(?f, sfile)
              wset = `atomicparsley #{sfile} -t`.split("\n").map {|l|
                key, value = l.split(/\s+contains:\s+/)
                key = key.split[-1].gsub(/["]/, '')[1..-1].to_sym
                [key, value]
              }
              wset  = Hash[wset]
              album = sinfo[:created].strftime("Smule-%Y.%m")
              year  = sinfo[:created].strftime("%Y")
              if wset[:nam] == 'ver:1' || wset[:alb] != album || \
                  wset[:day] != year
                do_download = true
              end
            else
              do_download = true
            end
          end

          if do_download
            if _download_list([sinfo], tdir, user, ssconnect) > 0
              system("open -g #{sfile}") if moptions[:open]
            end
          end
        end
        true
      end
    end

    desc "play user", "Play songs from user"
    option :myopen,  type: :boolean, desc:'Play my opens also'
    long_desc <<-LONGDESC
      Start a CLI player to play songs from user.  Player support various
      command to control the song and how to play.

      Player keep the play state on the file splayer.state to allow it
      to resume where it left off from the previous run.
    LONGDESC
    def play(user)
      cli_wrap do
        tdir = _tdir_check(options[:data_dir])
        SmulePlayer.new(user, tdir, options).play_all
      end
    end

    desc "show_following user", "Show the activities for following list"
    def show_following(user)
      cli_wrap do
        tdir      = _tdir_check(options[:data_dir])
        content   = Content.new(user, tdir)
        following = content.singers.select{|k, v| v[:following]}
        bar = TTY::ProgressBar.new("Following [:bar] :percent",
                                   total:content.content.size)
        content.content.each do |sid, sinfo|
          singers = sinfo[:record_by].split(',')
          singers.select{|r| r != user}.each do |osinger|
            if finfo = following[osinger]
              finfo[:last_join] ||= Time.at(0)
              finfo[:last_join] = [created_value(sinfo[:created]),
                                   created_value(finfo[:last_join])].max
              finfo[:songs] ||= 0
              finfo[:songs] += 1
            end
          end
          bar.advance
        end
        following.each do |asinger, finfo|
          if finfo[:last_join]
            finfo[:last_days] = (Time.now - finfo[:last_join])/(24*3600)
          end
        end
        following.sort_by{|k, v| v[:last_days] || 9999}.each do |asinger, finfo|
          puts "%-20.20s - %3d songs, %4d days, %s" %
            [asinger, finfo[:songs] || 0, finfo[:last_days] || 9999,
             finfo[:follower] ? 'follower' : '']
        end
        true
      end
    end

    desc "fix_content user <fix_type>", "Fixing something on the database"
    long_desc <<-LONGDESC
      Just a place holder to fix data content.  Code will be implemented
      as needed
    LONGDESC
    def fix_content(user, fix_type)
      cli_wrap do
        tdir    = _tdir_check(options[:data_dir])
        content = Content.new(user, tdir)
        ccount  = 0
        cutoff  = Time.parse("2019-09-01")
        fix_type = fix_type.to_sym
        content.each do |sid, cinfo|
          case fix_type
          when :date
            unless cinfo[:created].is_a?(Time)
              cinfo[:created] = created_value(cinfo[:created])
              ccount += 1
            end
          when :record_by
            if cinfo[:record_by].is_a?(Array)
              cinfo[:record_by] = cinfo[:record_by].join(',')
              ccount += 1
            end
          when :favs
            cdate = created_value(cinfo[:created])
            if (cdate < cutoff) || !cinfo[:oldfav]
              next
            end
            Plog.dump_info(sid:sid, cdate:cdate)
            cinfo.delete(:oldfav)
          end
        end
        if ccount > 0
          Plog.info("#{ccount} records fixed")
          content.writeback
        end
      end
    end

    desc "move_singer user old_name new_name", "Move songs from old singer to new singer"
    long_desc <<-LONGDESC
      Singer changes login all the times.  That would change control data as
      well as storage folder.  This needs to run to track user
    LONGDESC
    def move_singer(user, old_name, new_name)
      cli_wrap do
        tdir    = _tdir_check(options[:data_dir])
        content = Content.new(user, tdir)
        moptions = writable_options
        moptions.update(
          pbar:   "Move content from #{old_name}",
          filter: "record_by=#{old_name}",
        )
        changed = false
        content.each(moptions) do |k, v|
          new_record_by = v[:record_by].gsub(old_name, new_name)
          if new_record_by != v[:record_by]
            v[:record_by] = new_record_by
            v[:ofile], v[:sfile] = _ofile(v)
            SmuleSong.new(v).download_from_singsalon
            changed = true
          end
        end
        content.writeback if changed
        true
      end
    end
  end
end

if (__FILE__ == $0)
  SmuleAuto::Main.start(ARGV)
end

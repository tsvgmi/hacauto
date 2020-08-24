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
require 'smule-db'
require 'smule_song'

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
  stitle.strip
end

def curl(path, ofile=nil)
  cmd = 'curl -s -H "User-Agent: Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:59.0) Gecko/20100101 Firefox/59.0"'
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

  class API
    def initialize(options={})
      @options = options
    end

    def get_songs(url, options)
      allset    = []
      offset    = 0
      limit     = (options[:limit] || 10_000).to_i
      first_day = Time.now - (options[:days] || 7).to_i*24*3600
      bar       = TTY::ProgressBar.new("Checking songs [:bar] :percent",
                                       total:100)
      catch(:done) do
        while true
          ourl = "#{url}?offset=#{offset}"
          bar.log(ourl) if @options[:verbose]
          output = curl(ourl)
          if output == 'Forbidden'
            sleep 2
            next
          end
          result = JSON.parse(output)
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
              avatar:      info['cover_url'],
              is_ensemble: info['child_count'].to_i > 0,
              sid:         info['key'],
              created:     created,
              orig_city:   (info['orig_track_city'] || {}).values.join(', '),
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
      progress_set(collab_links, "Checking collabs") do |alink, bar|
        @spage.goto(alink)
        sitems = @spage.css(".duets.content .recording-listItem")
        sitems.each do |sitem|
          next unless sinfo = _scan_a_collab_song(sitem)
          sinfo.update(parent:alink)
          result << sinfo
        end
        true
      end
      Plog.info("Found #{result.size} songs in collabs")
      result
    end

    def scan_songs
      @spage.goto(@user)
      _scan_songs
    end

    def scan_favs
      @spage.goto(@user)
      @spage.click_and_wait('._16qibwx:nth-child(3)')
      _scan_songs(100)
    end

    def _scan_songs(pages=nil)
      pages ||= (@options[:pages] || 100).to_i
      result = []
      _each_main_song(pages) do |sitem|
        if sentry = _scan_a_main_song(sitem)
          result << sentry
        end
      end
      result
    end

    def _each_main_song(pages)
      _scroll_to_bottom(pages)
      sitems       = @spage.css("._8u57ot")
      result       = []
      collab_links = []
      progress_set(sitems, "Checking songs") do |sitem, bar|
        plink = sitem.css('a._1sgodipg')[0]
        next unless plink
        next if sitem.css('._1wii2p1').size <= 0
        yield sitem
        true
      end
    end

    def _scan_a_main_song(sitem)
      plink = sitem.css('a._1sgodipg')[0]
      if !plink || (sitem.css('._1wii2p1').size <= 0)
        return nil
      end
      since       = sitem.css('._1wii2p1')[2].text
      record_by   = nil
      is_ensemble = false
      if collabs = sitem.css('a._api99xt')[0]
        href = collabs['href']
        if href =~ /ensembles$/
          is_ensemble = true
          record_by   = [@user]
        end
      end
      unless record_by
        s1        = sitem.css('._1iurgbx')[0]
        s1        = s1 ? s1.text.strip : nil
        s2        = sitem.css('._1iurgbx')[1]
        s2        = s2 ? s2.text.strip : nil
        record_by = [s1, s2].compact
      end
      phref    = plink['href'].split('/')
      sid      = phref[-1] == 'ensembles' ? phref[-2] : phref[-1]
      created  = Time.now - time_since(since)
      title    = clean_emoji(plink.text).strip
      {
        title:       title,
        href:        plink['href'],
        record_by:   _record_by_map(record_by).join(','),
        listens:     sitem.css('._1wii2p1')[0].text.to_i,
        loves:       sitem.css('._1wii2p1')[1].text.to_i,
        avatar:      (sitem.css('img')[0] || {})['src'],
        is_ensemble: is_ensemble,
        sid:         sid,
        created:     created,
      }
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
      progress_set(1..pages, "Scroll to end") do |apage, bar|
        @spage.execute_script("window.scrollBy({top:700, left:0, behaviour:'smooth'})")
        # Scroll fast, and you'll be banned.  So slowly
        if block_given?
          @spage.refresh
          unless yield
            break
          end
        end
        sleep 1
        true
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
      def _ofile(sinfo)
        tdir  = '/Volumes/Voice/SMULE'
        odir  = tdir + "/#{sinfo[:record_by].split(',').sort.join('-')}"
        title = sinfo[:title].strip.gsub(/[\/\"]/, '-')
        ofile = File.join(odir,
                          title.gsub(/\&/, '-').gsub(/\'/, '-') + '.m4a')

        sfile = File.join(tdir, "STORE", sinfo[:sid] + '.m4a')
        [ofile, sfile]
      end

      def _prepare_download(flist, tdir)
        newlist = []
        progress_set(flist, "Preparing download") do |afile, bar|
          afile[:ofile], afile[:sfile] = _ofile(afile)
          odir          = File.dirname(afile[:ofile])
          FileUtils.mkdir_p(odir, verbose:@options[:verbose]) unless test(?d, odir)
          begin
            if test(?f, afile[:ofile]) && !test(?l, afile[:ofile])
              FileUtils.move(afile[:ofile], afile[:sfile],
                             verbose:@options[:verbose], force:true)
              FileUtils.symlink(afile[:sfile], afile[:ofile],
                                verbose: @options[:verbose], force:true)
            end
          rescue ArgumentError => errmsg
            Plog.dump_error(errmsg:errmsg, sfile:afile[:sfile],
                            ofile:afile[:ofile])
          end
          do_download = if options[:force]
            true
          else
            !(test(?f, afile[:sfile]) && test(?l, afile[:ofile]))
          end
          newlist << afile if do_download
          true
        end
        flist = newlist
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

      def _open_song(sinfo)
        if options[:open]
          system("set -x; open -g #{sinfo[:sfile]}")
          sleep(2)
        end
      end

      def _download_list(flist, tdir, user)
       flist = _prepare_download(flist, tdir)
       if !flist || (flist.size <= 0)
          return 0
        end
        FileUtils.rm(Dir.glob("#{ENV['HOME']}/Downloads/*.m4a"))
        ssconnect = SiteConnect.new(:singsalon, options).driver
        ssconnect.goto('/smule-downloader')
        fcount = 0
        progress_set(flist, "Downloading songs") do |afile, bar|
          if SmuleSong.new(afile, options).
              download_from_singsalon(ssconnect, excuser:user)
            fcount += 1
            _open_song(afile)
          end
          true
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
        days        = (options[:days] || 30).to_i
        last_date   = (Time.now - days*24*3600)
        collab_list = Performance.
          where(Sequel.like(:href, '%/ensembles')).
          where(created:Date.today-days..Date.today).
          reverse(:created)
        if collab_list.count <= 0
          Plog.info("No collabs found in last #{days} days")
          return []
        end
        if true
          result = []
          progress_set(collab_list, "Checking collabs") do |sinfo, bar|
            result.concat(SmuleSong.new(sinfo, options).get_ensemble_asset)
            true
          end
        else
          collab_urls = collab_list.map(:href)
          result      = Scanner.new(user, writable_options).
            scan_collab_list(collab_urls)
          content.add_new_songs(result, false)
        end
        result
      end

      def _tdir_check(tdir)
        unless test(?d, tdir)
          raise "Target dir #{tdir} not accessible to download music to"
        end
        tdir
      end

      def _collect_songs(user, content)
        limit = (options[:limit] || 10_000).to_i
        days  = (options[:days] || 7).to_i
        if options[:use_api]
          sapi    = API.new(options)
          perfset = sapi.get_performances(user, limit:limit, days:days)
          content.add_new_songs(perfset, false)
        else
          scanner = Scanner.new(user, writable_options)
          perfset = scanner.scan_songs
          content.add_new_songs(perfset, false)
        end
        perfset
      end

      def song_content(user, tdir)
        SmuleDB.instance(user, tdir)
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
    class_option :pages,    type: :numeric, default:10,
      desc:'Pages to scan'
    class_option :verbose,  type: :boolean
    class_option :open,     type: :boolean, desc: 'Opening mp4 after download'
    class_option :use_api,  type: :boolean, default:true

    desc "collect_songs user", "Collect all songs and collabs of user"
    option :with_collabs,  type: :boolean
    def collect_songs(user)
      cli_wrap do
        tdir     = _tdir_check(options[:data_dir])
        content  = song_content(user, tdir)
        newsongs = _collect_songs(user, content)
        if options[:with_collabs]
          newsongs.concat(_collect_collabs(user, content))
        end
        if (newsongs.size) <= 0
          return true
        end
        if options[:download]
          _download_list(newsongs, tdir, user)
          content.add_new_songs(newsongs, false)
        end
        true
      end
    end

    desc "download_songs(user, *filters)", "download_songs"
    def download_songs(user, *filters)
      cli_wrap do
        tdir     = _tdir_check(options[:data_dir])
        content  = song_content(user, tdir)
        to_download = []
        content.each(filter:filters.join('/')) do |sid, sinfo|
          to_download << sinfo
        end
        _download_list(to_download, tdir, user)
        true
      end
    end

    desc "scan_favs user", "Scan list of favorites for user"
    def scan_favs(user)
      cli_wrap do
        tdir    = _tdir_check(options[:data_dir])
        content = song_content(user, tdir)
        if options[:use_api]
          favset = API.new.get_favs(user)
        else
          favset = Scanner.new(user, writable_options).scan_favs
        end
        content.add_new_songs(favset, true)
        true
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
        tdir    = _tdir_check(options[:data_dir])
        content = song_content(user, tdir)
        if options[:use_api]
          favset  = API.new.get_favs(user)
        else
          favset = content.select_set(:isfav, true).
            sort_by{|r| created_value(r[:created])}.reverse
        end
        result  = Scanner.new(user, writable_options).
          unfavs_old(count.to_i, favset)
        song_content(user, tdir).add_new_songs(result, true) if tdir
        true
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
        song_content(user, tdir).set_follows(fset[0], fset[1])
        true
      end
    end

    desc "open_on_itune(user, *filters)", "open_on_itune"
    option :open,  type: :boolean, default:true
    def open_on_itune(user, *filters)
      cli_wrap do
        tdir     = _tdir_check(options[:data_dir])
        content  = song_content(user, tdir)
        to_download = []
        content.each(filter:filters.join('/')) do |sid, sinfo|
          sfile = sinfo[:sfile]
          if sfile && test(?f, sfile)
            Plog.dump_info(sinfo:sinfo, _ofmt:'Y')
            _open_song(sinfo)
          elsif sfile
            Plog.info("#{sfile} not found.  Removing the stale name")
          end
        end
        true
      end
    end

    desc "fix_mp3_files(user, *filters)", "fix_mp3_meta"
    option :open,      type: :boolean, desc:'Open after fixing to check'
    option :overwrite, type: :boolean,
      desc:'Redownload and overwrite existing file'
    long_desc <<-LONGDESC
Check and add in metadata to mp3 file if missing.  Sometimes website changes
attributes so we could not get the metadata and create raw mp3 file. This
should be reran after fix to insure the metadata is saved into the file

metadata look like could be written only once. So if it was written wrongly
before, you'd need to use --overwrite to force download a fresh copy again
    LONGDESC
    def fix_mp3_files(user, *filters)
      cli_wrap do
        moptions = writable_options.update(
          pbar:  'Correct MP3 meta',
          force: true,
          filter: filters.join('/'),
        )
        tdir      = _tdir_check(moptions[:data_dir])
        content   = song_content(user, tdir)
        dl_list   = []
        content.each(moptions) do |sid, sinfo|
          sfile = sinfo[:sfile]

          if sfile =~ /Voice-\d+/
            sfile = sinfo[:sfile] = sfile.sub(/Voice-1/, 'Voice')
          end

          rcode = SmuleSong.new(sinfo, moptions).update_mp4tag(user)
          if rcode == :updated
            _open_song(sinfo)
            next
          elsif rcode == :notfound || rcode == :error
            [:ofile, :sfile].each do |afile|
              if test(?f, sinfo[afile])
                FileUtils.remove(sinfo[afile], verbose:true, force:true)
              end
            end
            dl_list << sinfo
          end
        end
        _download_list(dl_list, tdir, user)
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
        content   = song_content(user, tdir)
        following = content.singers.select{|k, v| v[:following]}
        bar = TTY::ProgressBar.new("Following [:bar] :percent",
                                   total:Performance.size)
        Performance.each do |sid, sinfo|
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
        tdir     = _tdir_check(options[:data_dir])
        content  = song_content(user, tdir)
        fix_type = fix_type.to_sym
        ccount   = 0
        SmuleDB.instance(user)
        case fix_type
        when :stitle
          query  = Performance.where(stitle:nil)
          ccount = query.count
          query.each do |r|
            stitle = to_search_str(r[:title])
            r.update(stitle:stitle)
          end
        when :sfile
          query   = Performance.where(sfile:nil)
          ccount  = query.count
          dl_list = []
          query.each do |r|
            ofile, sfile = _ofile(r)
            if !test(?f, sfile) || !test(?f, ofile)
              Plog.error("#{sfile} or #{ofile} does not exist")
              dl_list << r
              next
            end
            r.update(sfile:sfile, ofile:ofile)
          end
          _download_list(dl_list, tdir, user)
        end
        Plog.info("#{ccount} records fixed")
        ccount
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
        content = song_content(user, tdir)
        moptions = writable_options
        moptions.update(
          pbar:   "Move content from #{old_name}",
          filter: "record_by=#{old_name}",
        )
        Performance.
          where(Sequel.like(:record_by, "%#{old_name}%")).each do |v|
          new_record_by = v[:record_by].gsub(old_name, new_name)
          if new_record_by != v[:record_by]
            ofile, sfile = _ofile(v)
            v.update(record_by:new_record_by, ofile:ofile, sfile:sfile)
            SmuleSong.new(v, options).download_from_singsalon(nil, excuser:user)
          end
        end
        true
      end
    end

    desc "smule_song_info(url)", "smule_song_info"
    def smule_song_info(url)
      cli_wrap do
        SmuleDB.instance("THV_13", ".")
        surl = url.sub(%r{^https://www.smule.com}, '')
        sinfo = Performance.first(href:surl) || Performance.new(href:surl)
        song  = SmuleSong.new(sinfo, options)
        if url =~ /ensembles$/
          song.get_ensemble_asset
        else
          song.get_asset
        end.to_yaml
      end
    end

   desc "curl(url)", "curl"
   def do_curl(url)
      cli_wrap do
        curl(url)
      end
    end
  end
end

if (__FILE__ == $0)
  SmuleAuto::Main.start(ARGV)
end

#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        smuleauto.rb
# Date:        2021-01-01 22:13:22 -0800
# $Id$
#---------------------------------------------------------------------------
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
  stitle.gsub(/\s+/, ' ').strip
end

def curl(path, ofile=nil)
  cmd = 'curl -s -H "User-Agent: Mozilla/5.0 (Windows NT 6.1; Win64; x64; rv:59.0) Gecko/20100101 Firefox/59.0"'
  cmd += " -o #{ofile}" if ofile
  `#{cmd} '#{path}'`
end

def time_since(since)
  case since
  when /(min|m)$/
    since.to_i * 60.0
  when /hr?$/
    since.to_i * 3600
  when /d$/
    since.to_i * 24*3600
  when /mo$/
    since.to_i * 24 * 30 * 3600
  when /yr$/
    since.to_i * 24 * 365 * 3600
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
  'Annygermany'   => 'Nai_Anh_Anh',
  'Eddy2020_'     => 'Mina_________',
  '_Huong'        => '__HUONG',
  '__MinaTrinh__' => 'Mina_________',
  'tim_chet'      => 'ngotngao_mantra',
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
      if test('f', @cfile)
        @content = YAML.safe_load_file(@cfile)
      else
        @content = {}
      end
    end
  end

  class API
    def initialize(options={})
      @options = options
      @logger  = options[:logger] || PLogger.new($stderr)
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
            rec     = {
              title:       info['title'],
              stitle:      to_search_str(info['title']),
              href:        info['web_url'],
              record_by:   _record_by_map(record_by).join(','),
              listens:     stats['total_listens'],
              loves:       stats['total_loves'],
              gifts:       stats['total_gifts'],
              avatar:      info['cover_url'],
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
      @logger.info("Getting performances for #{user}")
      get_songs("https://www.smule.com/#{user}/performances/json", options)
    end

    def get_favs(user)
      @logger.info("Getting favorites for #{user}")
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
      @spage     = SmulePage.new(@connector.driver)
      @logger    = options[:logger] || PLogger.new($stderr)
      sleep(1)
      at_exit {
        @connector.close
      }
    end

    def star_set(song_set, count)
      stars = []
      song_set.each do |sinfo|
        href = sinfo[:href]
        next if href =~ /ensembles$/
        next if sinfo[:record_by].include?(@user)
        next if Love.first(sid: sinfo[:sid], user:@user)
        if @options[:exclude]
          next if @options[:exclude].find{ |r| sinfo[:record_by] =~ /#{r}/}
        end
        begin
          if @spage.star_song(sinfo[:href])
            @logger.info("Marking #{sinfo[:stitle]} (#{sinfo[:record_by]})")
            stars << sinfo
            if @options[:pause]
              sleep(1)
              @spage.toggle_play(true)
              sleep(@options[:pause])
            end
            count -= 1
            if count <= 0
              break
            end
          end
          Love.insert(sid: sinfo[:sid], user:@user)
        rescue => errmsg
          Plog.error(errmsg)
        end
      end
      stars
    end

    def set_unfavs(songs, marking=true)
      songs.each do |asong|
        @spage.goto(asong[:href])
        @spage.set_song_favorite(false)
        @spage.set_song_tag('#thvfavs') if marking
        @logger.dump_info(msg:'Unfav', stitle: asong[:stitle], record_by: asong[:record_by])
      end
    end

    def unfavs_old(count, result)
      new_size = result.size - count
      set_unfavs(result[new_size..-1])
      result[0..new_size-1]
    end
  end

  class Main < Thor
    include ThorAddition

    no_commands do
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

      def _tdir_check
        if (sdir = options[:song_dir]).nil?
          raise "Target dir #{sdir} not accessible to download music to"
        end
        SmuleSong.song_dir = sdir

        ddir = options[:data_dir]
        unless test('d', ddir)
          raise "Target dir #{ddir} not accessible to keep database in"
        end
      end

      def _collect_songs(user, content)
        limit = options[:limit]
        days  = options[:days]
        sapi    = API.new(options)
        perfset = sapi.get_performances(user, limit: limit, days: days)
        content.add_new_songs(perfset, false)
        perfset
      end
    end

    class_option :browser,  type: :string, default:'firefox',
      desc:'Browser to use (firefox|chrome)'
    class_option :data_dir, type: :string, default:'./data',
      desc:'Data directory to keep database'
    class_option :days,     type: :numeric, default:7,
      desc:'Days to look back'
    class_option :force,    type: :boolean
    class_option :limit,    type: :numeric, desc:'Max # of songs to process',
      default:10_000
    class_option :logfile,  type: :string
    class_option :skip_auth,  type: :boolean, 
      desc:'Login account from browser (not anonymous)'
    class_option :song_dir, type: :string, default:'/Volumes/Voice/SMULE',
      desc:'Data directory to keep songs (m4a)'
    class_option :verbose,  type: :boolean

    desc "collect_songs user", "Collect all songs and collabs of user"
    option :with_collabs,  type: :boolean
    def collect_songs(user)
      cli_wrap do
        _tdir_check
        content  = SmuleDB.instance(user, options[:data_dir])
        newsongs = _collect_songs(user, content)
        content.add_new_songs(newsongs, false)
        if options[:with_collabs]
          newsongs = SmuleSong.collect_collabs(user, options[:days])
          content.add_new_songs(newsongs, false)
        end
        true
      end
    end

    desc "scan_favs user", "Scan list of favorites for user"
    def scan_favs(user)
      cli_wrap do
        _tdir_check
        content = SmuleDB.instance(user, options[:data_dir])
        favset  = API.new.get_favs(user)
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
        _tdir_check
        content  = SmuleDB.instance(user, options[:data_dir])
        favset   = API.new.get_favs(user)
        woptions = writable_options
        woptions[:logger] = @logger
        result  = Scanner.new(user, woptions).unfavs_old(count.to_i, favset)
        content.add_new_songs(result, true)
        true
      end
    end

    desc "scan_follows user", "Scan the follower/following list"
    def scan_follows(user)
      cli_wrap do
        _tdir_check
        fset = []
        %w(following followers).each do |agroup|
          users = JSON.parse(curl("https://www.smule.com/#{user}/#{agroup}/json"))
          users = users['list'].map { |r| 
            {
              name:       r['handle'],
              avatar:     r['pic_url'],
              account_id: r['account_id'],
            }
          }
          fset << users
        end
        SmuleDB.instance(user, options[:data_dir]).set_follows(fset[0], fset[1])
        true
      end
    end

    desc "check_follows(user)", "check_follows"
    def check_follows(user)
      cli_wrap do
        fset    = {}
        api     = API.new
        options = {limit:25, days:365*10}
        users   = JSON.parse(curl("https://www.smule.com/#{user}/followers/json"))
        users['list'].each do |r| 
          fuser = r['handle']
          slist = api.get_songs("https://www.smule.com/#{fuser}/performances/json", options)
          fset[fuser] = slist.size
          @logger.info(user: fuser, size: slist.size)
          sleep(0.5)
        end
        fset.to_yaml
      end
    end

    desc "open_on_itune(user, *filters)", "Open songs on iTunes"
    long_desc <<-LONGDESC
Open the songs on itunes.  This is done to force itune to refresh the MP3
header and update its database.
Filters is the list of SQL's into into DB.
    LONGDESC
    def open_on_itune(user, *filters)
      cli_wrap do
        _tdir_check
        content = SmuleDB.instance(user, options[:data_dir])
        content.each(filter: filters.join('/')) do |_sid, sinfo|
          song = SmuleSong.new(sinfo)
          sfile = song.ssfile
          if sfile && test('f', sfile)
            @logger.dump_info(sinfo: sinfo, _ofmt:'Y')
            system("set -x; open -g #{sfile}")
            sleep(1)
          elsif sfile
            @logger.dump_error(msg:"#{sfile} not found", sinfo: sinfo)
          end
        end
        true
      end
    end

    desc "play user", "Play songs from user"
    option :download,  type: :boolean, desc:'Download while playing'
    long_desc <<-LONGDESC
Start a CLI player to play songs from user.  Player support various command to
control the song and how to play.

Player keep the play state on the file splayer.state to allow it to resume where
it left off from the previous run.
    LONGDESC
    def play(user)
      cli_wrap do
        _tdir_check
        SmulePlayer.new(user, options[:data_dir], options).play_all
      end
    end

    desc "show_following user", "Show the activities for following list"
    def show_following(user)
      cli_wrap do
        _tdir_check
        content   = SmuleDB.instance(user, options[:data_dir])
        following = content.singers.where(following: true).as_hash(:name)
        bar = TTY::ProgressBar.new("Following [:bar] :percent",
                                   total: Performance.count)
        Performance.where(Sequel.lit('record_by like ?', "%#{user}%")).
                          each do |sinfo|
          singers = sinfo[:record_by].split(',')
          singers.select { |r| r != user }.each do |osinger|
            unless (finfo = following[osinger]).nil?
              finfo[:last_join] ||= Time.at(0)
              finfo[:last_join] = [created_value(sinfo[:created]),
                                   created_value(finfo[:last_join])].max
              finfo[:songs] ||= 0
              finfo[:songs] += 1

              if sinfo[:isfav] || sinfo[:oldfav]
                finfo[:favs] ||= 0
                finfo[:favs] += 1
              end
            end
          end
          bar.advance
        end
        following.each do |_asinger, finfo|
          if finfo[:last_join]
            finfo[:last_days] = (Time.now - finfo[:last_join])/(24*3600)
          end
        end
        following.sort_by { |_k, v| v[:last_days] || 9999 }.each do |asinger, finfo|
          puts "%-20.20s - %3d songs, %3d favs, %4d days, %s" %
            [asinger, finfo[:songs] || 0,
             finfo[:favs] || 0,
             finfo[:last_days] || 9999,
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
    def fix_content(user, fix_type, *data)
      cli_wrap do
        _tdir_check
        content = SmuleDB.instance(user, options[:data_dir])
        ccount   = 0
        SmuleDB.instance(user)
        case fix_type.to_sym
        when :mp3, :m4a
          content.each(filter: data.join('/')) do |_sid, sinfo|
            asong = SmuleSong.new(sinfo)
            if asong.update_mp4tag(user) == :updated
              asong._run_command("open -g #{asong.ssfile}")
            end
          end
        when :tags
          if data.size <= 1
            @logger.error("No data specified for tag")
            return false
          end
          recs   = []
          filter = "stitle like '%#{data.shift}%'"
          content.each(filter: filter) do |_sid, r|
            recs << r
          end
          ccount = content.add_tag(recs, data.join(','))
        when :stitle
          query  = Performance.where(stitle: nil)
          ccount = query.count
          query.each do |r|
            stitle = to_search_str(r[:title])
            r.update(stitle: stitle)
          end
        when :favs
          query  = Performance.where(isfav:1, oldfav:1)
          ccount = query.count
          query.each do |r|
            r.update(oldfav:0)
          end
        when :slink
          query  = Performance.where(created: Time.now-80*24*3600..Time.now).
            where(Sequel.ilike(:record_by, "%#{user}%"))
          ccount = query.count
          progress_set(query.all, "symlink") do |r|
            SmuleSong.new(r).sofile
          end
        end
        @logger.info("#{ccount} records fixed")
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
        _tdir_check
        SmuleDB.instance(user, options[:data_dir])
        moptions = writable_options
        moptions.update(
          pbar:   "Move content from #{old_name}",
          filter: "record_by=#{old_name}",
        )
        Performance.
          where(Sequel.ilike(:record_by, "%#{old_name}%")).each do |v|
          if v[:record_by] =~ /,#{old_name}$|^#{old_name},/
            asong = SmuleSong.new(v, moptions)
            if asong.move_song(old_name, new_name)
              if asong.update_mp4tag(user) == :updated
                asong._run_command("open -g #{asong.ssfile}")
              end
            end
            v.save
          end
        end
        true
      end
    end

    desc "song_info url", "Get the song info from URL and update into database"
    option :update,  type: :boolean, desc:'Updating database'
    long_desc <<-LONGDESC
Check the URL's and update into database
Done if any downloaded files are missed or processed incorrectly
Filters is the list of SQL's into into DB.
    LONGDESC
    def song_info(url)
      cli_wrap do
        SmuleDB.instance("THV_13", ".")
        SmuleSong.update_from_url(url, options).to_yaml
      end
    end

    desc "to_open(user)", "Show list of potential to open songs"
    option :tags,  type: :string
    option :favs,  type: :boolean, default: true
    option :title, type: :string
    option :record_by, type: :string
    long_desc <<-LONGDESC
List the candidates for open from the matching filter.
Filters is the list of SQL's into into DB.
* Song which has not been opened
* Was a favorites
* Sorted by date
    LONGDESC
    def to_open(user, *filter)
      cli_wrap do
        _tdir_check
        SmuleDB.instance(user, options[:data_dir])
        wset    = Performance.where(record_by: user)
        opened  = {}
        wset.all.each do |r|
          opened[r[:stitle]] = true
        end

        wset = Performance.where(Sequel.lit('record_by like ?', "%#{user}%"))
        wset = wset.order(:created).
          join_table(:left, :song_tags, name: :stitle)

        if filter.size > 0
          wset = wset.where(Sequel.lit(filter.join(' ')))
        end
        wset = wset.where(Sequel.lit('isfav = 1 or oldfav = 1')) if options[:fav]
        unless (value = options[:tags]).nil?
          wset = wset.where(Sequel.lit('tags like ?', "%#{value}%"))
        end
        unless (value = options[:record_by]).nil?
          wset = wset.where(Sequel.lit('record_by like ?', "%#{value}%"))
        end

        unless (title = options[:title]).nil?
          wset = wset.where(Sequel.lit('stitle like ?', "%#{title}%"))
        end

        Plog.dump(wset: wset)
        topen = {}
        wset.all.each do |r|
          next if opened[r[:stitle]]

          topen[r[:stitle]] = [r[:created], r[:tags]]
        end
        table = []
        topen.sort_by { |_k, v| v[0] }.each do |name, sinfo|
          table << [sinfo[0], name, sinfo[1]]
        end
        print_table(table)
        true
      end
    end

    desc "dump_comment(user)", "dump_comment"
    def dump_comment(user, *filter)
      cli_wrap do
        _tdir_check
        SmuleDB.instance(user, options[:data_dir])
        wset    = Comment.where(Sequel.lit("record_by like '%#{user}%'"))
        if filter.size > 0
          wset = wset.where(Sequel.lit(filter.join(' ')))
        end
        wset.all.map { |r| r.values }.to_yaml
        wset.each do |sinfo|
          comments = JSON.parse(sinfo[:comments]).
            select { |_c, m| m && !m.empty? }
          if comments.size > 0
            puts "\n%-60.60s %20.20s %s" %
              [sinfo[:stitle], sinfo[:record_by], sinfo[:created]]
            comments.each do |cuser, msg|
              puts "  %-14.14s | %s" % [cuser, msg]
            end
          end
        end
        true
      end
    end

    desc "star_singers(count, singers)", "star_singers"
    option :top,     type: :numeric
    option :days,    type: :numeric, default:15
    option :exclude, type: :string
    option :pause,   type: :numeric, default:5
    option :play,    type: :boolean
    option :offset,  type: :numeric, default:0

    BannedList = %w[Joseph_TN]
    def star_singers(user, count, *singers)
      cli_wrap do
        _tdir_check
        woptions = writable_options
        content = SmuleDB.instance(user, woptions[:data_dir])
        unless (exclude = woptions[:exclude]).nil?
          exclude = exclude.split(',')
        else
          exclude = []
        end
        woptions[:exclude] = exclude
        unless (topc = woptions[:top]).nil?
          topc += exclude.size
          singers = content.top_partners(topc, woptions).
            map    { |k, _v| k }[options[:offset]..-1].
            select { |r| !exclude.include?(r) }
          @logger.dump_info(singers: singers)
        end
        limit    = woptions[:limit]
        days     = woptions[:days]
        sapi     = API.new(woptions)

        woptions[:logger] = @logger
        scanner  = Scanner.new(user, woptions)

        count   = count.to_i
        allsets = []
        singers.each do |asinger|
          perfset = sapi.get_performances(asinger, limit:[limit, 30].min,
                                          days: days)
          perfset = perfset.select do |r|
            (r[:record_by].split(',') & BannedList).size == 0
          end
          starred = scanner.star_set(perfset, count)
          allsets.concat(starred)
        end
        count = {}
        allsets.each do |sinfo|
          sinfo[:record_by].split(',').each do |singer|
            count[singer] ||= 0
            count[singer] += 1
          end
        end
        table = []
        count.to_a.sort_by { |_u, c| c }.each do |u, c|
          table << [u, c]
        end
        print_table(table)
        true
      end
    end

    desc "watch_mp4(dir)", "watch_mp4"
    option :verify,  type: :boolean
    option :open,    type: :boolean, desc: 'Opening mp4 after download'
    option :logfile, type: :string
    def watch_mp4(dir, user, csong_file='cursong.yml')
      cli_wrap do
        woptions = writable_options
        unless (value = woptions[:logfile]).nil?
          woptions[:logger] = PLogger.new(value)
        end
        FirefoxWatch.new(user, dir, csong_file, woptions).start
        sleep
      end
    end
  end
end

if (__FILE__ == $0)
  SmuleAuto::Main.start(ARGV)
end


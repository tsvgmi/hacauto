#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hacauto.rb
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
require 'smule_player'
require 'tty-spinner'

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

    def get_audio_from_singsalon(ofile, ssconnect)
      ssconnect.type('input.downloader-input', @olink)
      ssconnect.click_and_wait('input.ipsButton[value~=Fetch]')
      ssconnect.click_and_wait('a.ipsButton[download]')

      while true
        m4file = Dir.glob("#{ENV['HOME']}/Downloads/*.m4a").
          sort_by{|r| File.mtime(r)}.last
        break if m4file
        sleep(1)
      end

      Plog.info("Waiting for #{m4file}")
      while (fsize = File.size(m4file)) < 1_000_000
        sleep(1)
      end
      File.open(ofile, 'wb') do |f|
        f.write(File.read(m4file))
      end
      Plog.info("Wrote #{ofile}(#{File.size(ofile)} b) from #{@link}")
    end

    def get_audio(ofile)
      if @link
        if false
          # This trigger IP ban.
          audio = HTTP.follow.get(@link)
          File.open(ofile, 'wb') do |f|
            f.write(audio.body)
          end
          Plog.info("Wrote #{ofile} from #{@link}.  Wait a bit")
          sleep(5+rand(5))
        else
          Plog.info(audio_link:@link)
        end
        true
      else
        Plog.error("No audio file found previously")
        false
      end
    end

    def get_lyric
      unless @song_info_url
        return nil
      end

      # Continue may get banned
      if true
        sdoc  = Nokogiri::HTML(curl(@song_info_url))
        asset = sdoc.css('head script')[0].text.split("\n").grep(/Song:/)[0].
          sub(/^\s*Song: /, '')[0..-2]
        CGI.unescapeHTML(JSON.parse(asset).dig('lyrics')).
                    gsub(/<br>/, "\n").
                    gsub(/<p>/, "\n\n")
      else
        Plog.info(info_link:@song_info_url)
        return nil
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

  class Content
    attr_reader :content, :singers, :tags

    def initialize(user, cdir='.')
      @user     = user
      @cdir     = cdir
      @cfile    = "#{cdir}/content-#{user}.yml"
      @sfile    = "#{cdir}/singers-#{user}.yml"
      @tagfile = "#{cdir}/songtags2.yml"
      @loaded   = Time.at(0)
      refresh
    end

    def select_sids(sids)
      @content.select{|k, v| sids.include?(k)}.values
    end

    def select_set(ftype, value)
      newset = []

      if ftype == :recent
        days = value.to_i
        days = 7 if days <= 0
        ldate  = Time.now - days*24*3600
      end
      Plog.dump_info(ftype:ftype, value:value)
      if ftype == :url
        if result = @content.find{|k, v| v[:href] == value}
          newset = [result[1]]
        end
      else
        @content.each do |k, v|
          case ftype
          when :favs
            newset << v if (v[:isfav] || v[:oldfav])
          when :record_by
            newset << v if v[:record_by].downcase.include?(value.downcase)
          when :title
            newset << v if v[:stitle].include?(value.downcase)
          when :recent
            newset << v if created_value(v[:created]) >= ldate
          when :star
            newset << v if v[:stars].to_i >= value.to_i
          end
        end
      end
      Plog.info("Selecting #{newset.size} songs")
      newset
    end

    def refresh
      if File.mtime(@cfile) <= @loaded
        Plog.info("File #{@cfile} was not changed. Skip")
        return
      end
      if test(?s, @cfile)
        @content = YAML.load_file(@cfile)
      else
        Plog.warn("#{@cfile} does not exist or empty")
        @content = {}
      end
      @content.each do |k, r|
        r[:sincev] = time_since(r[:since]) / 3600.0
      end
      @singers = test(?f, @sfile) ? YAML.load_file(@sfile) : {}
      @tags    = {}
      if test(?f, @tagfile)
        File.open(@tagfile) do |fid|
          while l = fid.gets
            begin
              k, v = l.chomp.split(':::')
              if v && !v.empty?
                @tags[k] = v.split(',')
              end
            rescue => errmsg
              Plog.dump_error(errmsg:errmsg.to_s, l:l)
            end
          end
        end
      end
      @loaded = Time.now
    end

    def following
      @singers.select{|k, v| v[:following]}
    end

    def follower
      @singers.select{|k, v| v[:follower]}
    end

    def _write_with_backup(mfile, content, options={})
      wset = [mfile]
      if options[:backup]
        wset << File.join('/Volumes/Voice/SMULE', File.basename(mfile))
      end
      wset.uniq.each do |afile|
        b2file = afile + ".bak"
        if test(?f, afile)
          FileUtils.move(afile, b2file, verbose:true)
        end
        begin
          File.open(afile, 'w') do |fod|
            Plog.info("Writing #{content.size} entries to #{afile}")
            case options[:format]
            when :text
              fod.puts content
            else
              fod.puts content.to_yaml
            end
          end
        rescue Errno::ENOENT => errmsg
          Plog.dump_error(file:afile, errmsg:errmsg)
        end
      end
    end

    def writeback(backup=true)
      if File.mtime(@cfile) > @loaded
        Plog.error("File #{@cfile} was updated after load - #{@loaded}")
      end

      @content = @content.select do |sid, asong|
        !asong[:deleted]
      end
      @content.each do |sid, asong|
        stitle = to_search_str(asong[:title])
        asong[:stitle] ||= stitle
      end
      woption = {format: :yaml, backup: backup}
      _write_with_backup(@cfile, @content, woption)
      _write_with_backup(@sfile, @singers, woption) if @schanged
      @loaded   = Time.now

      newsong = false
      @content.each do |sid, asong|
        title = asong[:title]
        stitle = to_search_str(title)
        if stitle && !stitle.empty?
          unless @tags[stitle]
            @tags[stitle] = []
            newsong = true
          end
        end
      end

      if newsong || @newtag
        wtag = @tags.to_a.sort.
          map {|k2, v| "#{k2}:::#{v.join(',')}"}
        woption = {format: :text, backup: backup}
        _write_with_backup(@tagfile, wtag, woption)
        @newtag = false
      end
      self
    end

    def add_tag(song, tag)
      key = song[:stitle]
      @tags[key] = ((@tags[key] || []) + [tag]).uniq
      @newtag    = true
    end

    def set_follows(followings, followers)
      # Clear the list first
      @singers.each do |singer, sinfo|
        @singers[singer].delete(:following)
        @singers[singer].delete(:follower)
      end
      followings.each do |singer|
        @singers[singer[:name]] = singer
        @singers[singer[:name]][:following] = true
      end
      followers.each do |singer|
        @singers[singer[:name]] ||= singer
        @singers[singer[:name]][:follower] = true
      end
      @schanged = true
      self
    end

    def add_new_songs(block, isfav=false)
      require 'time'

      now = Time.now

      # Favlist must be reset if specified
      if isfav
        @content.each do |sid, sinfo|
          sinfo.delete(:isfav)
        end
      end

      block.each do |r|
        r[:updated_at] = now
        r[:isfav]      = isfav if isfav
        # Keep the 1st created, b/c it is more accurate
        sid = r[:sid]

        r.delete(:since)
        r.delete(:sincev)
        if c = @content[sid]
          c.update(
            listens:   r[:listens],
            loves:     r[:loves],
            since:     r[:since],
            record_by: r[:record_by],   # In case user change login
            isfav:     r[:isfav],
            orig_city: r[:orig_city],
            media_url: r[:media_url],
            sfile:     r[:sfile] || c[:sfile],
            ofile:     r[:ofile] || c[:ofile],
          )
          if c[:isfav]
            c[:oldfav] = true
          end
        else
          @content[sid] = r
        end
      end
      self
    end

    def list
      block = []
      @content.each do |href, r|
        title     = r[:title].scrub
        record_by = r[:record_by]
        stitle    = to_search_str(title)
        block << [title, record_by, stitle]
      end
      block.sort_by {|t, r, st| "#{st}:#{r}"}.each do |title, record_by, st|
        puts "%-50.50s %-24.24s %s" % [title, record_by, st]
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
    
    def download_from_singsalon(ssconnect=nil)
      begin
        if @options[:force] || !test(?f, @info[:sfile])
          if ssconnect
            audio_handler = AudioHandler.new(@surl)
            if audio_handler.get_audio_from_singsalon(@info[:sfile], ssconnect)
              @lyric = audio_handler.get_lyric
              update_mp4tag
            end
          else
            Plog.error("Need to download song, but there is no connection")
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
      end
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
        comment = "#{date} - #{href}"
        year    = cdate.year
        title   = clean_emoji(@info[:title]).gsub(/\'/, "")

        command = "atomicparsley #{@info[:sfile]} --overWrite"

        # Get the artwork
        lcfile  = File.basename(@info[:avatar])
        curl(@info[:avatar], lcfile)
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

  class API
    def initialize(options={})
      @options = options
    end

    def get_songs(url, options)
      allset    = []
      offset    = 0
      limit     = (options[:limit] || 10_000).to_i
      first_day = Time.now - (options[:days] || 7).to_i*24*3600
      catch(:done) do
        while true
          Plog.dump_info(path:"#{url}?offset=#{offset}")
          result = JSON.parse(curl("#{url}?offset=#{offset}"))
          slist  = result['list']
          slist.each do |info|
            #Plog.dump_info(info:info)
            #puts info.to_yaml
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
              Plog.info("Created less than #{first_day}")
              throw :done
            end
            throw :done if (allset.size >= limit)
          end
          offset = result['next_offset']
          throw :done if offset < 0
        end
      end
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
      s_singers = (@options[:singers] || "").split(',').sort
      bar       = ProgressBar.create(title:"Checking collabs",
                                   total:collab_links.size)
      collab_links.each do |alink|
        @spage.goto(alink)
        sitems = @spage.css(".duets.content .recording-listItem")
        sitems.each do |sitem|
          next unless sinfo = _scan_a_collab_song(sitem)
          if s_singers.size > 0
            record_by = sinfo[:record_by].split(',')
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

    def scan_followers
      @spage.goto(@user)
      @spage.click_and_wait('._16qibwx:nth-child(4)')
      sleep(2)
      _scan_users
    end

    def scan_followings
      @spage.goto(@user)
      @spage.click_and_wait('._16qibwx:nth-child(5)')
      sleep(2)
      _scan_users
    end

    def scan_songs
      @spage.goto(@user)
      pages = (@options[:pages] || 100).to_i
      _scan_songs(pages)
    end

    def _scroll_to_bottom(pages=nil)
      pages ||= 50
      bar    = ProgressBar.create(title:"Scroll to end", total:pages)
      (1..pages).each_with_index do |apage, index|
        @spage.execute_script("window.scrollBy({top:700, left:0, behaviour:'smooth'})")
        # Scroll fast, and you'll be banned.  So slowly
        sleep 1
        bar.increment
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

    def _each_main_song(pages)
      _scroll_to_bottom(pages)
      sitems       = @spage.css("._8u57ot")
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

    def _scan_songs(pages=100)
      result       = []
      collab_links = []
      _each_main_song(pages) do |sitem|
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

  class << self
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
      options = getOption
      bar     = ProgressBar.create(title:"Preparing list #{flist.size}", total:flist.size)
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
      FileUtils.rm(Dir.glob("#{ENV['HOME']}/Downloads/*.m4a"))
      bar = ProgressBar.create(title:"Downloading songs #{flist.size}", total:flist.size)
      ssconnect = SiteConnect.new(:singsalon, getOption).driver
      ssconnect.goto('/smule-downloader')
      flist.each do |afile|
        SmuleSong.new(afile).download_from_singsalon(ssconnect)
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

    def _collect_collabs(user, content)
      options   = getOption
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
      result      = Scanner.new(user, options).scan_collab_list(collab_urls)
      content.add_new_songs(result, false)
      result
    end

    # Just for debug to bring up the page for testing
    def test_scanner(user, url)
      options = getOption
      scanner = Scanner.new(user, options)
      scanner.spage.goto(url)
      spage = scanner.spage
      require 'byebug'

      byebug
      a = 10
      b = 20
      c = 30
    end

    def _tdir_check(tdir)
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
    end

    def _collect_songs(user, content)
      options = getOption
      limit   = (options[:limit] || 10_000).to_i
      days    = (options[:days] || 7).to_i
      sapi    = API.new
      perfset = sapi.get_performances(user, limit:limit, days:days)
      content.add_new_songs(perfset, false)
      favset  = sapi.get_favs(user)
      content.add_new_songs(favset, true)
      perfset
    end

    def collect_collabs(user, tdir='data')
      _tdir_check(tdir)
      options = getOption
      content = Content.new(user, tdir)
      collabs = _collect_collabs(user, content)
      if collabs.size <= 0
        return true
      end
      _download_list(collabs, tdir) if options[:download]
      content.writeback
      true
    end

    def collect_songs(user, tdir='data')
      _tdir_check(tdir)
      options = getOption
      content = Content.new(user, tdir)
      perfset =  _collect_songs(user, content)
      if perfset.size <= 0
        return true
      end
      _download_list(perfset, tdir) if options[:download]

      # Redo since download list will setup ofile field
      content.add_new_songs(perfset, false)

      # Favs must dump the whole thing
      content.writeback
      true
    end

    def collect_songs_and_collabs(user, tdir='data')
      _tdir_check(tdir)
      options = getOption
      content = Content.new(user, tdir)
      newsongs = _collect_songs(user, content)
      collabs  = _collect_collabs(user, content)
      if (newsongs.size) <= 0 && (collabs.size <= 0)
        return true
      end
      if options[:download]
        _download_list(newsongs + collabs, tdir)
      end
      content.writeback
      true
    end

    def scan_favs(user, tdir='data')
      _tdir_check(tdir)
      options = getOption
      content = Content.new(user, tdir)
      allset  = API.new.get_favs(user)
      content.add_new_songs(allset, true)
      content.writeback
    end

    def unfavs_old(user, count=10, tdir=nil)
      if tdir && !test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
      options = getOption
      favset  = API.new.get_favs(user)
      result  = Scanner.new(user, options).unfavs_old(count.to_i, favset)
      Content.new(user, tdir).add_new_songs(result, true).writeback if tdir
      result.to_yaml
    end

    def scan_follows(user, tdir='data')
      _tdir_check(tdir)
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

    def play(user, tdir='data')
      _tdir_check(tdir)
      SmulePlayer.new(user, tdir, getOption).play_all
    end

    def show_following(user, tdir='data')
      _tdir_check(tdir)
      content   = Content.new(user, tdir)
      following = content.singers.select{|k, v| v[:following]}
      bar = ProgressBar.create(total:content.content.size,
                               format:'%t %B %c/%C')
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
        bar.increment
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

    def fix_content(user, fix_type, tdir='data')
      _tdir_check(tdir)
      content  = Content.new(user, tdir)
      ccount   = 0
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
        end
      end
      if ccount > 0
        Plog.info("#{ccount} records fixed")
        content.writeback
      end
    end

    def fix_favs(user, tdir='data')
      _tdir_check(tdir)
      content = Content.new(user, tdir)
      cutoff  = Time.parse("2019-09-01")
      content.each do |sid, cinfo|
        cdate = created_value(cinfo[:created])
        if (cdate < cutoff) || !cinfo[:oldfav]
          next
        end
        Plog.dump_info(sid:sid, cdate:cdate)
        cinfo.delete(:oldfav)
      end
      content.writeback
    end

    def add_mp3_comment(user, tdir='data')
      _tdir_check(tdir)
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
        v[:ofile], v[:sfile] = _ofile(v)
        if !test(?f, v[:sfile]) || (File.size(v[:sfile]) < 1_000_000) ||
            !test(?l, v[:ofile])
          SmuleSong.new(v, force:true).download_from_singsalon
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
    def move_singer(user, old_name, new_name, tdir='data')
      _tdir_check(tdir)
      content = Content.new(user, tdir)
      options = getOption
      options.update(
        pbar:   "Move content from #{old_name}",
        filter: "record_by=#{old_name}",
      )
      changed = false
      content.each(options) do |k, v|
        new_record_by = v[:record_by].gsub(old_name, new_name)
        if new_record_by != v[:record_by]
          v[:record_by] = new_record_by
          v[:ofile], v[:sfile] = _ofile(v)
          SmuleSong.new(v).download_from_singsalon
          changed = true
        end
      end
      content.writeback if changed
    end
  end
end

if (__FILE__ == $0)
  SmuleAuto.handleCli(
    ['--auth',        '-a', 1],
    ['--browser',     '-b', 1],
    ['--download',    '-d', 0],
    ['--days',        '-D', 1],
    ['--filter',      '-f', 1],
    ['--limit',       '-l', 1],
    ['--play_length', '-L', 1],
    ['--mysongs',     '-m', 0],
    ['--myopen',      '-M', 0],
    ['--no_auth',     '-n', 0],
    ['--order',       '-o', 1],
    ['--store_dir',   '-O', 1],
    ['--pages',       '-p', 1],
    ['--singers',     '-s', 1],
    ['--size',        '-S', 1],
    ['--verbose',     '-v', 0],
  )
end

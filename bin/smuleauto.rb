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
}

def to_search_str(str)
  stitle = clean_emoji(str).downcase.sub(/\s*\(.*$/, '').strip
  AccentMap.each do |ptn, rep|
    stitle = stitle.gsub(ptn, rep)
  end
  stitle
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
        Plog.info("Wrote #{ofile}.  Wait a bit to see if smule let me go")
        sleep(5+rand(5))
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
      sdoc  = Nokogiri::HTML(`curl -s '#{@song_info_url}'`)
      asset = sdoc.css('head script')[0].text.split("\n").grep(/Song:/)[0].
        sub(/^\s*Song: /, '')[0..-2]
      CGI.unescapeHTML(JSON.parse(asset).dig('lyrics')).
                  gsub(/<br>/, "\n").
                  gsub(/<p>/, "\n\n")
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
    attr_reader :content, :singers

    def initialize(user, cdir='.')
      @user    = user
      @cdir    = cdir
      @cfile   = "#{cdir}/content-#{user}.yml"
      @sfile   = "#{cdir}/singers-#{user}.yml"
      @tagfile = "#{cdir}/songtags.yml"
      if test(?f, @cfile)
        @content = YAML.load_file(@cfile)
      else
        Plog.warn("#{@cfile} does not exist")
        @content = {}
      end

      @content.each do |k, r|
        r[:sincev] = time_since(r[:since]) / 3600.0
      end

      @singers = test(?f, @sfile) ? YAML.load_file(@sfile) : {}
    end

    def following
      @singers.select{|k, v| v[:following]}
    end

    def follower
      @singers.select{|k, v| v[:follower]}
    end

    def _write_with_backup(mfile, content, format=:yaml)
      bakfile = File.join(ENV['PWD'], 'data', File.basename(mfile))
      [mfile, bakfile].each do |afile|
        b2file = afile + ".bak"
        if test(?f, afile)
          FileUtils.move(afile, b2file, verbose:true)
        end
        File.open(afile, 'w') do |fod|
          Plog.info("Writing #{content.size} entries to #{afile}")
          case format
          when :text
            fod.puts content
          else
            fod.puts content.to_yaml
          end
        end
      end
    end

    def writeback
      require 'time'

      @content.each do |sid, asong|
        stitle = to_search_str(asong[:title])
        asong[:stitle] ||= stitle
      end
      _write_with_backup(@cfile, @content)
      _write_with_backup(@sfile, @singers)

      tagset  = {}
      if test(?f, @tagfile)
        File.read(@tagfile).split("\n").each do |l|
          k, v = l.split(':::')
          tagset[k] = (v || '').split(',')
        end
      end
      @content.each do |sid, asong|
        title = asong[:title]
        tagset[title] ||= []
      end
      tagset = tagset.to_a.sort_by{|k, v| k.downcase}.
        map {|k, v| "#{k}:::#{v.join(',')}"}
      _write_with_backup(@tagfile, tagset, :text)
      self
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
        @singers[singer[:name]] = singer
        @singers[singer[:name]][:follower] = true
      end
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

      first_bad_date = Time.parse('2019-07-01')
      block.each do |r|
        r[:updated_at] = now
        r[:isfav]      = isfav if isfav
        # Keep the 1st created, b/c it is more accurate
        sid = r[:sid]
        if c = @content[sid]
          c.update(
            listens:   r[:listens],
            loves:     r[:loves],
            since:     r[:since],
            record_by: r[:record_by],   # In case user change login
            isfav:     r[:isfav],
            orig_city: r[:orig_city],
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
        record_by = r[:record_by].gsub(',', ', ')
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
    
    def download
      begin
        if @options[:force] || !test(?f, @info[:sfile])
          audio_handler = AudioHandler.new(@surl)
          if audio_handler.get_audio(@info[:sfile])
            @lyric = audio_handler.get_lyric
            update_mp4tag
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

  class SmuleAPI
    def initialize(options={})
      @options = options
    end

    def get_songs(url, limit)
      allset   = []
      offset   = 0
      catch(:done) do
        while true
          #Plog.dump_info(path: "#{url}?offset=#{offset}")
          result = JSON.parse(`curl -s '#{url}?offset=#{offset}'`)
          slist  = result['list']
          Plog.info("Retrieving from #{offset}")
          slist.each do |info|
            #Plog.dump_info(info:info)
            #puts info.to_yaml
            record_by = [info.dig('owner', 'handle')]
            info['other_performers'].each do |rinfo|
              record_by << rinfo['handle']
            end
            stats   = info['stats']
            created = info['created_at']
            since   = ((Time.now - Time.parse(created))/60).to_i
            rec     = {
              title:       info['title'],
              href:        info['web_url'],
              record_by:   record_by,
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
            }
            allset << rec
            throw :done if (allset.size >= limit)
          end
          offset = result['next_offset']
          throw :done if offset < 0
        end
      end
      allset
    end

    def get_performances(user, limit)
      get_songs("https://www.smule.com/#{user}/performances/json", limit)
    end

    def get_favs(user, limit)
      get_songs("https://www.smule.com/#{user}/favorites/json", limit)
    end
  end

  class SmuleScanner
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

    def set_unfavs(songs)
      songs.each do |asong|
        @spage.goto(asong[:href])
        @spage.click_and_wait('._13ryz2x')
        @spage.click_and_wait('._117spsl')
      end
    end

    def unfavs_old(count, result)
      new_size  = result.size - count
      set_unfavs(result[new_size..-1])
      result[0..new_size-1]
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
      sitems = @spage.page.css("._aju92n9")
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
        record_by:   _record_by_map(record_by),
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
        record_by:   _record_by_map(record_by),
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
      #Plog.dump_info(afile:afile, tdir:tdir)
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

    def download_for_user(user, tdir='data')
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
      options = getOption
      scanner = SmuleScanner.new(user, options)
      songs   = scanner.scan_songs
      _download_list(songs, tdir)

      content = Content.new(user, tdir)
      content.add_new_songs(songs, false)
      unless options[:quick]
        favset = SmuleAPI.new.get_favs(user, 10_000)
        content.add_new_songs(favset, true)
      end
      content.writeback
      true
    end

    def collect_collabs(user, tdir='data')
      content   = Content.new(user, tdir)
      last_date = (Time.now - 30*24*3600)
      ensembles = []
      content.content.each do |sid, cinfo|
        cdate = cinfo[:created]
        if cdate.is_a?(Date)
          cdate = cdate.to_time
        elsif cdate.is_a?(String)
          cdate = Time.parse(cdate)
        end
        if cinfo[:href] =~ /ensembles$/ && cdate > last_date
          ensembles << cinfo
        end
      end
      return unless ensembles.size > 0
      collab_urls = ensembles.sort_by{|r| r[:created]}.reverse.map{|r| r[:href]}

      options = getOption
      result  = SmuleScanner.new(user, options).scan_collab_list(collab_urls)
      _download_list(result, tdir)
      content = Content.new(user, tdir)
      content.add_new_songs(result, false)
      content.writeback
      true
    end

    def collect_songs(user, tdir='data')
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
      options = getOption
      content = Content.new(user, tdir)
      limit   = (options[:limit] || 10_000).to_i
      sapi    = SmuleAPI.new
      perfset = sapi.get_performances(user, limit)
      content.add_new_songs(perfset, false)

      # Favs must dump the whole thing
      unless options[:quick]
        _download_list(perfset, tdir)
        content.add_new_songs(perfset, false)
        favset = sapi.get_favs(user, limit)
        content.add_new_songs(favset, true)
      end
      content.writeback
      true
    end

    def scan_favs(user, tdir='data')
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
      options = getOption
      content = Content.new(user, tdir)
      limit   = (options[:limit] || 10_000).to_i
      allset  = SmuleAPI.new.get_favs(user, limit)
      content.add_new_songs(allset, true)
      content.writeback
    end

    def unfavs_old(user, count=10, tdir=nil)
      if tdir && !test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
      favset = SmuleAPI.new.get_favs(user, 10_000)
      result = SmuleScanner.new(user, getOption).unfavs_old(count.to_i, favset)
      Content.new(user, tdir).add_new_songs(result, true).writeback if tdir
      result.to_yaml
    end

    def scan_follows(user, tdir='data')
      unless test(?d, tdir)
        raise "Target dir #{tdir} not accessible to download music to"
      end
      fset = []
      %w(following followers).each do |agroup|
        users = JSON.parse(`curl "https://www.smule.com/#{user}/#{agroup}/json"`)
        users = users['list'].map{|r| 
          Plog.dump_info(r:r)
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

    def show_content(user, tdir='data')
      Content.new(user, tdir).list
      true
    end

    def play_favs(user, tdir='data', pduration="1.0")
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

    def play_recents(user, tdir='data', pduration="1.0")
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

    def play_singer(user, singer, tdir='data', pduration="1.0")
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

    def fix_content(user, tdir='data')
      content = Content.new(user, tdir)
      content.each do |sid, cinfo|
        if cinfo[:created].is_a?(Time) || cinfo[:created].is_a?(Date)
          cinfo[:created] = cinfo[:created].iso8601
        end
      end
      content.writeback
    end

    def fix_favs(user, tdir='data')
      content = Content.new(user, tdir)
      cutoff  = Time.parse("2019-09-01")
      content.each do |sid, cinfo|
        if cinfo[:created].class == Date
          cdate = cinfo[:created].to_time
        elsif cinfo[:created].class == String
          cdate = Time.parse(cinfo[:created])
        else
          cdate = cinfo[:created]
        end
        if (cdate < cutoff) || !cinfo[:oldfav]
          next
        end
        Plog.dump_info(sid:sid, cdate:cdate)
        cinfo.delete(:oldfav)
      end
      content.writeback
    end

    def add_mp3_comment(user, tdir='data')
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
    def move_singer(user, old_name, new_name, tdir='data')
      changed = false
      content = Content.new(user, tdir)
      options = getOption
      options.update(
        pbar:   "Move content from #{old_name}",
        filter: "record_by=#{old_name}",
      )
      content.each(options) do |k, v|
        new_record_by = v[:record_by].sub(old_name, new_name)
        if new_record_by != v[:record_by]
          v[:record_by] = new_record_by
          v[:ofile], v[:sfile] = _ofile(v, tdir)
          SmuleSong.new(v).download
          changed = true
        end
      end
      if changed
        content.writeback
      end
    end

    def show_singers(user, tdir='data')
      options = getOption
      content = Content.new(user, tdir)
      ulist   = {}
      content.each(options) do |k, v|
        v[:record_by].split(',').each do |auser|
          next if auser == user
          ulist[auser] ||= 3650*24
          ulist[auser] = [ulist[auser], v[:sincev]].min
        end
      end
      ulist.to_a.select{|name, sincev|
        (content.singers[name] || {})[:following]
      }.sort_by {|name, sincev| sincev}.each {|name, sincev|
        puts "%-20s %6.1d" % [name, sincev/24]
      }
      nos_list = content.following.keys - ulist.keys
      puts "Not singing with: #{nos_list.join(' ')}"
      true
    end

    def make_song_tags(user, tdir='data')
      content = Content.new(user, tdir)
      content.writeback
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

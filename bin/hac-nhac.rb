#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hac-nhac.rb
# Date:        2018-04-01 01:46:33 -0700
# $Id$
#---------------------------------------------------------------------------
#++
# nhac.vn source
class MusicSource
  include HtmlRes

  def song_list_with_filter(url, options={})
    check_lyrics = options[:check_lyrics]
    options.delete(:check_lyrics)

    Plog.info("Collecting #{self.class} from #{url}")
    links = song_list(url, options).uniq {|e| e[:href]}

    # Filter for having lyrics only
    if check_lyrics
      links = links.select do |info|
        linfo = lyric_info(info[:href])
        if linfo[:lyric] && !linfo[:lyric].empty?
          info.update(linfo)
          true
        else
          false
        end
      end
    end
    links
  end

  class << self
    def mk_source(url, options={})
      case url
      when /chordzone.org/
        ChordZoneSource.new
      when /hopamchuan/
        HacSource.new(options)
      when %r{hopamhay}
        HahSource.new
      when %r{hopamviet.vn}
        HavSource.new
      when /keeng.vn/
        KeengSource.new
      when /nhaccuatui/
        NctSource.new
      when /nhac.vn/
        NhacSource.new
      when /spotify/
        SpotifySource.new
      when /tabs.ultimate-guitar.com/
        TabGuitarSource.new
      when /guitartwitt.com/
        GuitarTwitt.new
      when /chordsworld.com/
        ChordsWorld.new
      when %r{zing}
        ZingSource.new
      else
        raise "Cannot create source for #{url}"
      end
    end
  end
end

module ChordMerger
  def _pick_chords(line)
    chords  = []
    s_space = true
    cword   = ''
    cindex  = 0
    (line + ' ').split('').each_with_index do |c, index|
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
    chords
  end

  # Merge the blob where chord line goes on top of lyric line
  def merge_chord_lines(lyric)
    chords  = []
    result  = []
    options = {shift_space:true}
    lyric.split(/\n/).each do |l|
      l, is_chord_line = detect_and_clean_chord_line(l)
      if is_chord_line
        # Multiple chord lines together
        if chords.size > 0
          result << chords.map {|cword, _cindex| "[#{cword}]"}.join(' ')
        end
        chords = _pick_chords(l)
        next
      end
      if l =~ /^(\s*)\[(.*)\]\s*$/
        l = "#{$1}#{$2}:"
      end
      if chords.size > 0
        # Reverse to avoid changing the disturbing existing text until touched
        chords.reverse.each do |text, pos|
          begin
            if l.size <= pos
              l += ' ' * 80
            end
            #Plog.dump_error(start:l[0..pos-1], pos:pos, remain:l[pos..-1])

            # Need to back until I find a space
            if options[:shift_space]
              if (pos > 0) && (l[pos] != ' ') && (l[pos-1] != ' ')
                cpos = pos-1
                while cpos > 0
                  if l[cpos] == ' '
                    Plog.dump_error(pos:pos, cpos:cpos+1)
                    pos = cpos+1
                    break
                  end
                  cpos -= 1
                end
                if cpos == 0
                  pos = 0
                end
              end
            end

            l.insert(pos, "[#{text}]")
            #Plog.dump_error(l:l)
          rescue => errmsg
            Plog.error errmsg
          end
        end
        chords = []
      end
      l = l.strip.gsub(/\s+/, ' ')
      result << ' ' + l
    end
    result.join("\n")
  end
end

class GuitarTwitt < MusicSource
  
  # WIP:  Not parseable?
  def lyric_info(url)
    require 'byebug'

    byebug
    Plog.info("Extract lyrics from #{url}")
    page    = get_page_curl(url)
    content = page.css('.entry-content')
    ltext   = []
    content.css('p, h4').each do |ap|
      nap = Nokogiri::HTML(ap.to_html.gsub('<br>', '<p>'))
      ltext.concat(nap.css('p'))
    end
    
    
    blob  = get_page_curl(url, raw:true)
    blob  = JSON.parse(blob.sub(/^[^{]*/o, '').sub(/;\s*$/o, ''))['data']
    lyric = merge_chord_lines(blob.dig('tab_view', 'wiki_tab', 'content'))
    {
      lyric:  lyric,
      title:  blob.dig('tab', 'song_name'),
      artist: (blob.dig('tab', 'recording', 'recording_artists') || []).
                map{|r| r.dig('artist', 'name')}.join(', '),
      author: blob.dig('tab', 'artist_name'),
      source: url,
    }
  end
end

class ChordsWorld < MusicSource
  include ChordMerger

  def detect_and_clean_chord_line(l)
    words = l.split
    cline = true
    words.each do |w|
      if w !~ /^\[?[-A-G][Mmb#ajdimsu0-9]*(\/[A-Gb#]*)?\]?$/o
        cline = false
        break
      end
    end
    cline = false if words.size <= 0
    [l, cline]
  end

  def lyric_info(url)
    require 'json'
      require 'byebug'

      byebug

    Plog.info("Extract lyrics from #{url}")
    page  = get_page_curl(url)
    blob  = page.css('.contentprotect')
    lyric = merge_chord_lines(blob.text)
    lyric = lyric.split("\n").select{|l| l !~ /adsbygoogle/}.join("\n")
    etitle =  page.css('.entry-title').text
    artist, title = etitle.split(/\s+-\s+/, 2)
    {
      lyric:  lyric,
      title:  title,
      artist: artist,
      source: url,
    }
  end
end

class TabGuitarSource < MusicSource
  include ChordMerger

  def detect_and_clean_chord_line(l)
    if l.include?('[ch]')
      l = l.gsub(/\[\/?ch\]/, '')
      cline = true
    else
      cline = true
      words = l.split
      words.each do |w|
        if w !~ /^\[?[-A-G][Mmb#ajdimsu0-9]*(\/[A-Gb#]*)?\]?$/o
          cline = false
          break
        end
      end
      cline = false if words.size <= 0
    end
    [l, cline]
  end

  def lyric_info(url)
    require 'json'

    Plog.info("Extract lyrics from #{url}")
    blob  = get_page_curl(url, raw:true).split("\n").grep(/window.UGAPP.store.page/)[0]
    blob  = JSON.parse(blob.sub(/^[^{]*/o, '').sub(/;\s*$/o, ''))['data']
    lyric = merge_chord_lines(blob.dig('tab_view', 'wiki_tab', 'content'))
    {
      lyric:  lyric,
      title:  blob.dig('tab', 'song_name'),
      artist: (blob.dig('tab', 'recording', 'recording_artists') || []).
                map{|r| r.dig('artist', 'name')}.join(', '),
      author: blob.dig('tab', 'artist_name'),
      source: url,
    }
  end
end

class NhacSource < MusicSource
  def lyric_info(url)
    Plog.info("Extract lyrics from #{url}")
    page  = get_page(url)
    sdetails = page.css('.h2-song-detail')
    ndetails = page.css('.name_detail').text.strip.split(/\s+-\s+/)
    {
      lyric:  page.css('.content_lyrics').text.strip,
      title:  ndetails[0],
      artist: ndetails[1],
      author: sdetails[0].css('.val').text.strip,
      genre:  sdetails[1].css('.val').text.strip,
      source: url,
    }
  end

  def song_list(url, options={})
    page  = get_page(url)
    limit = (options[:limit] || 9999).to_i
    case url
    when %r{^https://nhac.vn/?$}
      links = page.css('.info_song_home')[0..limit-1].map do |atrack|
        {
          name: atrack.css('.name a')[0].text.strip,
          href: atrack.css('.name a')[0]['href'],
          artist: atrack.css('.singer a')[0].text.strip,
        }
      end
    else
      links = page.css('.item-in-list .h4-song-item')[0..limit-1].
        map do |atrack|
        tlinks = atrack.css('a')
        arefs  = atrack.css('a').map {|a| [a.text, a['href']]}
        info   = {
          name:   tlinks[0].text.strip,
          href:   tlinks[0]['href'],
          artist: tlinks[1].text.strip,
        }
        info
      end.uniq {|e| e[:href]}
    end
    links
  end

  def browser_song_list(spage, url, options={})
    spage.goto(url)
    limit = (options[:limit] || 9999).to_i
    page  = spage.page
    case url
    when %r{^https://nhac.vn/?$}
      links = page.css('.info_song_home')[0..limit-1].map do |atrack|
        {
          name: atrack.css('.name a')[0].text.strip,
          href: atrack.css('.name a')[0]['href'],
          artist: atrack.css('.singer a')[0].text.strip,
        }
      end
    when %r{/album/}
      links = page.css('.items .present')[0..limit-1].
        map do |atrack|
        info = {
          name:   atrack.css('a')[0].text.strip,
          href:   atrack.css('a')[0]['href'],
          artist: atrack.css('.artist').text.strip,
        }
        info
      end
    else
      links = page.css('.item-in-list .h4-song-item')[0..limit-1].
        map do |atrack|
        tlinks = atrack.css('a')
        info = {
          name:   tlinks[0].text.strip,
          href:   tlinks[0]['href'],
          artist: tlinks[1].text.strip,
        }
        info
      end.uniq {|e| e[:href]}
    end
    links
  end
end

class KeengSource < MusicSource
  def lyric_info(url)
    Plog.info("Extract lyrics from #{url}")
    page  = get_page(url)
    {
      lyric:  page.css('.info-show')[0].text.strip,
      title:  page.css('#song_name').text.strip,
      artist: page.css('#song_singer_name').text.strip,
      author: page.css('#author').text.strip,
      genre:  page.css('#song_cat').text.strip,
      source: url,
    }
  end

  def song_list(url, options={})
    page   = get_page(url)
    limit = (options[:limit] || 9999).to_i
    case url
    when %r{^http://keeng.vn/?$}
      links = page.css('.song-hot-info')[0..limit-1].map do |atrack|
        tinfo  = atrack.css('.song-hot-h3 a')[0]
        {
          name:   tinfo.text.strip,
          href:   tinfo['href'],
          artist: atrack.css('.song-hot-singer')[0].text.strip,
        }
      end
    when %r{/video/}
      links = page.css('.ka-content')[0..limit-1].
        map do |atrack|
        tinfo = atrack.css('.ka-info-h3 a')
        {
          name:   tinfo.text.strip,
          href:   tinfo[0]['href'],
          artist: atrack.css('a.singer-audio').text.strip,
        }
      end
    else
      links = page.css('.ka-info')[0..limit-1].
        map do |atrack|
        tinfo = atrack.css('.ka-info-h3 a')
        {
          name:   tinfo.text.strip,
          href:   tinfo[0]['href'],
          genre:  atrack.css('.category-song').text.strip,
          artist: atrack.css('.ka-info-singer a').text.strip,
        }
      end
    end
    links.select{|r| r[:href] !~ /album/}
  end
end

# hopamviet
class HavSource < MusicSource
  def lyric_info(url)
    Plog.info("Extract lyrics from #{url}")
    page  = get_page(url)
    links = page.css('.ibar a').map {|l| l.text.strip}
    if links[0] == 'Sheet'
      links.shift
    end
    chord, artist = "", ""
    if page.css('#fullsong span.label-primary').size > 0
      selperf = 0
      chord   = page.css('#fullsong span.label-primary')[selperf].text.strip
      artist  = page.css('#fullsong a')[selperf].text.strip.sub(/\s*\(.*$/, '')
    end
    lyric    = page.css('#lyric').text.strip
    pcount   = page.css('.ibar')[0].text.strip.split.last
    new_note = ""
    if chord && !chord.empty? && (lyric =~ /\[([a-z0-9#]+)\]/im)
      lkey     = $1
      if lkey != chord
        offset = key_offset(lkey, chord)
        Plog.info({lkey:lkey, chord:chord, offset:offset}.inspect)
        new_note = "Tone #{artist} là #{chord}.  Capo #{offset} chơi #{lkey}"
      end
    end

    ret = {
      lyric:  lyric,
      lnote:  new_note,
      title:  page.css('.ibar h3').text.strip.split("\n")[0],
      author: links[0..-3].join(', '),
      genre:  links[-2],
      artist: artist,
      chord:  chord,
      pcount: pcount.to_i
    }
    ret
  end

  def scan_song_list(curl, options={})
    offset = 0
    links  = []
    curl   = curl.sub(/\.html$/, '')
    limit  = (options[:limit] || 0).to_i
    while true
      if curl =~ /search.html/
        url = "#{curl}&per_page=#{offset}"
      else
        url = "#{curl}/#{offset}"
      end
      Plog.info("Checking #{url}")
      page   = get_page(url)
      plinks = page.css('.fa-music + a')
      break if plinks.size <= 0
      new_links = plinks.map do |plink|
        if block_given?
          yield plink.text.strip, plink['href']
        end
        { 
          name: plink.text.strip,
          href: plink['href'],
        }
      end
      links  += new_links
      offset += 10
      if !limit.zero? && (offset > limit)
        break
      end
    end
    links
  end

  def song_list(url, options={})
    page   = get_page(url)
    plinks = page.css('.ct-box p a')
    result = plinks.map do |plink|
      { 
        name:   plink.text.strip,
        href:   plink['href'],
      }
    end
    plinks = page.css('.col-md-12 h4')
    result += plinks.map do |pinfo|
      name = pinfo.css('.fa-music+a')[0].text.strip
      href = pinfo.css('.fa-music+a')[0]['href']
      { 
        name:   name,
        href:   href,
      }
    end
    result
  end

  def find_matching_song(name)
    sname0 = name.sub(/\s*\(.*$/, '')
    sname  = CGI.escape(sname0)
    url    = "https://hopamviet.vn/chord/search.html?song=#{sname}"
    page   = get_page(url)
    plinks = page.css('.fa-music + a')
    if plinks.size <= 0
      Plog.info("#{sname0} not found on HAV")
      return []
    end
    plinks.map do |plink|
      { 
        sname:  name,
        name:   plink.text.strip,
        href:   plink['href'],
      }
    end
  end

  def find_matching_songs(slist)
    result     = []
    not_founds = []
    bar    = ProgressBar.new(slist.size)
    slist.each do |sinfo|
      bar.increment!
      plinks = find_matching_song(sinfo[:name])
      unless plinks
        Plog.info("#{sname0} not found on HAV")
        not_founds << sinfo
        next
      end
      result += plinks
    end
    if result.size > slist.size
      Plog.info "Found more matching songs than requested"
    end
    result = result.uniq {|e| e[:href]}
    [result, not_founds]
  end
end

# hopamhay
class HahSource < MusicSource
  def lyric_info(url)
    Plog.info("Extract lyrics from #{url}")
    page  = get_page(url)
    page.css('#wide .pre script').remove

    titles = page.css('.lyrics-title a').map{|r| r.text.strip}
    title  = titles[0]
    author = titles[1]
    genre  = titles[-1]
    artist, chord = nil, nil

    ['#fullsong a', '.single-lyric-video a'].each do |spec|
      if element = page.css(spec)[0]
        artist = element.text.strip
        break
      end
    end

    ['#fullsong .label-primary', '.single-lyric-video .KCNchordWrap'].each do |spec|
      if element = page.css(spec)[0]
        chord = element.text.strip
        break
      end
    end

    if !artist && !chord
      page.css('.single-lyric-video div').remove
      artist, chord = page.css('.single-lyric-video').text.strip.split(/\s+\|\s+/)
      chord = chord.sub(/^Tone:\s+/, '')
    end

    guide = page.css('.huong-dan-dem-hat').text.strip

    lyric = page.css('.pLgn').map{|r| r.text.strip}.join("\n")
    if lyric.empty?
      lyric = page.css('#wide .pre').text
    end
    lyric = lyric.gsub(/_/, '').gsub(/\[\]/, '')
    lyric = <<EOL
#{guide}
===
#{lyric}
EOL
    ret = {
      title:  title,
      author: author,
      genre:  genre,
      artist: artist,
      chord:  chord,
      lyric:  lyric,
    }
    ret
  end

  def song_list(url, options={})
    url     = 'https://hopamhay.com'
    page    = get_page(url)
    list_no = (options[:list_no] || 1).to_i
    section = page.css('.latest-lyrics')[list_no]
    res = section.css('h5 a').map do |r|
      name    = r.text.strip.sub(/\s*–.*$/, '')
      {
        name:  name,
        href:  r['href']
      }
    end
    res
  end
end

# nhaccuatui
class NctSource < MusicSource
  def lyric_info(url)
    Plog.info("Extract lyrics from #{url}")
    page  = get_page(url)
    data  = page.css('.detail_info_playing_now a')
    genre = nil
    genre = data[-1].text.strip if data.size > 0
    lyric = page.css('#divLyric').text.strip
    #Plog.dump_info(lyric:lyric)
    {
      lyric:  lyric,
      title:  page.css('.name_title h1').text.strip,
      artist: page.css('.name-singer').text.strip,
      genre:  genre,
      source: url,
    }
  end

  def song_list(url, options={})
    url  ||= 'http://www.nhaccuatui.com/'
    page   = get_page(url)
    Plog.info("Check list at #{url}")
    if url =~ /playlist|chu-de/
      links = _songs_playlist(page, options)
    elsif url =~ /nghe-si/
      links = _songs_artist(page, options)
    else
      links = _songs_main(page, options)
    end
    links
  end

  def _songs_playlist(page, options={})
    limit = (options[:limit] || 9999).to_i
    page.css('#idScrllSongInAlbum li[itemprop="tracks"]')[0..limit-1].map do |atrack|
      arefs = atrack.css('a').map {|a| [a.text, a['href']]}
      info = {
        name:   arefs[0][0].sub(/\s*\(.*$/, '').sub(/\s+(2017|Cover)$/, ''),
        href:   arefs[2][1] || arefs[0][1],
        artist: arefs[1][0],
      }
      info
    end
  end

  def _songs_artist(page, options={})
    limit = (options[:limit] || 9999).to_i
    page.css('.list_item_music li')[0..limit-1].map do |atrack|
      arefs = atrack.css('a').map {|a| [a.text, a['href']]}
      info = {
        name:   arefs[0][0].sub(/\s*\(.*$/, '').sub(/\s+(2017|Cover)$/, ''),
        href:   arefs[0][1],
        artist: arefs[1][0],
      }
    end
  end

  # This is the top page
  def _songs_main(page, options={})
    limit = (options[:limit] || 9999).to_i
    links = []
    ['a.name_song', 'a.button_playing'].each do |selector|
      page.css(selector).each do |atrack|
        if atrack['title']
          name, artist = atrack['title'].split(/\s+-\s+/)
        else
          name, artist = atrack.text.strip.split(/\s+-\s+/)
        end
        name = name.sub(/Nghe bài hát\s+/, '')
        links << {
          name:   name,
          href:   atrack['href'],
          artist: artist,
        }
        break if links.size >= limit
      end
      break if links.size >= limit
    end
    links
  end
end

class ZingSource < MusicSource
  # Zing requires a selenium connection
  def initialize
  end

  def lyric_info(url)
    Plog.info("Extract lyrics from #{url}")
    page  = get_page(url)
    title, artist = page.css('h1')[0].text.strip.split(/\s+-\s+/)
    genre = page.css('a.genre-track-log')[-1].text.strip
    lyrics = page.css('p.fn-wlyrics')
    if lyrics.size > 0
      lyric = page.css('p.fn-wlyrics')[0].text.strip
      {
        lyric:  lyric,
        title:  title,
        artist: artist,
        genre:  genre,
        source: url,
      }
    else
      Plog.error "No lyrics found for #{url}"
      nil
    end
  end

  def song_list(url, options={})
    page   = get_page(url)
    # Artist page
    base_url = 'https://mp3.zing.vn'
    links    = page.css('li[data-type="song"]').map do |atrack|
      aref = atrack.css('a')[0]
      name, artist = aref.text.strip.split(/\s+-\s+/)
      info = {
        name:   name,
        href:   base_url + aref['href'],
        artist: artist,
      }
    end
    links
  end

  def browser_song_list(spage, url, options={})
    uri      = URI.parse(url)
    base_url = uri.scheme + '://' + uri.host
    slist    = []
    spage.goto(url) if url
    case url
    when /zing-chart-tuan/
      slist = spage.page.css(".e-item").map do |sitem|
        sinfo  = sitem.css('.title-item a')[0]
        href   = base_url + sinfo['href']
        name   = sinfo.text.strip
        sinfo  = sitem.css('.title-sd-item a')[0]
        artist = sinfo.text.strip
        {
          name:   name,
          artist: artist.gsub(/\s+/, ' '),
          href:   href,
        }
      end
    when nil, 'https://mp3.zing.vn', /zing-chart/
      slist = spage.page.css(".desc-song").map do |sitem|
        sinfo  = sitem.css('a.fn-name')[0]
        href   = base_url + sinfo['href']
        name   = sinfo.text.strip
        sinfo  = sitem.css('.sub-title')[0]
        artist = sinfo.text.strip
        {
          name:   name,
          artist: artist.gsub(/\s+/, ' '),
          href:   href,
        }
      end

      slist += spage.page.css("li.dot a").map do |sitem|
        name = sitem['title']
        href = sitem['href']
        {
          name:   name,
          href:   href,
        }
      end
    when /top100/
      # Scroll a few times to the end of page
      (1..5).each do |apage|
        spage.execute_script("window.scrollTo(0,10000)")
        sleep 1
      end
      spage.refresh
      slist = spage.page.css(".e-item").map do |sitem|
        sinfo = sitem.css('a.fn-name')[0]
        href  = base_url + sinfo['href']
        name  = sinfo.text.strip
        artist = sitem.css('.fn-artist_list a').map{|i| i.text.strip}.join(', ')
        {
          name:   name,
          artist: artist,
          href:   href,
        }
      end
    when /album|playlist/
      if url =~ /beta.mp3.zing.vn/
        slist = spage.page.css(".card-info").map do |sitem|
          sinfo  = sitem.css('.title a')[0]
          href   = base_url + (sinfo['href'] || '')
          name   = sinfo.text.strip
          artist = sitem.css('.artist').text.strip
          {
            name:   name,
            artist: artist.gsub(/\s+/, ' '),
            href:   href,
          }
        end
      else
        slist = spage.page.css(".fn-playlist-item").map do |sitem|
          sinfo  = sitem.css('a.fn-name')[0]
          href   = base_url + sinfo['href']
          name   = sinfo.text.strip
          artist = sitem.css('.fn-artist').text.strip
          {
            name:   name,
            artist: artist.gsub(/\s+/, ' '),
            href:   href,
          }
        end
      end
      slist = slist.select{|r| r[:href] !~ /album/}
    else
      Plog.error "Unsupported URL for zing: #{url}"
    end
    slist
  end
end

class SpotifySource < MusicSource
  def song_list(url, options={})
    page   = get_page(url)
    links  = {}
    tracks = []
    page.css('.track-name-wrapper').each do |atrack|
      name = atrack.css('.track-name').text.strip
      artist = atrack.css('a')[0].text.strip
      info = {
        name:    name,
        artist:  artist,
      }
      if block_given?
        yield info
      end
      tracks << info
    end
    tracks
  end
end

class HacSource < MusicSource
  attr_reader :base_url

  def initialize(options={})
    @base_url = options[:hac_url] || "https://hopamchuan.com"
  end

  def find_matching_songs(slist, do_match=true)
    found_set  = []
    not_founds = []
    bar        = ProgressBar.new(slist.size)
    slist.each do |sinfo|
      ck_name = sinfo[:name].strip.sub(/\s*\(.*$/o, '').sub(/\s+cover/io, '')
      url     = "#{@base_url}/search?q=#{CGI.escape(ck_name)}"
      Plog.dump_info(url:url)
      begin
        page    = get_page(url)
      rescue OpenURI::HTTPError => errmsg
        Plog.dump_error(url:url, errmsg:errmsg)
        next
      end

      bar.increment!
      found_item = nil
      [:perfect, :name_only, :first].each do |phase|
        page.css('.song-item').each do |sitem|
          case phase
          when :perfect
            title  = sitem.css('a.song-title').text.strip.sub(/\s*\(.*$/o, '')
            author = sitem.css('a.author-item').text.strip
            if title == ck_name && author == sinfo[:artist]
              Plog.info "Match #{sinfo} perfectly from HAC"
              found_item = sitem
              break
            end
          when :name_only
            title  = sitem.css('a.song-title').text.strip.sub(/\s*\(.*$/o, '')
            if title == ck_name
              Plog.info "Match #{sinfo} on name from HAC"
              found_item = sitem
              break
            end
          when :first
            Plog.info "Match #{sinfo} on 1st match from HAC"
            found_item = sitem
            break
          end
        end
        break if found_item
      end
      if found_item
        flink = found_item.css('a.song-title')
        sname = flink.text.strip.sub(/\s*\(.*$/o, '')
        found_set << {
          sname:  sname,
          name:   sname,
          href:   flink[0]['href'],
        }
      else
        not_founds << sinfo
      end
    end
    found_set = found_set.uniq {|e| e[:href]}
    [found_set, not_founds]
  end

  def download_song(href, options={})
    path  = href.split('/').compact
    if path.size >= 7
      sno, song, user = path[-3], path[-2], path[-1]
    else
      sno, song, user = path[-2], path[-1], "unknown"
    end

    sdir    = options[:store] || '.'
    odir    = "#{sdir}/#{user}"
    unless test(?d, odir)
      FileUtils.mkdir_p(odir, verbose:true)
    end

    ofile = "#{odir}/#{sno}::#{song}.yml"
    if !options[:force] && test(?s, ofile)
      Plog.info("#{ofile} exists.  Skip") if options[:verbose]
      return
    end

    sinfo = {href:href, ofile:ofile}
    sinfo.update(lyric_info(sinfo[:href]) || {})
    
    Plog.info("Writing to #{ofile}")
    File.open(ofile, "w") do |fod|
      fod.puts sinfo.to_yaml
      #fod.puts JSON.pretty_generate(sinfo)
    end
    sinfo
  end

  def download_songs(user, options={})
    if user =~ /^http/
      download_song(user, options)
    else
      song_list("#{@base_url}/profile/posted/#{user}", options) do |sinfo|
        download_song(sinfo[:href], options)
      end
    end
    true
  end

  # Extraction could leave multiple chords between bracket.  We comenstate it here
  def _fix_chords(lyric)
    output = ''
    lyric.scan(/([^\[]*)\[([^\]]+)\]/m).each do |text, chord|
      chord = chord.split.join("] [")
      output += "#{text}[#{chord}]"
    end
    last_span = lyric.sub(/^.*\]/m, '')
    output += last_span
    output
  end

  def lyric_info(url)
    Plog.info("Extract lyrics from #{url}")
    page      = get_page(url)
    lnote     = page.css('.song-lyric-note .chord_lyric_line').
                    map{|r| r.text.strip}.join("\n").strip
    lnote     = _fix_chords(lnote)
    lyric     = page.css('#song-lyric > .pre > .chord_lyric_line').
                    map{|r| r.text.gsub(/\r/, '').gsub(/\s+\]/, ']').strip}.join("\n")
    lyric     = _fix_chords(lyric)
    artist    = page.css('.perform-singer-list .author-item').map {|r| r.text.strip}
    author    = page.css("#song-detail-info tr")[1].css("td")[0].text.strip
    genre     = page.css("#song-detail-info tr")[1].css("td")[1].text.strip
    perf_link = page.css('.perform a').last['href']
    song_key  = (lnote + lyric).scan(/\[([^\]]+)\]/)[0][0]
    ret = {
      title:     page.css('#song-title').text.strip,
      artist:    artist.join(', '),
      author:    author,
      genre:     genre,
      lnote:     lnote,
      lyric:     lyric,
      perf_link: perf_link,
      song_key:  song_key,
    }
  end

  def list_for_user(url, options={})
    offset = 0
    result = []
    loop do
      page = get_page("#{url}?offset=#{offset}")
      list = page.css('.playlist-item')
      break if list.size <= 0
      result += list.map do |item|
        alink = item.css('.playlist-item-title a')[0]
        href  = alink['href']
        sname = href.split('/')[-2..-1].join('/')
        list_id = href.split('/')[-2].to_i
        count = item.css('.playlist-item-count').text.strip.to_i
        {
          id:         list_id,
          href:       href,
          sname:      sname,
          name:       alink.text.strip,
          song_count: count,
        }
      end
      offset += 18
    end
    result
  end

  def thanh_vien(count)
    url   = "#{@base_url}/user/month"
    Plog.dump_info(url:url)
    page  = get_page_curl(url)
    tlist = page.css('td .one-line').map{|e| e['href'].split('/').last}[0..count-1]
    Plog.dump_info(tlist:tlist)
    tlist
  end

  # Pull the current list of songs from the playlist
  def playlist(url, options={})
    offset  = 0
    entries = []
    url     = "#{@base_url}/#{url}" unless url =~ /^http/i
    loop do
      purl = "#{url}?offset=#{offset}"
      Plog.info "Loading #{purl}"
      page  = get_page(purl)
      songs = page.css('.song-item')
      break if songs.size <= 0
      page.css('.song-item').each do |sitem|
        href = sitem.css('a.song-title')[0]['href']
        song_id = href.split('/')[4]
        entry = {
          song_id: song_id.to_i,
          name:    sitem.css('.song-title').text.strip,
          href:    href,
          artist:  sitem.css('.song-singers').text.strip.sub(/^-\s*/, ''),
          preview: sitem.css('.song-preview-lyric').text.strip.
                      gsub(/\[[^\]]*\]/, ''),
        }
        entries << entry
      end
      offset += 10
    end
    entries
  end

  def song_list(url, options={})
    collected = 0
    ofile     = options[:ofile]
    links     = {}
    if ofile
      store  = SongStore.new([options[:ofile]].compact)
      store.songs.each do |sinfo|
        links[sinfo[:name]] = sinfo
      end
    end

    limit = (options[:limit] || 100000).to_i
    if value = options[:page]
      offset = (value.to_i) * 10
      incr = -10
    else
      offset = 0
      incr = 10
    end
    loop do
      purl = "#{url}?offset=#{offset}"
      Plog.info "Loading #{purl}"

      page   = get_page(purl)
      sitems = page.css('.song-item')
      break if sitems.size <= 0
      sitems.each do |atrack|
        aref    = atrack.css('a.song-title')[0]
        artist  = atrack.css('.song-singers').
          map{|r| r.text.strip.sub(/^-\s+/, '').split(/\s*,\s*/)}.
          flatten.join(', ')
        preview = atrack.css('.song-preview-lyric')[0].text.strip
        name    = aref.text.strip
        info = {
          name:    name,
          href:    aref['href'],
          artist:  artist,
          preview: preview,
          chords:  atrack.css('.song-chords span').map{|v| v.text.strip}.join(' '),
        }
        if block_given?
          yield info
        end
        collected += 1
        links[name] ||= {}
        links[name].update(info)
      end
      offset += incr
      if collected >= limit
        break
      end
    end
    slist = links.keys.sort.map {|aname| links[aname]}
    if ofile
      store.write(slist)
    else
      slist
    end
  end
end


#!/usr/bin/env ruby
# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        smule_player.rb
# Date:        2020-03-25 16:13:09 -0700
# $Id$
#---------------------------------------------------------------------------
#++

require 'tty-prompt'
require 'tty-box'
require 'tty-cursor'
require 'tty-table'
require 'tty-pager'

module SmuleAuto
  # Docs for PlayList
  class PlayList
    attr :clist, :filter, :listpos

    def initialize(state_file, content, options={})
      @state_file = state_file
      @content    = content
      @options    = options
      # @logger     = options[:logger] || PLogger.new($stderr)
      if test('s', @state_file)
        config   = YAML.safe_load_file(@state_file)
        @clist   = @content.select_sids(config[:clist]) if config[:clist]
        @filter  = config[:filter]
        @order   = config[:order]
        @listpos = config[:listpos]
      end
      @clist   ||= []
      @filter  ||= {}
      @order   ||= 'play'
      @listpos ||= 0
    end

    def toplay_list
      @clist[@listpos..]
    end

    def done_list
      @clist[0..@listpos]
    end

    def order=(value)
      @order = value
      # This have issue, the listpos is hanging here.
      @clist = sort_selection(@clist)
    end

    def save
      data = {
        filter:  @filter,
        order:   @order,
        listpos: @listpos,
        clist:   @clist.map { |r| r[:sid] },
      }
      File.open(@state_file, 'w') do |fod|
        fod.puts(data.to_yaml)
        Plog.info("Updating #{@state_file}")
      end
    end

    def playable?(sitem)
      return false unless sitem

      return false if (sitem[:stars].to_i == 1) || sitem[:deleted]

      #     if (sitem[:href] =~ %r{/ensembles$})
      #       return false
      #     end

      state = :play
      @filter.each do |k, v|
        case k
        when '*'
          state = :skip unless sitem[:stars].to_i == v.to_i
        when '>'
          state = :skip unless sitem[:stars].to_i >= v.to_i
        when 's'
          state = :skip unless sitem[:record_by].downcase.include?(v.downcase)
        when 'S'
          state = :skip unless sitem[:record_by].downcase.start_with?(v.downcase)
        when 't'
          state = :skip unless sitem[:stitle].include?(v)
        end
      end
      if state == :skip
        Plog.info("Skipping #{sitem[:title]}")
        return false
      end
      true
    end

    def next_song(increment: 1, nextinc: 1)
      req_file = 'toplay.dat'
      if test('f', req_file)
        sids = File.read(req_file).split
        @clist.insert(@listpos, *@content.select_sids(sids))
        FileUtils.remove(req_file, verbose: true)
      end
      return nil if @clist.size <= 0

      count = 0
      while count <= @clist.size
        @cursong = @clist[@listpos]
        @listpos = (@listpos + increment)
        # Should not do mod operation here.  Just start
        @listpos = 0 if @listpos >= @clist.size
        return @cursong if playable?(@cursong)

        count += 1
        increment = nextinc
      end
      Plog.error('No matching song in list')
      nil
    end

    def insert(songs, newonly: false)
      if newonly
        newsongs = songs.reject do |asong|
          @clist.find { |r| r[:sid] == asong[:sid] }
        end
        Plog.info("#{newsongs.size} found to be added")
        songs = newsongs
      end
      @clist.insert(@listpos, *songs) unless songs.empty?
    end

    def remains
      @clist.size - @listpos
    end

    def add_to_list(newset, replace: false)
      newset = sort_selection(newset)
      if replace
        @clist   = newset
        @listpos = 0
      else
        @clist.concat(newset)
      end
    end

    # Chop list to a new list only
    def chop(size)
      endpos   = [@listpos + size, @clist.size - 1].min
      @clist   = @clist[@listpos..endpos]
      @listpos = 0
    end

    def cur_info
      {
        filter: @filter,
        order:  @order,
        count:  @clist.size,
        song:   @cursong,
      }
    end

    def sort_selection(cselect)
      Plog.info("Resort based on #{@order}")
      cselect =
        case @order
        when /^random/
          cselect.shuffle
        when /^play/
          cselect.sort_by { |v| v[:listens].to_i }
        when /^love/
          cselect.sort_by { |v| v[:loves].to_i }.reverse
        when /^star/
          cselect.sort_by { |v| v[:stars].to_i }.reverse
        when /^date/
          cselect.sort_by { |v| created_value(v[:created]) }.reverse
        when /^title/
          cselect.sort_by { |v| v[:stitle] }
        else
          Plog.error "Unknown sort mode: #{@order}.  Known are random|play|love|star|date"
          cselect
        end
      cselect = cselect.reverse if @order =~ /\.d$/
      Plog.info("Sorted #{cselect.size} entries")
      cselect
    end
  end

  # Docs for SmulePlayer
  class SmulePlayer
    STATE_FILE = 'splayer.state'

    def initialize(user, tdir, options={})
      @user     = user
      @options  = options
      @roptions = {}
      @content  = SmuleDB.instance(user, cdir: tdir)
      @tdir     = tdir
      @spage    = Scanner.new(user, @options).spage
      @sapi     = API.new(options)
      @wqueue   = Queue.new
      @playlist = PlayList.new(File.join(@tdir, STATE_FILE), @content)
      # @logger   = options[:logger] || PLogger.new($stderr)
      at_exit do
        @playlist.save
        exit 0
      end
      if @options[:download]
        if test('d', SmuleSong.song_dir)
          listen_for_download
        else
          Plog.error("#{SmuleSong.song_dir} does not exist for download")
        end
      end
      Plog.info("Playing #{@playlist.clist.size} songs")
    end

    def listen_for_download(enable: true)
      dir = '/var/folders/vh'
      @listener&.stop
      @wqueue.clear
      @listener = if enable
                    FirefoxWatch
                      .new(@user, dir.strip, @wqueue,
                           verify: true, open: true, logger: PLogger.new('watcher.log'))
                      .start
                  end
    end

    def _list_show(curset:, curitem: nil, start: 0, limit: 10, clear: true)
      bar      = '*' * 10
      songtags = @content.songtags
      table    = TTY::Table.new
      cursor   = TTY::Cursor
      print cursor.clear_screen if clear
      print cursor.move_to
      if curitem
        unless (avatar = curitem[:avatar]).nil?
          lfile = "cache/#{File.basename(avatar)}"
          system "curl -so #{lfile} #{avatar}" unless test('f', lfile)
          print cursor.move_to(0, 0)
          system "imgcat -r 5 <#{lfile}"
        end
        ptags = songtags[curitem[:stitle]] || ''
        isfav = curitem[:isfav] || curitem[:oldfav] ? 'F' : ' '
        xtags = @content.db[:tags].where(sname: ptags.split(',')).map { |r| r[:description] }.join(', ')
        box   = TTY::Box.frame(top: 0, left: 15,
                               width: TTY::Screen.width - 20,
                               height: 5) do
          title = curitem[:title].strip.gsub(/\s+/o, ' ').gsub(/[\u3000\u00a0]/, '')
          <<~EOM
            [#{isfav}] #{title} - #{curitem[:created].strftime('%Y-%m-%d')} - #{bar[1..curitem[:stars].to_i]}
                #{curitem[:record_by]} - #{curitem[:listens]} plays, #{curitem[:loves]} loves - #{ptags[0..9]}
            #{curitem[:message]} - #{xtags}
          EOM
        end
        puts box
      end
      start.upto(start + limit - 1) do |i|
        witem = curset[i]
        next unless witem

        ptags = songtags[witem[:stitle]] || ''
        isfav = witem[:isfav] || witem[:oldfav] ? 'F' : ''
        title = witem[:title].strip.gsub(/\s+/o, ' ').gsub(/[\u3000\u00a0]/, '')

        row   = [i, isfav, title, witem[:record_by],
                 witem[:listens], witem[:loves],
                 bar[1..witem[:stars].to_i],
                 witem[:created].strftime('%Y-%m-%d'), ptags[0..9]]
        table << row
      end
      puts table.render(:unicode, multiline: true,
                        width: TTY::Screen.width,
             alignments: %i[right left left left right right])
      print cursor.clear_screen_down
    end

    def box_msg(msg, options={})
      box = TTY::Box.frame(top: 0, left: 0,
                           width: options[:width] || TTY::Screen.width,
                           height: options[:height] || TTY::Screen.height - 1) do
        msg
      end
      puts box
    end

    def _setprompt
      @prompt = @autoplay ? '[P]' : '[S]'
      @prompt += 'lnswx*+='
      @prompt += " (#{@playlist.filter.inspect})>"
    end

    def play_asong(sitem, to_play: true)
      res = {duration: 0}

      Plog.dump(sitem: sitem)
      @wqueue << sitem
      psecs, msgs = SmuleSong.new(sitem).play(@spage, to_play: to_play)

      case psecs
      when :deleted
        @content.delete_song(sitem)
        return res
      when :error
        return res
      end
      psecs = psecs.to_i
      return res if psecs <= 0

      duration = if (plength = @roptions[:play_length]).nil?
                   psecs
                 else
                   [plength.to_i, psecs].min
                 end

      res[:duration] = duration
      res[:msgs]     = msgs
      res
    end

    def text_wrap(msg, width)
      msg.gsub(/(.{1,#{width}})(\s+|\Z)/, "\\1\n")
    end

    def _show_msgs(sitem, psitem)
      return unless psitem

      table = TTY::Table.new
      pmsg  = psitem[:msgs] || []
      pmsg.each do |usr, msg|
        table << [usr, text_wrap(msg, 80)]
      end
      comments = pmsg.to_json
      data = {
        sid:       sitem[:sid],
        comments:  comments,
      }
      rec = Comment.first(sid: sitem[:sid])
      if rec
        if comments != rec.comments
          rec.update(data)
          rec.save_changes
        end
      else
        Comment.insert(data)
      end
      puts table.render(multiline: true)
    end

    # Run the code and protect all exception from killing the menu
    def _menu_eval
      yield
    rescue StandardError => e
      prompt = TTY::Prompt.new
      Plog.dump_error(e: e, trace: e.backtrace)
      prompt.keypress('[ME] Press any key to continue ...')
    end

    def reload_app
      # begin
      [__FILE__, 'lib/smule*rb'].each do |ptn|
        Dir.glob(ptn).each do |script|
          Plog.info("Loading #{script}")
          eval "load '#{script}'", TOPLEVEL_BINDING, __FILE__, __LINE__
        end
      end
      # rescue => e
      # Plog.dump_error(e: e)
      # end
    end

    HELP_SCREEN = <<~EOH.freeze
            Command:
            ? Help
            a           Toggle autoplay
            C           Cut current playlist to the set
            c           Show comments on song or user
            F           Mark the song as favorite
            f           Filter existing song list
              *=0       Filter songs w/o star
              >=4       Filter song with >= 4 stars
              s=singer  Filter song with singer
              S=singer  Filter song started with singer
            h           Jump to specified song URL
            i           Song Info
            l           List next songs
            L           Set play length
            M           Open song in Music
            n           Goto next (1) song
            p           List played (previous) songs
            R           Reload script
            s           Sort order
            S           Sync with smule (update new songs, collab)
            t           Give new tags to current song
            x           Exit
            *           Give stars to current song
      #{'      '}
            .           Replay current song
            Space       Toogle pause/play
      #{'      '}
            + Add songs matching filter (see down)
            = Replace songs matching filter (see down)
            - Remove songs matching filter (see down)
            / Search and list matching songs
             record_by, recent, title, favorites
      #{'      '}
            Composite:
            F           Set to favorite and add #thvfavs tags (F and bt#thvfavs)
    EOH
    def play_all
      pcount = 0
      _setprompt
      prompt    = TTY::Prompt.new
      sitem     = nil
      @autoplay = true

      # Clear the cookie prompt
      @spage.find_element(:css, 'button.sc-hAsxaJ').click

      loop do
        # Update into db last one played
        @content.update_song(sitem) if sitem

        # Get next song and play
        if (sitem = @playlist.next_song).nil?
          endt = Time.now + 1
        elsif sitem[:record_by] == @user
          _list_show(curset: @playlist.toplay_list, curitem: sitem)
          psitem = play_asong(sitem)
          @spage.add_any_song_tag(@user, sitem)
          @spage.toggle_play(doplay: @autoplay)
          if (duration = psitem[:duration]) <= 0
            next
          end

          endt = Time.now + duration
        else
          _list_show(curset: @playlist.toplay_list, curitem: sitem)
          psitem = play_asong(sitem, to_play: @autoplay)
          if (duration = psitem[:duration]) <= 0
            next
          end

          @spage.add_any_song_tag(@user, sitem)
          @spage.toggle_play(doplay: @autoplay)

          # Turn off autoplay.  Can't do because play/pause will disappear
          # @spage.autoplay_off # if pcount == 0
          pcount += 1
          @playlist.save if (pcount % 10) == 0
          endt = Time.now + duration
        end

        @paused = !@autoplay
        #@paused = @autoplay
        refresh = true
        loop do
          # Show the menu + list
          begin
            if sitem && !@paused
              if refresh
                _list_show(curset: @playlist.toplay_list,
                           clear: false, curitem: sitem)
                _show_msgs(sitem, psitem)
              end
              wait_t = endt - Time.now
              key    = prompt.keypress("#{@prompt} [#{@playlist.remains}.:countdown]",
                                       timeout: wait_t)
            elsif @autoplay
              # In paused mode
              key = prompt.keypress("#{@prompt} [#{@playlist.remains}]")
            else
              # but if autoplay is also off.  We still timeout for next song
              wait_t = endt - Time.now
              key = prompt.keypress("#{@prompt} [#{@playlist.remains}.:countdown]",
                                    timeout: wait_t)
            end
          rescue StandardError => e
            Plog.dump_error(e: e, trace: e.backtrace)
            next
          end

          # Collect user input and process
          begin
            hc, refresh = handle_user_input(key, sitem)
            case hc
            when :pausing
              @paused = !@paused
              Plog.dump_info(paused:@paused)
              remain  = @spage.toggle_play(doplay: !@paused)
              # This is buggy.  If there is limit on playtime, it would
              # be overritten by this
              endt = Time.now + remain if remain > 0
              refresh = false
            when :quit
              return
            when :next
              break
            else
              refresh = true
            end
            break if Time.now >= endt
          rescue StandardError => e
            Plog.error(e)
            sleep(3)
          end
        end
      end
    end

    def show_comment(ftype, sitem)
      require 'tempfile'

      wset = nil
      case ftype
      when :by_singer
        singer = sitem[:record_by].split(',').reject { |f| f == @user }[0]
        wset = Performance.where(Sequel.lit('performances.record_by like ?',
                                            "%#{singer}%"))
                          .order(:created)
                          .join_table(:left, :song_tags, name: :stitle)
      when :by_song
        wset = Performance.where(Sequel.lit('performances.stitle = ?', (sitem[:stitle]).to_s))
      else
        return
      end
      wset = wset.join_table(:inner, :comments,
                             Sequel.lit('performances.sid = comments.sid'))
      fod = Tempfile.new(['comment', '.md'])
      fod.puts <<~EOH
        | Record By | Title / Comment |
        | --------- | --------------- |
      EOH
      wset.each do |sinfo|
        next unless sinfo[:comments]

        comments = JSON.parse(sinfo[:comments])
                       .select { |_c, m| m && !m.empty? }
        next if comments.empty?

        srecord_by = sinfo[:record_by].sub(/,?#{@user},?/, '')
        fod.puts "| **#{srecord_by}** | **[#{sinfo[:title]}](https://smule.com/#{sinfo[:href]})** - #{sinfo[:created]} | "
        comments.each do |cuser, msg|
          fod.puts "| <sup>#{cuser}</sup> | <sup>#{msg}</sup> |"
        end
      end
      fod.close
      system("set -x; open #{fod.path}")
    end

    # rubocop:disable Metrics/AbcSize
    # rubocop:disable Metrics/CyclomaticComplexity
    # rubocop:disable Metrics/MethodLength
    # Return 2 parameters
    # 1. How to handle: :pausing, :quit, :next
    # 2. Whether to refresh display (display content change)
    def handle_user_input(key, sitem)
      prompt = TTY::Prompt.new
      case key
      when ' '
        return [:pausing, 0]
      when '?'
        TTY::Pager.new.page(HELP_SCREEN)
        prompt.keypress('Press any key [:countdown]', timeout: 3)
      when '.'
        @playlist.next_song(increment: -1)
        return [:next, true]
      when /^[+=]/i # Add/replace list
        choices = %w[favs isfav recent record_by my_open my_duets
                     star title my_tags query untagged]
        ftype   = prompt.enum_select('Replacing set.  Filter type?', choices)
        if ftype != 'untagged'
          param   = case ftype
                    when /fav|my_open|my_duets/
                      prompt.yes?('Not tagged yet ?')
                    else
                      prompt.ask("#{ftype} value ?")
                    end
        end
        newset = @content.select_set(ftype.to_sym, param)
        @playlist.add_to_list(newset, replace: key == '=')
      when '*' # Set stars
        sitem[:stars] = prompt.keypress('Value?').to_i if sitem
      when /\d/ # Set stars also
        sitem[:stars] = key.to_i if sitem
      when 'a'
        @autoplay = !@autoplay
        _setprompt
        prompt.keypress("Autoplay is #{@autoplay} [:countdown]", timeout: 3)
      when 'C'
        list_length = prompt.ask('List Length to cut: ').to_i
        if list_length > 0
          @playlist.chop(list_length)
          print TTY::Cursor.clear_screen
        end

      # See comment
      when 'c'
        choices = %i[by_singer by_song]
        ftype   = prompt.enum_select('Comment type?', choices)
        show_comment(ftype, sitem)
        prompt.keypress('Press any key [:countdown]', timeout: 3)

      when 'D'
        if prompt.keypress('Are you sure? ') =~ /^y/i
          @content.delete_song(sitem)
          sitem = nil
          prompt.keypress('Press any key [:countdown]', timeout: 3)
          return [:next, true]
        end

      when 'f' # Set filter
        param = prompt.ask('Filter value?', default: '')
        _menu_eval do
          @playlist.filter = Hash[param.split.map { |fs| fs.split('=') }]
        end
        _setprompt
      when 'F' # Set as favorite and tag
        _menu_eval do
          sitem[:isfav] = true
          @spage.add_any_song_tag(@user, sitem)
          @spage.toggle_play(doplay: @autoplay)
        end

      when 'h'
        unless (url = prompt.ask('URL:')).nil?
          newsongs = SmuleSong.update_from_url(url, update: true)
          @playlist.insert(newsongs)
          return [:next, true]
        end

      when 'i'                            # Song Info
        puts @playlist.cur_info.to_yaml
        prompt.keypress('Press any key to continue ...')

      when 'l'                            # List playlist
        offset      = 10
        toplay_list = @playlist.toplay_list
        while offset < toplay_list.size
          _list_show(curset: toplay_list, start: offset)
          key = prompt.keypress('Press any key to continue ...')
          break if key == 'q'

          offset += 10
        end
        print TTY::Cursor.clear_screen

      when 'L'
        play_length = prompt.ask('Max Play Length: ').to_i
        @roptions[:play_length] = play_length if play_length >= 3

      # Open local file in Music
      when 'M'
        sfile = SmuleSong.new(sitem).ssfile
        Plog.info("open -g '#{sfile}'")
        system("open -g '#{sfile}'")

      when /[>n]/ # Play next song
        @playlist.next_song(increment: 0)
        return [:next, true]

      when 'N'                            # Next n songs
        offset = key == 'N' ? prompt.ask('Next track offset?').to_i : 0
        Plog.info("Skip #{offset} songs")
        @playlist.next_song(increment: offset)
        return [:next, true]
      when 'O'                            # Next n songs
        hlist    = songs_from_notification
        newsongs = hlist.map do |surl|
          SmuleSong.update_from_url(surl, update: true, singer: @user)
        end.flatten.compact
        @playlist.insert(newsongs, newonly: true) unless newsongs.empty?
        return [:next, true]
      when '<'                            # Play prev song
        @playlist.next_song(increment: -2, nextinc: -1)
        return [:next, true]
      when /p/i                           # List history
        offset = key == 'P' ? prompt.ask('Prev track offset?').to_i : 0
        _list_show(curset: @playlist.done_list.reverse, start: offset.to_i)
        prompt.keypress('Press any key [:countdown]', timeout: 3)
        print TTY::Cursor.clear_screen
      when 'R' # Reload script
        reload_app
        prompt.keypress('Press any key [:countdown]', timeout: 3)
      when 's' # Sort current list
        choices = %w[random play love star date title
                     play.d love.d star.d date.d title.d]
        # TBD what if I don't select anything
        @playlist.order = prompt.enum_select('Order?', choices)
      when 'S'
        _menu_eval do
          perfset          = @sapi.get_performances(@user, limit: 500, days: 3)
          newset, updset   = @content.add_new_songs(perfset, isfav: false)
          perfset          = SmuleSong.collect_collabs(@user, 14)
          newset2, updset2 = @content.add_new_songs(perfset, isfav: false)
          newset += newset2
          updset += updset2
          @playlist.insert(newset, newonly: true) unless newset.empty?
          prompt.keypress("#{newset.size} added / #{updset.size} songs updated [:countdown]",
                          timeout: 3)
        end
      when 't' # Set tag
        unless (tag = prompt.ask('Tag value ?')).nil?
          @content.add_tag(sitem, tag)
        end
      when 'T' # Test - when tags start changing
        choices = %w[quit auto_play_off comment like play menu favorite]
        loop do
          case prompt.enum_select('Test mode', choices)
          #when 'auto_play_off'
            #@spage.autoplay_off
          when 'comment'
            puts @spage.comment_from_page
          when 'like'
            @spage.like_song
          when 'play'
            @paused = !@paused
            @spage.toggle_play(doplay: !@paused)
          when 'menu'
            @spage.click_smule_page(:sc_song_menu, delay: 1)
            @spage.find_element(:css, 'body').click
          else
            break
          end
          prompt.keypress('[ME] Press any key to continue ...')
        end
      when 'x'                            # Quit
        return [:quit, true]
      when 'W'
        listen_for_download(enable: true)
        prompt.keypress('Start watching [:countdown]', timeout: 3)
      when 'w'
        listen_for_download(enable: false)
        prompt.keypress('Stop watching [:countdown]', timeout: 3)
      when 'Z'                            # Debug
        Plog.level = 0
        require 'byebug'
        byebug
      end
      [true, true]
    end

    # Go to notification page and collect all joined links
    def songs_from_notification
      @spage.goto('https://www.smule.com/user/notifications')
      selector = 'div.block.recording.recording-audio.recording-listItem a.title'
      links    = @spage.css(selector)
                       .map { |r| "https://www.smule.com#{r[:href]}" }.uniq
      @spage.navigate.back
      Plog.info("Picked up #{links.size} songs from notification")
      links
    end

    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength
  end
end

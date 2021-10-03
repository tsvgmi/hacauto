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
      @logger     = options[:logger] || PLogger.new($stderr)
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
        @logger.info("Updating #{@state_file}")
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
        @logger.info("Skipping #{sitem[:title]}")
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
      @logger.error('No matching song in list')
      nil
    end

    def insert(*songs)
      @clist.insert(@listpos, *songs)
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
      @logger.info("Resort based on #{@order}")
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
          @logger.error "Unknown sort mode: #{@order}.  Known are random|play|love|star|date"
          cselect
        end
      cselect = cselect.reverse if @order =~ /\.d$/
      @logger.info("Sorted #{cselect.size} entries")
      cselect
    end
  end

  # Docs for SmulePlayer
  class SmulePlayer
    STATE_FILE = 'splayer.state'

    def initialize(user, tdir, options={})
      @user       = user
      @options    = options
      @roptions   = {}
      @content    = SmuleDB.instance(user, cdir: tdir)
      @tdir       = tdir
      @scanner    = Scanner.new(user, @options)
      @sapi       = API.new(options)
      @wqueue     = Queue.new
      @playlist   = PlayList.new(File.join(@tdir, STATE_FILE), @content)
      @logger     = options[:logger] || PLogger.new($stderr)
      at_exit do
        @playlist.save
        exit 0
      end
      listen_for_download if @options[:download]
      @logger.info("Playing #{@playlist.clist.size} songs")
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
          <<~EOM
            [#{isfav}] #{curitem[:title]} - #{curitem[:created].strftime('%Y-%m-%d')} - #{bar[1..curitem[:stars].to_i]}
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
        row   = [i, isfav, witem[:title], witem[:record_by],
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
      @prompt = "lnswx*+= (#{@playlist.filter.inspect})>"
    end

    def play_asong(sitem, to_play: true)
      res = {duration: 0}

      Plog.dump(sitem: sitem)
      @wqueue << sitem
      psecs, msgs = SmuleSong.new(sitem).play(@scanner.spage, to_play: to_play)

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
      @logger.dump_error(e: e, trace: e.backtrace)
      prompt.keypress('[ME] Press any key to continue ...')
    end

    HELP_SCREEN = <<~EOH
            Command:
            ? Help
            C           Cut current playlist to the set
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
      prompt = TTY::Prompt.new
      sitem  = nil
      loop do
        # Update into db last one played
        @content.update_song(sitem) if sitem

        # Get next song and play
        if (sitem = @playlist.next_song).nil?
          endt = Time.now + 1
        elsif sitem[:record_by] == @user
          _list_show(curset: @playlist.toplay_list, curitem: sitem)
          psitem = play_asong(sitem)
          @scanner.spage.add_any_song_tag(@user, sitem)
          if (duration = psitem[:duration]) <= 0
            next
          end

          endt = Time.now + duration
        else
          _list_show(curset: @playlist.toplay_list, curitem: sitem)
          psitem = play_asong(sitem)
          if (duration = psitem[:duration]) <= 0
            next
          end

          @scanner.spage.add_any_song_tag(@user, sitem)

          # Turn off autoplay
          @scanner.spage.toggle_autoplay if pcount == 0
          pcount += 1
          @playlist.save if (pcount % 10) == 0
          endt = Time.now + duration
        end

        @paused = false
        refresh = true
        loop do
          # Show the menu + list
          begin
            if sitem && !@paused
              if refresh
                _list_show(curset: @playlist.toplay_list,
                           clear: false, curitem: sitem)
                _show_msgs(sitem, psitem)
                #               if (sitem[:isfav] || sitem[:oldfav]) && sitem[:record_by].start_with?(@user)
                #                 _menu_eval do
                #                   @scanner.spage.add_song_tag('#thvfavs', sitem)
                #                   @scanner.spage.toggle_play(doplay: true)
                #                 end
                #               end
              end
              wait_t = endt - Time.now
              key    = prompt.keypress("#{@prompt} [#{@playlist.remains}.:countdown]",
                                       timeout: wait_t)
            else
              key = prompt.keypress("#{@prompt} [#{@playlist.remains}]")
            end
          rescue StandardError => e
            @logger.dump_error(e: e, trace: e.backtrace)
            next
          end

          # Collect user input and process
          begin
            hc, refresh = handle_user_input(key, sitem)
            case hc
            when :pausing
              @paused = !@paused
              remain  = @scanner.spage.toggle_play(doplay: !@paused)
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
      end
      wset = wset.join_table(:inner, :comments,
                             Sequel.lit('performances.sid = comments.sid'))
      wset.each do |sinfo|
        next unless sinfo[:comments]

        comments = JSON.parse(sinfo[:comments])
                       .select { |_c, m| m && !m.empty? }
        next if comments.empty?

        puts format("\n%<title>-50.50s %<record>-20.20s %<created>s",
                    title: sinfo[:stitle], record: sinfo[:record_by],
                    created: sinfo[:created])
        comments.each do |cuser, msg|
          puts format('  %<cuser>-14.14s | %<msg>s', cuser: cuser, msg: msg)
        end
      end
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
                     star title my_tags query]
        ftype   = prompt.enum_select('Replacing set.  Filter type?', choices)
        param   = case ftype
                  when /fav|my_open|my_duets/
                    prompt.yes?("Not tagged yet ?")
                  else
                    prompt.ask("#{ftype} value ?")
                  end
        if param
          newset = @content.select_set(ftype.to_sym, param)
          @playlist.add_to_list(newset, replace: key == '=')
        end
      when '*' # Set stars
        sitem[:stars] = prompt.keypress('Value?').to_i if sitem
      when /\d/ # Set stars also
        sitem[:stars] = key.to_i if sitem
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
        prompt.keypress('Press any key to continue ...')

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
          @scanner.spage.add_any_song_tag(@user, sitem)
          @scanner.spage.toggle_play(doplay: true)
        end

      when 'h'
        unless (url = prompt.ask('URL:')).nil?
          newsongs = SmuleSong.update_from_url(url, update: true)
          @playlist.insert(*newsongs)
          return [:next, true]
        end

      when 'H'
        @scanner.spage.set_like

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
      when /[>n]/ # Play next song
        @playlist.next_song(increment: 0)
        return [:next, true]
      when 'N'                            # Next n songs
        offset = key == 'N' ? prompt.ask('Next track offset?').to_i : 0
        @logger.info("Skip #{offset} songs")
        @playlist.next_song(increment: offset)
        return [:next, true]
      when '<'                            # Play prev song
        @playlist.next_song(increment: -2, nextinc: -1)
        return [:next, true]
      when /p/i                           # List history
        offset = key == 'P' ? prompt.ask('Prev track offset?').to_i : 0
        _list_show(curset: @playlist.done_list.reverse, start: offset.to_i)
        prompt.keypress('Press any key [:countdown]', timeout: 3)
        print TTY::Cursor.clear_screen
      # rubocop:disable Security/Eval
      when 'R' # Reload script
        _menu_eval do
          begin
            [__FILE__, 'lib/smule*rb'].each do |ptn|
              Dir.glob(ptn).each do |script|
                @logger.info("Loading #{script}")
                eval "load '#{script}'", TOPLEVEL_BINDING, __FILE__, __LINE__
              end
            end
          rescue StandardError => e
            Plog.dump_error(e: e)
          end
          prompt.keypress('Press any key [:countdown]', timeout: 3)
        end
      # rubocop:enable Security/Eval
      when 's' # Sort current list
        choices = %w[random play love star date title
                     play.d love.d star.d date.d title.d]
        # TBD what if I don't select anything
        @playlist.order = prompt.enum_select('Order?', choices)
      when 'S'
        _menu_eval do
          perfset = @sapi.get_performances(@user, limit: 500, days: 2)
          nc, uc = @content.add_new_songs(perfset, isfav: false)
          perfset = SmuleSong.collect_collabs(@user, 10)
          nc2, uc2 = @content.add_new_songs(perfset, isfav: false)
          nc += nc2
          uc += uc2
          prompt.keypress("#{nc} added / #{uc} songs updated [:countdown]",
                          timeout: 3)
        end
      when 't' # Set tag
        unless (tag = prompt.ask('Tag value ?')).nil?
          @content.add_tag(sitem, tag)
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
        if true
          require 'byebug'
          byebug
        else
          require 'pry-byebug'
          binding.pry
        end
      end
      [true, true]
    end
    # rubocop:enable Metrics/AbcSize
    # rubocop:enable Metrics/CyclomaticComplexity
    # rubocop:enable Metrics/MethodLength
  end
end

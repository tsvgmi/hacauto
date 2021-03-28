#!/usr/bin/env ruby
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
  StateFile = "splayer.state"

  class PlayList
    attr :clist, :filter, :listpos

    def initialize(state_file, content, options={})
      @state_file = state_file
      @content    = content
      @options    = options
      @logger     = options[:logger] || PLogger.new(STDERR)
      if test(?f, @state_file)
        config      = YAML.safe_load_file(@state_file)
        if config[:clist]
          @clist      = @content.select_sids(config[:clist])
        end
        @filter     = config[:filter]
        @order      = config[:order]
        @listpos    = config[:listpos]
      end
      @clist      ||= []
      @filter     ||= {}
      @order      ||= 'play'
      @listpos    ||= 0
    end

    def toplay_list
      @clist[@listpos..-1]
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
      open(@state_file, "w") do |fod|
        fod.puts(data.to_yaml)
        @logger.info("Updating #{@state_file}")
      end
    end

    def playable?(sitem)
      if (sitem[:stars].to_i == 1) || sitem[:deleted] ||
         (sitem[:href] =~ /\/ensembles$/)
        return false
      end

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

    def next_song(increment=1, nextinc=1)
      req_file = 'toplay.dat'
      if test(?f, req_file)
        sids = File.read(req_file).split
        @clist.insert(@listpos, *@content.select_sids(sids))
        FileUtils.remove(req_file, verbose:true)
      end
      if @clist.size <= 0
        return nil
      end
      count = 0
      while (count <= @clist.size)
        @cursong = @clist[@listpos]
        @listpos = (@listpos + increment)
        # Should not do mod operation here.  Just start
        if @listpos >= @clist.size
          @listpos = 0
        end
        if playable?(@cursong)
          return @cursong
        end
        count += 1
        increment = nextinc
      end
      @logger.error("No matching song in list")
      nil
    end

    def insert(*songs)
      @clist.insert(@listpos, *songs)
    end

    def remains
      @clist.size - @listpos
    end

    def add_to_list(newset, replace=false)
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
      endpos   = [@listpos+size, @clist.size-1].min
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
          cselect.sort_by { |v| v[:listens]}
        when /^love/
          cselect.sort_by { |v| v[:loves]}.reverse
        when /^star/
          cselect.sort_by { |v| v[:stars].to_i}.reverse
        when /^date/
          cselect.sort_by { |v| created_value(v[:created])}.reverse
        when /^title/
          cselect.sort_by { |v| v[:stitle]}
        else
          @logger.error "Unknown sort mode: #{@order}.  Known are random|play|love|star|date"
          cselect
        end
      if @order =~ /\.d$/
        cselect = cselect.reverse
      end
      @logger.info("Sorted #{cselect.size} entries")
      cselect
    end
  end

  class SmulePlayer
    def initialize(user, tdir, options={})
      @user       = user
      @options    = options
      @roptions   = {}
      @content    = SmuleDB.instance(user, tdir)
      @tdir       = tdir
      @scanner    = Scanner.new(user, @options)
      @sapi       = API.new(options)
      @csong_file = options[:csong_file] || "./cursong.yml"
      @playlist   = PlayList.new(File.join(@tdir, StateFile), @content)
      @logger     = options[:logger] || PLogger.new(STDERR)
      at_exit {
        @playlist.save
        exit 0
      }
      listen_for_download if @options[:download]
      @logger.info("Playing #{@playlist.clist.size} songs")
    end

    def listen_for_download(enable=true)
      dir = '/var/folders/vh'
      if enable
        @listener.stop if @listener
        @listener = FirefoxWatch.
          new(@user, dir.strip, 'cursong.yml',
              verify:true, open:true, logger:PLogger.new('watcher.log')).
          start
      else
        if @listener
          @listener.stop
          @listener = nil
        end
      end
    end

    def _list_show(sitem, psitem, cselect, start, limit, clear=true)
      bar    = '*' * 10
      tags   = @content.tags
      table  = TTY::Table.new
      cursor = TTY::Cursor
      if clear
        print cursor.clear_screen
      end
      print cursor.move_to
      if sitem
        unless (avatar = sitem[:avatar]).nil?
          lfile = "cache/" + File.basename(avatar)
          unless test(?f, lfile)
            system "curl -so #{lfile} #{avatar}"
          end
          print cursor.move_to(0,0)
          system "imgcat -r 5 <#{lfile}"
        end
        ptags = tags[sitem[:stitle]] || ''
        isfav = (sitem[:isfav] || sitem[:oldfav]) ? 'F' : ' '
        box   = TTY::Box.frame(top: 0, left: 15,
                width:TTY::Screen.width-20,
                height:5) do
<<EOM
[#{isfav}] #{sitem[:title]} - #{sitem[:created].strftime("%Y-%m-%d")} - #{bar[1..sitem[:stars].to_i]}
    #{sitem[:record_by]} - #{sitem[:listens]} plays, #{sitem[:loves]} loves - #{ptags[0..9]}
#{(psitem || {})[:snote]}
EOM
        end
        puts box
      end
      start.upto(start+limit-1) do |i|
        witem  = cselect[i]
        next unless witem
        ptags = tags[witem[:stitle]] || ''
        isfav = (witem[:isfav] || witem[:oldfav]) ? 'F' : ''
        row   = [i, isfav, witem[:title], witem[:record_by],
		 witem[:listens], witem[:loves],
		 bar[1..witem[:stars].to_i],
                 witem[:created].strftime("%Y-%m-%d"), ptags[0..9]]
        table << row
      end
      puts table.render(:unicode, multiline:true,
                        width:TTY::Screen.width,
             alignments:[:right, :left, :left, :left, :right, :right])
      print cursor.clear_screen_down
    end

    def box_msg(msg, options={})
      box = TTY::Box.frame(top: 0, left: 0,
              width:options[:width] || TTY::Screen.width,
              height:options[:height] || TTY::Screen.height-1) do
        msg
      end
      puts box
    end

    def _setprompt
      @prompt = "lnswx*+= (#{@playlist.filter.inspect})>"
    end

    def play_asong(sitem)
      res = {duration:0}

      File.open(@csong_file, 'w') do |fod|
        fod.puts sitem.to_yaml
      end
      psecs, msgs = SmuleSong.new(sitem).play(@scanner.spage)

      if psecs == :deleted
        @content.delete_song(sitem)
        return res
      elsif psecs <= 0
        return res
      end
      if (plength = @roptions[:play_length]).nil?
        duration = psecs
      else
        duration = [plength.to_i, psecs].min
      end

      spage = @scanner.spage
      res[:duration] = duration
      res[:snote]    = spage.song_note
      res[:msgs]     = msgs
      res
    end

    def text_wrap(msg, width)
      msg.gsub(/(.{1,#{width}})(\s+|\Z)/, "\\1\n")
    end

    def _show_msgs(sitem, psitem)
      table  = TTY::Table.new
      psitem[:msgs].each do |usr, msg|
        table << [usr, text_wrap(msg, 80)]
      end
      data = {
        sid:       sitem[:sid],
        stitle:    sitem[:stitle],
        record_by: sitem[:record_by],
        comments:  psitem[:msgs].to_json,
      }
      unless (rec = Comment.first(sid:sitem[:sid])).nil?
        rec.update(data)
        rec.save_changes
      end
      puts table.render(multiline:true)
    end

    def _set_favorite(sitem)
      @scanner.spage.set_song_favorite
      sitem[:isfav] = true
    end

    # These are for test hooks mostly where could could not test code due to it
    # being in run loop.  Code could be copied here for testing as the function
    # is redefineable at runtime with 'R' option
    def browser_op(sitem, psitem, *operations)
      operations.each do |data|
        case data
        when 'M'
          _show_msgs(sitem, psitem)
        when 'F'                                # Set favorite song
          _set_favorite(sitem)
        end
      end
    end

    # Run the code and protect all exception from killing the menu
    def _menu_eval
      begin
        yield
      rescue => errmsg
        prompt = TTY::Prompt.new
        @logger.dump_error(errmsg:errmsg, args:args, trace:errmsg.backtrace)
        prompt.keypress("[ME] Press any key to continue ...")
      end
    end

    HelpScreen = <<EOH
Command:
? Help
b Browser   command (see below)
  t#tagname Adding tag name (only for songs started by you)
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

.           Replay current song
Space       Toogle pause/play

+ Add songs matching filter (see down)
= Replace songs matching filter (see down)
- Remove songs matching filter (see down)
/ Search and list matching songs
 record_by, recent, title, favorites

Composite:
F           Set to favorite and add #thvfavs tags (F and bt#thvfavs)
EOH
    def play_all
      pcount  = 0
      _setprompt
      prompt = TTY::Prompt.new
      sitem  = nil
      while true
        # Update into db last one played
        @content.update_song(sitem) if sitem
        unless (sitem = @playlist.next_song).nil?
          _list_show(sitem, nil, @playlist.toplay_list, 0, 10)
          psitem = play_asong(sitem)
          if (duration = psitem[:duration]) <= 0
            next
          end
          # Turn off autoplay
          @scanner.spage.toggle_autoplay if pcount == 0
          pcount  += 1
          if (pcount % 10) == 0
            @playlist.save
          end
          endt = Time.now + duration
        else
          endt = Time.now + 1
        end

        @paused = false
        refresh = true
        while true
          begin
            if sitem && !@paused
              if refresh
                _list_show(sitem, psitem, @playlist.toplay_list, 0, 10, false)
                _show_msgs(sitem, psitem)
                if sitem[:isfav] || sitem[:oldfav]
                  if sitem[:record_by] =~ /^THV_13,/
                    _menu_eval do
                      @scanner.spage.set_song_tag('#thvfavs')
                    end
                  end
                end
              end
              wait_t = endt - Time.now
              key    = prompt.keypress("#{@prompt} [#{@playlist.remains}.:countdown]",
                                       timeout:wait_t)
            else
              key = prompt.keypress("#{@prompt} [#{@playlist.remains}]")
            end
          rescue => errmsg
            @logger.error(errmsg)
            next
          end
          begin
            hc, refresh = handle_user_input(key, sitem, psitem)
            case hc
            when :pausing
              @paused = !@paused
              remain  = @scanner.spage.toggle_play(!@paused)
              # This is buggy.  If there is limit on playtime, it would
              # be overritten by this
              if remain > 0
                endt = Time.now + remain
              end
              refresh = false
            when :quit
              return
            when :next
              break
            else
              refresh = true
            end
            break if (Time.now >= endt)
          rescue => errmsg
            p errmsg
            sleep(3)
          end
        end
      end
    end

    # Return 2 parameters
    # 1. How to handle: :pausing, :quit, :next
    # 2. Whether to refresh display (display content change)
    def handle_user_input(key, sitem, psitem)
      prompt = TTY::Prompt.new
      case key
      when ' '
        return [:pausing, 0]
      when '?'
        TTY::Pager.new.page(HelpScreen)
        prompt.keypress("Press any key [:countdown]", timeout:3)
      when '.'
        @playlist.next_song(-1)
        return [:next, true]
      when /^[\+=]/i                # Add/replace list
        choices = %w(favs isfav recent record_by star title query)
        ftype   = prompt.enum_select('Replacing set.  Filter type?', choices)
        param   = (ftype =~ /fav/) ? '' : prompt.ask("#{ftype} value ?")
        if param
          newset  = @content.select_set(ftype.to_sym, param)
          @playlist.add_to_list(newset, key == '=')
        end
      when '*'                            # Set stars
        if sitem
          sitem[:stars] = prompt.keypress('Value?').to_i
        end
      when /\d/                               # Set stars also
        if sitem
          sitem[:stars] = key.to_i
        end
      when 'b'
        unless (param = prompt.ask('Browser Op alue?')).nil?
          _menu_eval do
            browser_op(sitem, psitem, param)
            prompt.keypress("Press any key [:countdown]", timeout:3)
          end
        end
      when 'C'
        list_length = prompt.ask('List Length to cut: ').to_i
        if list_length > 0
          @playlist.chop(list_length)
          print TTY::Cursor.clear_screen
        end
      when 'D'
        if prompt.keypress('Are you sure? ') =~ /^y/i
          @content.delete_song(sitem)
          sitem = nil
          prompt.keypress("Press any key [:countdown]", timeout:3)
          return [:next, true]
        end
      when 'f'                            # Set filter
        param = prompt.ask('Filter value?', default:'')
        _menu_eval do
          @playlist.filter = Hash[param.split.map { |fs| fs.split('=') }]
        end
        _setprompt
      when 'F'                              # Set as favorite and tag
        _menu_eval do
          _set_favorite(sitem)
          @scanner.spage.set_song_tag('#thvfavs')
        end

      when 'h'
        unless (url = prompt.ask('URL:')).nil?
          newsongs = SmuleSong.update_from_url(url, update:true)
          @playlist.insert(*newsongs)
          return [:next, true]
        end

      when 'H'
        @scanner.spage.set_like

      when 'i'                            # Song Info
        puts @playlist.cur_info.to_yaml
        prompt.keypress("Press any key to continue ...")
      when 'l'                            # List playlist
        offset      = 10
        toplay_list = @playlist.toplay_list
        while offset < toplay_list.size
          _list_show(nil, nil, toplay_list, offset, 10)
          key = prompt.keypress("Press any key to continue ...")
          if key == 'q'
            break
          end
          offset += 10
        end
        print TTY::Cursor.clear_screen
      when 'L'
        play_length = prompt.ask('Max Play Length: ').to_i
        @roptions[:play_length] = play_length if play_length >= 15
      when /[>n]/                          # Play next song
        @playlist.next_song(0)
        return [:next, true]
      when 'N'                            # Next n songs
        offset = (key == 'N') ? prompt.ask('Next track offset?').to_i : 0
        @logger.info("Skip #{offset} songs")
        @playlist.next_song(offset)
        return [:next, true]
      when '<'                            # Play prev song
        @playlist.next_song(-2, -1)
        return [:next, true]
      when /p/i                           # List history
        offset = (key == 'P') ? prompt.ask('Prev track offset?').to_i : 0
        _list_show(nil, nil, @playlist.done_list.reverse, offset.to_i, 10, true)
        prompt.keypress("Press any key [:countdown]", timeout:3)
        print TTY::Cursor.clear_screen
      when 'R'                             # Reload script
        _menu_eval do
          begin
            [__FILE__, "lib/smule*rb"]. each do |ptn|
              Dir.glob(ptn).each do |script|
                @logger.info("Loading #{script}")
                eval "load '#{script}'", TOPLEVEL_BINDING
              end
            end
          rescue => errmsg
            p errmsg
          end
          prompt.keypress("Press any key [:countdown]", timeout:3)
        end
      when 's'                            # Sort current list
        choices = %w(random play love star date title
                     play.d love.d star.d date.d title.d)
                     # TBD what if I don't select anything
        @playlist.order = prompt.enum_select('Order?', choices)
      when 'S'
        _menu_eval do
          perfset   = @sapi.get_performances(@user, limit:50, days:1)
          new_count = @content.add_new_songs(perfset, false)
          perfset   = SmuleSong.collect_collabs(@user, 10)
          new_count += @content.add_new_songs(perfset, false)
          prompt.keypress("#{new_count} songs added [:countdown]",
                          timeout:3)
        end
      when 't'                             # Set tag
        unless (tag = prompt.ask('Tag value ?')).nil?
          @content.add_tag(sitem, tag)
        end
      when 'x'                            # Quit
        return [:quit, true]
      when 'W'
        listen_for_download(true)
        prompt.keypress("Start watching [:countdown]", timeout:3)
      when 'w'
        listen_for_download(false)
        prompt.keypress("Stop watching [:countdown]", timeout:3)
      when 'Z'                            # Debug
        require 'byebug'

        Plog.level = 0
        byebug
      end
      [true, true]
    end
  end
end


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

  class SmulePlayer
    def initialize(user, tdir, options={})
      @user     = user
      @options  = options
      @roptions = {}
      @content  = SmuleDB.instance(user, tdir)
      if test(?f, StateFile)
        config  = YAML.load_file(StateFile)
        @clist  = @content.select_sids(config[:sids])
        @filter = config[:filter]
        @order  = config[:order]
      end
      @clist  ||= {}
      @filter ||= {}
      @order  ||= 'play'
      @played_set = []
      @scanner    = Scanner.new(user, @options)
      @sapi       = API.new(options)
      @csong_file = options[:csong_file] || "./cursong.yml"
      at_exit {
        _save_state(true)
        exit 0
      }
      Plog.info("Playing #{@clist.size} songs")
    end
    
    def _save_state(backup=false)
      data = {
        filter: @filter,
        order:  @order,
        sids:   @clist.map{|r| r[:sid]},
      }.to_yaml
      open(StateFile, "w") do |fod|
        fod.puts(data)
        Plog.info("Updating #{StateFile}")
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
        if avatar = sitem[:avatar]
          lfile = "cache/" + File.basename(avatar)
          unless test(?f, lfile)
            system "curl -so #{lfile} #{avatar}"
          end
          print cursor.move_to(0,0)
          system "imgcat -r 5 <#{lfile}"
        end
        #ptags = (tags[sitem[:stitle]] || []).join(', ')
        ptags = tags[sitem[:stitle]] || ''
        isfav = (sitem[:isfav] || sitem[:oldfav]) ? 'F' : ' '
        box   = TTY::Box.frame(top: 0, left: 15,
                width:TTY::Screen.width-20,
                height:5) do
          content = <<EOM
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
      @prompt = "lnswx*+= (#{@filter.inspect})>"
    end

    def _filter_song(sitem)
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
      end
      state
    end

    def _song_playable?(sitem)
      if (sitem[:stars] && sitem[:stars] <= 1)
        return false
      end
      if sitem[:deleted]
        return false
      end
      unless @options[:myopen]
        if (sitem[:href] =~ /\/ensembles$/)
          return false
        end
      end
      _filter_song(sitem) == :play
    end

    def play_asong(sitem, prompt)
      res = {duration:0}

      File.open(@csong_file, 'w') do |fod|
        fod.puts sitem.to_yaml
      end
      psecs = SmuleSong.new(sitem).play(@scanner.spage)

      if psecs == :deleted
        @content.delete_song(sitem)
        return res
      elsif psecs <= 0
        return res
      end
      if plength = @roptions[:play_length] 
        plength = plength.to_i
      end
      duration = if plength = @roptions[:play_length] 
        [plength.to_i, psecs].min
      else
        psecs
      end

      spage = @scanner.spage
      res[:duration] = duration
      res[:snote]    = spage.get_song_note
      res[:msgs]     = spage.get_comments
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
      if rec = Comment.first(sid:sitem[:sid])
        rec.update(data)
        rec.save_changes
      else
        Comment.insert(data)
      end
      puts table.render(multiline:true)
    end

    def _set_favorite(sitem)
      @scanner.spage.set_song_favorite
      sitem[:isfav] = true
    end

    def _set_smule_song_tag(sitem, tag)
      spage   = @scanner.spage
      content = spage.refresh
      msg     = spage.page.css('div._1ck56r8').text
      if msg =~ /#{tag}/
        Plog.info "Message already containing #{tag}"
        return false
      end
      text = ' ' + tag
      spage.click_and_wait("button._13ryz2x", 1)   # ...
      content  = spage.refresh
      unless editable = spage.page.css("div._8hpz8v")[2]
        Plog.error("Cannot locate edit element")
        return
      end
      editable = editable.text
      if editable == 'Edit'
        spage.click_and_wait("a._117spsl", 1, 1)  # Edit
        spage.type("textarea#message", text, append:true)  # Enter tag
        spage.click_and_wait("input#recording-save")
      else
        Plog.info "Song is not editable"
        spage.click_and_wait("._6ha5u0", 1)
      end
      spage.click_and_wait('button._1oqc74f', 0)
    end

    # These are for test hooks mostly where could could not test code due to it
    # being in run loop.  Code could be copied here for testing as the function
    # is redefineable at runtime with 'R' option
    def browser_op(sitem, psitem, *operations)
      spage = @scanner.spage
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
    def _menu_eval(*args)
      begin
        yield *args
      rescue => errmsg
        prompt = TTY::Prompt.new
        Plog.dump_error(errmsg:errmsg, args:args, trace:errmsg.backtrace)
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
        # Replay the same list again if exhausted
        if @clist.size <= 0
          @clist = @played_set.uniq.select{|s| _filter_song(s) != :skip}
        end
        # Update into db last one played
        @content.update_song(sitem) if sitem
        if sitem = @clist.shift
          unless _song_playable?(sitem)
            next
          end
          _list_show(sitem, nil, @clist, 0, 10)
          psitem = play_asong(sitem, prompt)
          if (duration = psitem[:duration]) <= 0
            next
          end
          @played_set << sitem
          # Turn off autoplay
          @scanner.spage.toggle_autoplay if pcount == 0
          pcount  += 1
          if (pcount % 10) == 0
            _save_state(false)
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
                _list_show(sitem, psitem, @clist, 0, 10, false)
                _show_msgs(sitem, psitem)
                if sitem[:isfav] || sitem[:oldfav]
                  if sitem[:record_by] =~ /^THV_13,/
                    _menu_eval do
                      _set_smule_song_tag(sitem, '#thvfavs')
                    end
                  end
                end
              end
              wait_t = endt - Time.now
              key    = prompt.keypress("#{@prompt} [#{@clist.size}.:countdown]",
                                       timeout:wait_t)
            else
              key = prompt.keypress("#{@prompt} [#{@clist.size}]")
            end
          rescue => errmsg
            Plog.error(errmsg)
            next
          end
          begin
            hc, refresh = handle_user_input(key, sitem, psitem)
            case hc
            when :pausing
              @paused = !@paused
              remain  = @scanner.spage.play_song(!@paused)
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
            #Plog.dump(now:Time.now, endt:endt)
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
        @clist.unshift(sitem) if sitem
        return [:next, true]
      when /^[\+=\/]/i                # Add/replace list
        choices = %w(favs recent record_by star title query)
        ftype   = prompt.enum_select('Replacing set.  Filter type?', choices)
        param   = (ftype == 'favs') ? '' : prompt.ask("#{ftype} value ?")
        if param
          newset  = @content.select_set(ftype.to_sym, param)
          case key
          when '+'
            @clist.concat(sort_selection(newset))
          when '='
            @clist      = sort_selection(newset)
            @played_set = []                # Clear current played list
          when '/'
            offset = 0
            while offset < newset.size
              _list_show(nil, nil, newset, offset, 10)
              key = prompt.keypress("Press any key to continue ...")
              if key == 'q'
                return [:next, true]
              end
              offset += 10
            end
          end
        end
      when '-'                   # Remove from list
        choices = %w(singer star)
        ftype   = prompt.enum_select('Filter type?', choices)
        if param = prompt.ask('Removing filter Value?')
          newset  = @clist.reject {|v|
            case ftype
            when 'singer'
              v[:record_by].downcase.include?(param)
            when 'star'
              v[:stars].to_i >= param.to_i
            else
              false
            end
          }
          @clist = sort_selection(newset)
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
        if param = prompt.ask('Browser Op alue?')
          _menu_eval do
            browser_op(sitem, psitem, param)
            prompt.keypress("Press any key [:countdown]", timeout:3)
          end
        end
      when 'C'
        list_length = prompt.ask('List Length to cut: ').to_i
        if list_length > 0
          # It pulls list_length+1 item because that matches the menu
          # so simpler to use
          @clist = @clist[0..list_length]
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
          @filter = Hash[param.split.map{|fs| fs.split('=')}]
        end
        _setprompt
      when 'F'                              # Set as favorite and tag
        _menu_eval do
          _set_favorite(sitem)
          _set_smule_song_tag(sitem, '#thvfavs')
        end

      when 'h'
        if url = prompt.ask('URL:')
          newsongs = SmuleSong.update_from_url(url, update:true)
          @clist.unshift(*newsongs)
          return [:next, true]
        end

      when 'i'                            # Song Info
        puts({
          filter: @filter,
          order:  @order,
          count:  @clist.size,
          song:   sitem,
        }.to_yaml)
        prompt.keypress("Press any key to continue ...")
      when 'I'
        if param = prompt.ask('SID(s):')
          newsong = @content.select_set(:sid, param)
          if newsong && newsong.size > 0
            sleep(3)
            @clist.unshift(*newsong)
            return [:next, true]
          end
        end
      when 'l'                            # List playlist
        offset = 10
        while offset < @clist.size
          _list_show(nil, nil, @clist, offset, 10)
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
      when /n/i                            # Next n songs
        offset = (key == 'N') ? prompt.ask('Next track offset?').to_i : 0
        Plog.info("Skip #{offset} songs")
        @clist.shift(offset)
        return [:next, true]
      when /p/i                           # List history
        offset = (key == 'P') ? prompt.ask('Prev track offset?').to_i : 0
        _list_show(nil, nil, @played_set.reverse, offset.to_i, 10, true)
        prompt.keypress("Press any key [:countdown]", timeout:3)
        print TTY::Cursor.clear_screen
      when 'R'                             # Reload script
        _menu_eval do
          [__FILE__, "lib/smule*rb"]. each do |ptn|
            Dir.glob(ptn).each do |script|
              Plog.info("Loading #{script}")
              eval "load '#{script}'", TOPLEVEL_BINDING
            end
          end
          prompt.keypress("Press any key [:countdown]", timeout:3)
        end
      when 's'                            # Sort current list
        choices = %w(random play love star date title
                     play.d love.d star.d date.d title.d)
        @order  = prompt.enum_select('Order?', choices)
        @clist  = sort_selection(@clist)
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
        if tag = prompt.ask('Tag value ?')
          @content.add_tag(sitem, tag)
        end
      when 'x'                            # Quit
        return [:quit, true]
      when 'W'
        if dir = prompt.ask('Firefox cache dir (about:cache):')
          @listener.stop if @listener
          @listener = FirefoxWatch.new(@user, dir.strip,
                                       'cursong.yml', verify:true).start
        else
          @listener.stop if @listener
          Plog.info("Stop watching")
        end
      when 'Z'                            # Debug
        require 'byebug'

        byebug
      end
      [true, true]
    end

    def sort_selection(cselect)
      Plog.info("Resort based on #{@order}")
      cselect = case @order
      when /^random/
        cselect.shuffle
      when /^play/
        cselect.sort_by{|v| v[:listens]}
      when /^love/
        cselect.sort_by{|v| v[:loves]}.reverse
      when /^star/
        cselect.sort_by{|v| v[:stars].to_i}.reverse
      when /^date/
        cselect.sort_by{|v| created_value(v[:created])}.reverse
      when /^title/
        cselect.sort_by{|v| v[:stitle]}
      else
        Plog.error "Unknown sort mode: #{@order}.  Known are random|play|love|star|date"
        cselect
      end
      if @order =~ /\.d$/
        cselect = cselect.reverse
      end
      Plog.info("Sorted #{cselect.size} entries")
      cselect
    end
  end
end


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
      @scanner = Scanner.new(user, @options)
      @sapi    = API.new(options)
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

    def _list_show(sitem, psitem, cselect, start, limit)
      bar    = '*' * 10
      tags   = @content.tags
      table  = TTY::Table.new
      cursor = TTY::Cursor
      print cursor.clear_screen
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
      res[:snote]    = spage.page.css('div._1ck56r8').text
      res[:msgs]     = spage.css('div._bmkhah').reverse.map do |acmt|
        user = acmt.css('div._1b9o6jw').text
        msg  = acmt.css('div._1822wnk').text
        [user, msg]
      end
      res
    end

    def text_wrap(msg, width)
      msg.gsub(/(.{1,#{width}})(\s+|\Z)/, "\\1\n")
    end

    def browser_pause(sitem, psitem)
      remain = 0
      spage  = @scanner.spage
      spage.refresh
      if spage.css('button._1oqc74f').size > 0       # Is stopped
        spage.click_and_wait('button._1oqc74f', 0)
        curtime   = spage.css("span._1guzb8h").text.split(':')
        curtime_s = curtime[0].to_i*60 + curtime[1].to_i
        remain    = psitem[:duration] - curtime_s
        Plog.dump_info(msg:"Was stopped.  Playing", remain:remain)
        #Plog.dump_info(curtime:curtime, curtime_s:curtime_s, remain:remain)
      elsif spage.css('button._1s30tn4h').size > 0   # Is playing
        Plog.info("Was playing.  Stopping")
        spage.click_and_wait('button._1s30tn4h', 0)
      else
        Plog.error("Unknown state to toggle")
      end
      remain
    end

    def _show_msgs(psitem)
      table  = TTY::Table.new
      psitem[:msgs].each do |usr, msg|
        table << [usr, text_wrap(msg, 80)]
      end
      puts table.render(multiline:true)
    end

    def _set_favorite(sitem)
      spage = @scanner.spage
      spage.click_and_wait("button._13ryz2x")
      content = spage.refresh
      unless fav = spage.page.css("div._8hpz8v")[0]
        Plog.error("Cannot locate fav element")
        return
      end
      fav = fav.text
      if fav != 'Favorite'
        Plog.info "Song is already favorite"
        spage.click_and_wait("._6ha5u0", 1)
        return false
      end
      sitem[:isfav] = true
      spage.click_and_wait("div._8hpz8v", 1, 0)
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
          _show_msgs(psitem)
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
        if sitem
          @content.update_song(sitem)
        end
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
          if pcount == 0
            @scanner.spage.click_and_wait("div._1jmbcz6h")
          end
          pcount  += 1
          if (pcount % 10) == 0
            _save_state(false)
          end
          endt = Time.now + duration
        else
          endt = Time.now + 1
        end

        paused = false
        while true
          if sitem && !paused
            _list_show(sitem, psitem, @clist, 0, 10)
            _show_msgs(psitem)
            if sitem[:isfav] || sitem[:oldfav]
              if sitem[:record_by] =~ /^THV_13,/
                _menu_eval do
                  _set_smule_song_tag(sitem, '#thvfavs')
                end
              end
            end
            wait_t = endt - Time.now
            key    = prompt.keypress("#{@prompt} [#{@clist.size}.:countdown]",
                                     timeout:wait_t)
          else
            key    = prompt.keypress("#{@prompt} [#{@clist.size}]")
          end
          if key
            case key
            when ' '
              remain = browser_pause(sitem, psitem)
              if remain > 0
                paused = false
                endt   = Time.now + remain
              else
                paused = true
              end
            when '?'
              TTY::Pager.new.page(HelpScreen)
              prompt.keypress("Press any key [:countdown]", timeout:3)
            when '.'
              @clist.unshift(sitem) if sitem
              break
            when /^[\+=\/]/i                # Add/replace list
              choices = %w(favs recent record_by star title query)
              ftype   = prompt.enum_select('Filter type?', choices)
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
                    break if key == 'q'
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
            when 'b'
              if param = prompt.ask('Browser Op alue?')
                _menu_eval do
                  browser_op(sitem, psitem, param)
                  prompt.keypress("Press any key [:countdown]", timeout:3)
                end
              end
            when 'D'
              if prompt.keypress('Are you sure? ') =~ /^y/i
                @content.delete_song(sitem)
                sitem = nil
                prompt.keypress("Press any key [:countdown]", timeout:3)
                break
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
              if param = prompt.ask('URL:')
                param   = param.sub(%r(^https://www.smule.com), '')
                newsong = @content.select_set(:url, param)
                if newsong && newsong.size > 0
                  @clist.unshift(newsong[0])
                  break
                end
              end
            when 'i'                            # Song Info
              puts({
                filter: @filter,
                order:  @order,
                count:  @clist.size,
                song:   sitem,
              }.to_yaml)
              prompt.keypress("Press any key to continue ...")
            when 'l'                            # List playlist
              offset = 10
              while offset < @clist.size
                _list_show(nil, nil, @clist, offset, 10)
                key = prompt.keypress("Press any key to continue ...")
                break if key == 'q'
                offset += 10
              end
            when 'L'
              play_length = prompt.ask('Max Play Length?').to_i
              @roptions[:play_length] = play_length if play_length >= 15
            when /n/i                            # Next n songs
              offset = (key == 'N') ? prompt.ask('Next track offset?').to_i : 0
              Plog.info("Skip #{offset} songs")
              @clist.shift(offset)
              break
            when /p/i                           # List history
              offset = (key == 'P') ? prompt.ask('Prev track offset?').to_i : 0
              _list_show(nil, nil, @played_set.reverse, offset.to_i, 10)
              prompt.keypress("Press any key [:countdown]", timeout:3)
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
                perfset.concat(SmuleSong.collect_collabs(@user, 7))
                new_count = @content.add_new_songs(perfset, false)
                prompt.keypress("#{new_count} songs added [:countdown]",
                                timeout:3)
              end
            when 't'                             # Set tag
              if tag = prompt.ask('Tag value ?')
                @content.add_tag(sitem, tag)
              end
            when 'x'                            # Quit
              return
            when 'Z'                            # Quit
              require 'byebug'

              byebug
            end
          end
          #Plog.dump(now:Time.now, endt:endt)
          break if (Time.now >= endt)
        end
      end
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


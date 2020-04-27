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
      @options = options
      @content = Content.new(user, tdir)
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
      at_exit {
        _save_state(true)
        exit 0
      }
      Plog.info("Playing #{@clist.size} songs")
    end
    
    def _save_state(backup=false)
      @content.writeback(backup)
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
        ptags = (tags[sitem[:stitle]] || []).join(', ')
        isfav = (sitem[:isfav] || sitem[:oldfav]) ? 'F' : ''
        box   = TTY::Box.frame(top: 0, left: 15,
                width:TTY::Screen.width-20,
                height:5) do
          content = <<EOM
[#{isfav}] #{sitem[:title]} - #{sitem[:created].strftime("%Y-%m-%d")} - #{bar[1..sitem[:stars].to_i]}
#{sitem[:record_by]} - #{sitem[:listens]} plays, #{sitem[:loves]} loves - #{ptags}
#{(psitem || {})[:snote]}
EOM
        end
        puts box
      end
      start.upto(start+limit-1) do |i|
        witem  = cselect[i]
        next unless witem
        ptags = (tags[witem[:stitle]] || []).join(', ')
        isfav = (witem[:isfav] || witem[:oldfav]) ? 'F' : ''
        row   = [i, isfav, witem[:title], witem[:record_by],
		 witem[:listens], witem[:loves],
		 bar[1..witem[:stars].to_i],
		 witem[:created].strftime("%Y-%m-%d"), ptags]
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
          state = :skip unless sitem[:record_by].downcase.include?(v)
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
      unless @options[:myopen]
        if (sitem[:href] =~ /\/ensembles$/)
          return false
        end
      end
      _filter_song(sitem) == :play
    end

    def play_asong(sitem, prompt)
      res = {duration:0}
      if (psecs = SmuleSong.new(sitem).play(@scanner.spage)) <= 0
        return res
      end
      if plength = @options[:play_length] 
        plength = plength.to_i
      end
      duration = if plength = @options[:play_length] 
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
        spage.click_and_wait('button._1oqc74f')
        curtime   = spage.css("span._1guzb8h").text.split(':')
        curtime_s = curtime[0].to_i*60 + curtime[1].to_i
        remain    = psitem[:duration] - curtime_s
        Plog.dump_info(msg:"Was stopped.  Playing", remain:remain)
        #Plog.dump_info(curtime:curtime, curtime_s:curtime_s, remain:remain)
      elsif spage.css('button._1s30tn4h').size > 0   # Is playing
        Plog.info("Was playing.  Stopping")
        spage.click_and_wait('button._1s30tn4h')
      else
        Plog.error("Unknown state to toggle")
      end
      remain
    end

    def browser_op(sitem, psitem, *operations)
      begin
        spage = @scanner.spage
        operations.each do |data|
          case data
          when 'M'
            table  = TTY::Table.new
            psitem[:msgs].each do |usr, msg|
              table << [usr, text_wrap(msg, 80)]
            end
            puts table.render(multiline:true)
          when 'F'                                # Set favorite song
            spage.click_and_wait("button._13ryz2x")
            content = spage.refresh
            fav     = spage.page.css("div._8hpz8v")[0].text
            if fav != 'Favorite'
              Plog.info "Song is already favorite"
              spage.click_and_wait("._6ha5u0", 1)
              next
            end
            sitem[:isfav] = true
            spage.click_and_wait("div._8hpz8v", 2, 0)
          when /^t/i                              # Set a tag in msg
            tag = $'.strip
            msg = spage.page.css('div._1ck56r8').text
            if msg =~ /#{tag}/
              Plog.info "Message already containing #{tag}"
              next
            end
            text = ' ' + tag
            spage.click_and_wait("button._13ryz2x")   # ...
            content  = spage.refresh
            editable = spage.page.css("div._8hpz8v")[2].text
            if editable == 'Edit'
              spage.click_and_wait("a._117spsl", 2, 1)  # Edit
              spage.type("textarea#message", text)  # Enter tag
              spage.click_and_wait("input#recording-save")
            else
              Plog.info "Song is not editable"
              spage.click_and_wait("._6ha5u0", 1)
            end
            spage.click_and_wait('button._1oqc74f')
          end
        end
      rescue => errmsg
        Plog.error(errmsg)
      end
    end

    HelpScreen = <<EOH
Command:
? Help
b Browser   command (see below)
  t#tagname Adding tag name (only for songs started by you)
  F         Mark the song as favorite
C           Reload content (if external app update it)
f           Filter existing song list
  *=0       Filter songs w/o star
  >=4       Filter song with >= 4 stars
l           List next songs
p           List played (previous) songs
R           Reload script
n           Goto next (1) song
s           Sort order
t           Give new tags to current song
w           Write database
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
      while true
        # Replay the same list again if exhausted
        if @clist.size <= 0
          @clist = @played_set.uniq.select{|s| _filter_song(s) != :skip}
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
            browser_op(sitem, psitem, "M")
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
              choices = %w(favs recent record_by star title)
              ftype   = prompt.enum_select('Filter type?', choices)
              param   = (ftype == 'favs') ? '' : prompt.ask('Value?')
              if param
                newset  = @content.select_set(ftype.to_sym, param)
                case key
                when '+'
                  @clist.concat(sort_selection(newset))
                when '='
                  @clist = sort_selection(newset)
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
              if param = prompt.ask('Value?')
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
              if param = prompt.ask('Value?')
                browser_op(sitem, psitem, param)
                prompt.keypress("Press any key [:countdown]", timeout:3)
              end
            when 'C'
              @content.refresh
              @clist      = []
              @played_set = []
            when 'f'                            # Set filter
              param = prompt.ask('Value?', default:'')
              @filter = Hash[param.split.map{|fs| fs.split('=')}]
              _setprompt
            when 'F'                              # Set as favorite and tag
              browser_op(sitem, psitem, "F", "t#thvfavs")
              prompt.keypress("Press any key [:countdown]", timeout:3)
            when 'i'                            # Song Info
              puts({
                filter: @filter,
                order:  @order,
                count:  @clist.size,
                song:   sitem,
              }.to_yaml)
              prompt.keypress("Press any key [:countdown]", timeout:3)
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
              @options[:play_length] = play_length if play_length >= 30
            when 'M'
              browser_op(sitem, psitem, key)
              prompt.keypress("Press any key [:countdown]", timeout:3)
            when /n/i                            # Next n songs
              offset = (key == 'N') ? prompt.ask('Offset?').to_i : 0
              Plog.info("Skip #{offset} songs")
              @clist.shift(offset)
              break
            when /p/i                           # List history
              offset = (key == 'P') ? prompt.ask('Offset?').to_i : 0
              _list_show(nil, nil, @played_set.reverse, offset.to_i, 10)
              prompt.keypress("Press any key [:countdown]", timeout:3)
            when 'R'                             # Reload script
              begin
                [__FILE__, "lib/smule_player.rb"]. each do |script|
                  Plog.info("Loading #{script}")
                  eval "load '#{script}'", TOPLEVEL_BINDING
                end
                prompt.keypress("Press any key [:countdown]", timeout:3)
              rescue => errmsg
                Plog.error errmsg
                prompt.keypress("Press any key to continue ...")
              end
            when 's'                            # Sort current list
              choices = %w(random play love star date title
                           play.d love.d star.d date.d title.d)
              @order  = prompt.enum_select('Order?', choices)
              @clist  = sort_selection(@clist)
            when 't'                             # Set tag
              if tag = prompt.ask('Value ?')
                @content.add_tag(sitem, tag)
              end
            when 'w'                            # Write content out
              _save_state(false)
            when 'x'                            # Quit
              return
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


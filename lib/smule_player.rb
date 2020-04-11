#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        smule_player.rb
# Date:        2020-03-25 16:13:09 -0700
# Copyright:   E*Trade, 2020
# $Id$
#---------------------------------------------------------------------------
#++

require 'tty-prompt'
require 'tty-box'
require 'tty-cursor'
require 'tty-table'

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

    def _list_set(sitem, cselect, start, limit)
      bar     = '*' * 10
      tags    = @content.tags
      output  = []
      tb_data = TTY::Table.new
      if sitem
        ptags = (tags[sitem[:stitle]] || []).join(', ')
        isfav = (sitem[:isfav] || sitem[:oldfav]) ? 'F' : ''
        row   = [">>>", isfav, sitem[:title],
		 sitem[:record_by], sitem[:listens], sitem[:loves],
		 bar[1..sitem[:stars].to_i],
		 sitem[:created].strftime("%Y-%m-%d"), ptags]
        tb_data << row
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
        tb_data << row
      end
      puts TTY::Cursor.clear_screen
      puts tb_data.render(:unicode, multiline:true,
                          width:TTY::Screen.width,
             alignments:[:right, :left, :left, :left, :right, :right])
      if sitem
        msg = @scanner.spage.page.css('div._1ck56r8').text
        puts msg
      end
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

    def play_asong(sitem)
      if (sitem[:stars] && sitem[:stars] <= 1)
        return 0
      end
      unless @options[:myopen]
        if (sitem[:href] =~ /\/ensembles$/)
          return 0
        end
      end
      unless _filter_song(sitem) == :play
        return 0
      end

      if (psecs = SmuleSong.new(sitem).play(@scanner.spage)) <= 0
        return 0
      end
      if plength = @options[:play_length] 
        plength = plength.to_i
      end
      if plength = @options[:play_length] 
        [plength.to_i, psecs].min
      else
        psecs
      end
    end

    def browser_op(sitem, *operations)
      begin
        spage = @scanner.spage
        operations.each do |data|
          case data
          when 'F'                                # Set favorite song
            spage.click_and_wait("button._13ryz2x")
            content = spage.refresh
            fav     = spage.page.css("div._8hpz8v")[0].text
            if fav != 'Favorite'
              Plog.info "Song is already favorite"
              spage.click_and_wait("._6ha5u0", 0)
              next
            end
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
              spage.click_and_wait("._6ha5u0", 0)
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
b t#tagname Add tag to the song comment (if allowed)
b F         Make song favorite
C           Reload content (if external app update it)
f *=0       Filter only songs with 0 star (no rating)
f >=4       Filter only songs with 4+ stars
l [offset]  List next songs
p [offset]  List played songs
n [count]   Goto next (1) song
.           Replay current song
s order     Sort order: random[.d], play[.d], love[.d], star[.d], date[.d], title[.d]

+ filter_type pattern Add songs matching filter (see down)
= filter_type pattern Replace songs matching filter (see down)
- filter_type pattern Remove songs matching filter (see down)
/ filter_type pattern Search and list matching songs

w           Write database
x           Exit

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
          _list_set(sitem, @clist, 0, 10)
          if (duration = play_asong(sitem)) <= 0
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
          endt     = Time.now + duration
          prompted = false
        else
          endt = Time.now + 1
        end

        while true
          if sitem
            _list_set(sitem, @clist, 0, 10)
            wait_t = endt - Time.now
            key    = prompt.keypress("#{@prompt} [#{@clist.size}.:countdown]",
                                     timeout:wait_t)
          else
            key    = prompt.keypress("#{@prompt} [#{@clist.size}]")
          end
          if key
            case key
            when '?'
              box_msg HelpScreen
              prompt.keypress("Press any key to continue ...")
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
                  _list_set(sitem, newset, 0, newset.size)
                  prompt.keypress("Press any key to continue ...")
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
              sitem[:stars] = prompt.keypress('Value?').to_i
              _list_set(sitem, @clist, 0, 10)
            when 'b'
              if param = prompt.ask('Value?')
                browser_op(sitem, param)
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
              browser_op(sitem, "F", "t#thvfavs")
              prompt.keypress("Press any key to continue ...")
            when 'i'                            # Song Info
              puts({
                filter: @filter,
                order:  @order,
                count:  @clist.size,
                song:   sitem,
              }.to_yaml)
            when 'l'                            # List playlist
              offset = prompt.ask('Offset?').to_i
              _list_set(sitem, @clist, offset, 10)
              prompt.keypress("Press any key to continue ...")
            when /n/i                            # Next n songs
              offset = (key == 'N') ? prompt.ask('Offset?').to_i : 0
              Plog.info("Skip #{offset} songs")
              @clist.shift(offset)
              break
            when /p/i                           # List history
              offset = (key == 'P') ? prompt.ask('Offset?').to_i : 0
              _list_set(nil, @played_set.reverse, offset.to_i, 10)
              prompt.keypress("Press any key to continue ...")
            when 'R'                             # Reload script
              begin
                [__FILE__, "lib/smule_player.rb"]. each do |script|
                  Plog.info("Loading #{script}")
                  eval "load '#{script}'", TOPLEVEL_BINDING
                end
              rescue => errmsg
                Plog.error errmsg
                prompt.keypress("Press any key to continue ...")
              end
            when 's'                            # Sort current list
              choices = %w(random play love star date title)
              @order  = prompt.enum_select('Order?', choices)
              @clist  = sort_selection(@clist)
            when 't'                             # Set tag
              if tag = prompt.ask('Value ?')
                @content.add_tag(sitem, tag)
                _list_set(sitem, @clist, 0, 10)
              end
            when 'w'                            # Write content out
              _save_state(false)
            when 'x'                            # Quit
              return
            end
            prompted = false
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


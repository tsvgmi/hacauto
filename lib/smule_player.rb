#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        smule_player.rb
# Date:        2020-03-25 16:13:09 -0700
# Copyright:   E*Trade, 2020
# $Id$
#---------------------------------------------------------------------------
#++

require 'tty-prompt'

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
      bar  = '*' * 10
      tags = @content.tags
      #Plog.dump_info(sitem:sitem, size:cselect.size, start:start, limit:limit)
      if sitem
        ptags = (tags[sitem[:stitle]] || []).join(', ')
        puts "\n[***/%3d] %-40.40s %-20.20s %3d %3d %5.5s %s %s" %
          [cselect.size, sitem[:title], sitem[:record_by],
           sitem[:listens], sitem[:loves], bar[1..sitem[:stars].to_i],
           sitem[:created].strftime("%Y-%m-%d"), ptags]
      end
      start.upto(start+limit-1) do |i|
        witem  = cselect[i]
        next unless witem
        ptags  = (tags[witem[:stitle]] || []).join(', ')
        puts "[%3d/%3d] %-40.40s %-20.20s %3d %3d %5.5s %s %s" %
          [i, cselect.size, witem[:title], witem[:record_by],
           witem[:listens], witem[:loves],
           bar[1..witem[:stars].to_i],
           witem[:created].strftime("%Y-%m-%d"), ptags]
      end
    end

    Cmap = {
      'f' => :favs,
      'r' => :recent,
      's' => :record_by,
      '*' => :star,
      't' => :title,
    }

    def _select_set(ftype, value)
      @content.select_set(Cmap[ftype], value)
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

      _list_set(sitem, @clist, 0, 5)
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

    def browser_op(sitem, data)
      #Plog.dump_info(sitem:sitem, data:data)
      begin
        case data
        when /^l/i
          @scanner.spage.click_and_wait("div._1v7cqsk")
        when /^t/i
          text = ' ' + $'.strip + ' '
          @scanner.spage.click_and_wait("button._13ryz2x")   # ...
          @scanner.spage.click_and_wait("a._117spsl", 2, 1)  # Edit
          @scanner.spage.type("textarea#message", text)  # Enter tag
          @scanner.spage.click_and_wait("input#recording-save")
          @scanner.spage.click_and_wait('button._1oqc74f')
        end
      rescue => errmsg
        Plog.error(errmsg)
      end
    end

    HelpScreen = <<EOH
Command:
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

Filter type:
s Singer
t Title
r Latest days [7]
f Favorites (old+new)
* Stars
EOH
    def play_all
      pcount  = 0
      _setprompt
      while true
        # Replay the same list again if exhausted
        if @clist.size <= 0
          @clist = @played_set.uniq.select{|s| _filter_song(s) != :skip}
        end
        if sitem = @clist.shift
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
          unless prompted
            print @prompt
            prompted = true
          end
          if select([$stdin], nil, nil, 1)
            unless ans = $stdin.gets
              return
            end
            case ans = ans.chomp
            when /^\?/i                           # Help
              puts HelpScreen
            when /^\./i                           # Replay current
              @clist.unshift(sitem) if sitem
              break
            when /^([\+=\/])\s*(\S)/i                # Add/replace list
              param       = $'.strip.downcase
              oper, ftype = $1, $2
              newset      = _select_set(ftype, param)
              case oper
              when '+'
                @clist.concat(sort_selection(newset))
              when '='
                @clist = sort_selection(newset)
              when '/'
                _list_set(sitem, newset, 0, newset.size)
              end
            when /^-\s*(s|\*)/i                   # Remove from list
              param = $'.strip.downcase
              ftype = $1
              newset = @clist.reject {|v|
                case ftype
                when 's'
                  v[:record_by].downcase.include?(param)
                when '*'
                  v[:stars].to_i >= param.to_i
                else
                  false
                end
              }
              @clist = sort_selection(newset)
            when /^\*/                            # Set stars
              sitem[:stars] = $'.strip.to_i
              _list_set(sitem, [], 0, 0)
            when /^b/i
              browser_op(sitem, $'.strip)
            when /^C/i                            # Reload content
              @content.refresh
              @clist      = []
              @played_set = []
            when /^f/i                            # Set filter
              @filter = Hash[$'.strip.split.map{|fs| fs.split('=')}]
              _setprompt
            when /^i/i                            # Song Info
              puts({
                filter: @filter,
                order:  @order,
                count:  @clist.size,
                song:   sitem,
              }.to_yaml)
            when /^l/i                            # List playlist
              offset = $'.to_i
              _list_set(sitem, @clist, offset, 10)
            when /^n/i                            # Next n songs
              data = $'.to_i
              Plog.info("Skip #{data} songs")
              @clist.shift(data)
              break
            when /^p/i                            # List playlist
              offset = $'.to_i
              _list_set(nil, @played_set.reverse, offset, 10)
            when /^R/                             # Reload script
              begin
                [__FILE__, "lib/smule_player.rb"]. each do |script|
                  eval "load '#{script}'", TOPLEVEL_BINDING
                end
              rescue => errmsg
                Plog.error errmsg
              end
            when /^s/i                            # Sort current list
              @order = $'.strip
              @clist = sort_selection(@clist)
            when /^t/                             # Set tag
              tag = $'.strip
              @content.add_tag(sitem, tag)
              _list_set(sitem, [], 0, 0)
            when /^w/i                            # Write content out
              _save_state(false)
            when /^x/i                            # Quit
              return
            end
            prompted = false
          end
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


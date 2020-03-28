#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        smule_player.rb
# Date:        2020-03-25 16:13:09 -0700
# Copyright:   E*Trade, 2020
# $Id$
#---------------------------------------------------------------------------
#++

module SmuleAuto
  class SmulePlayer
    def initialize(user, content, clist, options={})
      @options = options
      @content = content
      @clist   = clist
      @options[:no_auth] = true
      @scanner = Scanner.new(user, @options)
      Plog.info("Playing #{@clist.size} songs")
    end

    def _list_set(sitem, cselect, start, limit, tags={})
      bar   = '*' * 10
      ptags = (tags[sitem[:stitle]] || []).join(', ')
      puts "\n[***/%3d] %-40.40s %-20.20s %3d %3d %5.5s %s %s" %
        [cselect.size, sitem[:title], sitem[:record_by],
         sitem[:listens], sitem[:loves], bar[1..sitem[:stars].to_i],
         sitem[:created].strftime("%Y-%m-%d"), ptags]
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

    def _select_set(ftype, value)
      newset = []

      if ftype == 'r'
        days = value.to_i
        days = 7 if days <= 0
        ldate  = Time.now - days*24*3600
      end
      @content.each(@options) do |k, v|
        case ftype
        when 's'
          newset << v if v[:record_by].downcase.include?(value)
        when 't'
          newset << v if v[:stitle].include?(value)
        when 'r'
          newset << v if created_value(v[:created]) >= ldate
        when '*'
          newset << v if v[:stars].to_i >= value.to_i
        end
      end
      Plog.info("Selecting #{newset.size} songs")
      newset
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

      _list_set(sitem, @clist, 0, 3, @content.tags)
      if (psecs = SmuleSong.new(sitem).play(@scanner.spage)) <= 0
        return 0
      end
      if plength = @options[:play_length] 
        plength = plength.to_i
      end
      @pcount  += 1
      if (@pcount % 10) == 0
        @content.writeback(false)
      end
      plength || psecs
    end

    HelpScreen = <<EOH
f *=0       Filter only songs with 0 star (no rating)
f >=4       Filter only songs with 4+ stars
l [offset]  List next songs
n [count]   Goto next (1) song
.           Replay current song
s order     Sort order: random[.d], play[.d], love[.d], star[.d], date[.d], title[.d]
+ s pattern Add singer matching pattern from db to playlist
+ t pattern Add song title matching string
+ r days    Add recent songs from last days
+ * number  Add song with stars from db to playlist
= s pattern Replace current list with singer matching pattern from db
= t pattern Replace song title matching string
= r days    Replace recent songs from last days
= * number  Replace current list with stars matching number from db
- s pattern Remove singer pattern from current list
- * number  Remove song with stars matching number from current llist
w           Write database
x           Exit
EOH
    def play_song_set
      @order  = (@options[:order] || "listens:a")
      @filter = {}
      @pcount = 0
      @clist  = sort_selection(@clist)
      _setprompt
      while true
        if sitem = @clist.shift
          if (duration = play_asong(sitem)) <= 0
            next
          end
          endt = Time.now + duration
          prompted = false
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
            when /^(\+|=)\s*(\S)/i                # Add/replace list
              param       = $'.strip.downcase
              oper, ftype = $1, $2
              newset      = _select_set(ftype, param)
              if oper == '+'
                @clist.concat(newset)
              else
                @clist = newset
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
              @clist = sort_selection(newset)[0..299]
            when /^\*/                            # Set stars
              sitem[:stars] = $'.strip.to_i
              puts sitem.to_json
            when /^f/i                            # Set filter
              @filter = Hash[$'.strip.split.map{|fs| fs.split('=')}]
              _setprompt
            when /^i/i                            # Song Info
              puts sitem.to_json if sitem
            when /^l/i                            # List playlist
              if sitem
                offset = $'.to_i
                _list_set(sitem, @clist, offset, 20, @content.tags)
              end
            when /^n/i                            # Next n songs
              if (data = $'.to_i) > 0
                Plog.info("Skip #{data} songs")
                @clist.shift(data)
              end
              break
            when /^R/                             # Reload script
              begin
                [__FILE__, "lib/smule_player.rb"]. each do |script|
                  eval "load '#{script}'", TOPLEVEL_BINDING
                end
              rescue => errmsg
                Plog.error errmsg
              end
            when /^s/i                            # Sort current list
              order = $'.strip
              @clist = sort_selection(@clist)
            when /^t/                             # Set tag
              tag = $'.strip
              puts "Adding tag #{tag} to #{sitem[:title]}"
              @content.add_tag(sitem, tag)
            when /^w/i                            # Write content out
              @content.writeback(false)
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
        cselect.sort_by{|v| v[:created]}.reverse
      when /^title/
        cselect.sort_by{|v| v[:stitle]}
      else
        Plog.error "Unknown sort mode: #{@order}.  Known are random|play|love|star|date"
        cselect
      end
      if @order =~ /\.d$/
        cselect = cselect.reverse
      end
      cselect
    end
  end
end

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
      order   = (@options[:order] || "listens:a")
      @clist  = SmulePlayer.sort_selection(@clist, order)
      @filter = {}
      if @clist.size > 0
        _setprompt
        self._play_set(@content.tags) do |command, sitem|
          case command
          when /^f/i
            @filter = Hash[$'.strip.split.map{|fs| fs.split('=')}]
            _setprompt
            :nothing
          when /^l/i
            offset = $'.to_i
            [:list, offset]
          when /^n/i
            [:next, $'.to_i]
          when /^(\+|=)\s*(\S)/i
            param       = $'.strip.downcase
            oper, ftype = $1, $2
            newset      = _select_set(ftype, param)
            [oper == '+' ? :addset : :repset, SmulePlayer.sort_selection(newset, order)[0..299]]
          when /^-\s*(s|\*)/i
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
            [:repset, SmulePlayer.sort_selection(newset, order)[0..299]]
          when /^\*/
            sitem[:stars] = $'.strip.to_i
            puts sitem.to_json
            :nothing
          when /^t/
            tag = $'.strip
            puts "Adding tag #{tag} to #{sitem[:title]}"
            @content.add_tag(sitem, tag)
            :nothing
          when /^w/i
            @content.writeback(false)
            :nothing
          when /^x/i
            :exit
          else
            :nothing
          end
        end
      end
    end

    def _play_set(tags)
      pcount = 0
      while true
        if sitem = @clist.shift
          next if (sitem[:stars] && sitem[:stars] <= 1)
          unless @options[:myopen]
            next if (sitem[:href] =~ /\/ensembles$/)
          end
          next unless _filter_song(sitem) == :play
          _list_set(sitem, @clist, 0, 3, tags)
          if (psecs = SmuleSong.new(sitem).play(@scanner.spage)) <= 0
            next
          end
          endt     = Time.now + psecs
          prompted = false

          pcount  += 1
          if (pcount % 10) == 0
            yield('w', sitem)
          end
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
            when /^\?/i
              puts HelpScreen
              prompted = false
              next
            when /^\./i
              @clist.unshift(sitem) if sitem
              break
            when /^i/i
              puts sitem.to_json if sitem
              prompted = false
              next
            when /^R/
              begin
                eval "load '#{__FILE__}'", TOPLEVEL_BINDING
              rescue => errmsg
                Plog.error errmsg
              end
              prompted = false
              next
            when /^s/i
              order = $'.strip
              @clist = self.class.sort_selection(@clist, order)
              prompted = false
              next
            end

            action, data = yield(ans, sitem)
            case action
            when :exit
              return
            when :next
              if data > 0
                Plog.info("Skip #{data} songs")
                @clist.shift(data)
              end
              break
            when :addset
              Plog.info("Adding #{data.size} song to playlist")
              @clist.concat(data)
            when :repset
              Plog.info("Replacing #{data.size} song to playlist")
              @clist = data
            when :list
              if sitem
                offset = data
                _list_set(sitem, @clist, offset, 20, tags)
              end
            end
            prompted = false
          end
          break if (Time.now >= endt)
        end
      end
    end

    def self.sort_selection(cselect, order)
      Plog.info("Resort based on #{order}")
      cselect = case order
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
        Plog.error "Unknown sort mode: #{order}.  Known are random|play|love|star|date"
        cselect
      end
      if order =~ /\.d$/
        cselect = cselect.reverse
      end
      cselect
    end
  end
end

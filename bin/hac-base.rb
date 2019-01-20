#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hac-base.rb
# Date:        2018-04-01 01:50:24 -0700
# $Id$
#---------------------------------------------------------------------------
#++

module HtmlRes
  KeyPos = %w(A A#|Bb B C C#|Db D D#|Eb E F F#|Gb G G#|Ab)
  # Attach play note to the like star
  def key_offset(base_key, new_key)
    base_key = base_key.sub(/m$/, '')
    new_key  = new_key.sub(/m$/, '')
    #Plog.info({base_key:base_key, new_key:new_key}.inspect)
    new_ofs  = KeyPos.index{|f| new_key =~ /^#{f}$/}
    base_ofs = KeyPos.index{|f| base_key =~ /^#{f}$/}
    if new_ofs && base_ofs
      offset = KeyPos.index{|f| new_key =~ /^#{f}$/} - KeyPos.index{|f| base_key =~ /^#{f}$/}
      offset += 12 if offset < 0
      offset
    else
      0
    end
  end
end

class ClickLog
  def initialize(auser)
    @kmap    = {}
    @logfile = "logs/hac_click-#{auser}.log"
    if test(?s, @logfile)
      File.read(@logfile).split("\n").each do |l|
        @kmap[l] = true
      end
    end
    @clogger = File.open(@logfile, "a")
  end

  def was_clicked?(user, link, selector)
    mkey = "#{user}@#{link}@#{selector}"
    if @kmap[mkey]
      Plog.info "Skipping previous action: #{mkey}"
      return true
    end
    return false
  end

  def log_click(user, link, selector)
    if was_clicked?(user, link, selector)
      return true
    end
    mkey = "#{user}@#{link}@#{selector}"
    @clogger.puts(mkey)
    @clogger.flush
    @kmap[mkey] = true
    return false
  end
end

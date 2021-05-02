#!/usr/bin/env ruby
# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        hac-base.rb
# Date:        2018-04-01 01:50:24 -0700
# $Id$
#---------------------------------------------------------------------------
#++

# Docs for module HtmlRes
module HtmlRes
  KEY_POS = %w[A A#|Bb B C C#|Db D D#|Eb E F F#|Gb G G#|Ab].freeze
  # Attach play note to the like star
  def key_offset(base_key, new_key)
    base_key = base_key.sub(/m$/, '')
    new_key  = new_key.sub(/m$/, '')
    # Plog.info({base_key:base_key, new_key:new_key}.inspect)
    new_ofs  = KEY_POS.index { |f| new_key =~ /^#{f}$/ }
    base_ofs = KEY_POS.index { |f| base_key =~ /^#{f}$/ }
    if new_ofs && base_ofs
      offset = KEY_POS.index { |f| new_key =~ /^#{f}$/ } - KEY_POS.index { |f| base_key =~ /^#{f}$/ }
      offset += 12 if offset < 0
      offset
    else
      0
    end
  end
end

# Docs for class ClickLog
class ClickLog
  def initialize(auser)
    @kmap    = {}
    @logfile = "logs/hac_click-#{auser}.log"
    if test('s', @logfile)
      File.read(@logfile).split("\n").each do |l|
        @kmap[l] = true
      end
    end
    @clogger = File.open(@logfile, 'a')
  end

  def was_clicked?(user, link, selector)
    link = link.sub(%r{/$}, '')
    mkey = "#{user}@#{link}@#{selector}"
    if @kmap[mkey]
      Plog.info "Skipping previous action: #{mkey}"
      return true
    end
    false
  end

  def log_click(user, link, selector)
    link = link.sub(%r{/$}, '')
    return true if was_clicked?(user, link, selector)

    mkey = "#{user}@#{link}@#{selector}"
    @clogger.puts(mkey)
    @clogger.flush
    @kmap[mkey] = true
    false
  end
end

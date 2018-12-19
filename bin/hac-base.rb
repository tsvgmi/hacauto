#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hac-base.rb
# Date:        2018-04-01 01:50:24 -0700
# $Id$
#---------------------------------------------------------------------------
#++

module HtmlRes
  def get_page_curl(url)
    `curl -ks #{url}`
  end

  def get_page(url)
    require 'open-uri'

    # Some sites does not have good SSL certs.  That's OK here.
    
    fid  = open(url, ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE)
    page = Nokogiri::HTML(fid.read)
    fid.close
    page
  end

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

class SDriver
  attr_reader :driver, :auser

  def initialize(base_url, options={})
    @url    = base_url
    @auser  = options[:user]
    browser = (options[:browser] || 'firefox').to_sym
    @driver = Selenium::WebDriver.for browser
    Plog.info("Goto #{@url}")
    @driver.navigate.to(@url)
    sleep(1)
  end

  def click_and_wait(selector, wtime=3)
    begin
      Plog.info "Click on #{selector}"
      @driver.find_element(:css, selector).click
      sleep(wtime) if wtime > 0
    rescue => errmsg
      errmsg
    end
  end

  def alert
    @driver.switch_to.alert
  end

  def type(selector, data, options={})
    if data
      Plog.info "Enter on #{selector} - #{data[0..19]}"
      elem = @driver.find_element(:css, selector)
      if options[:clear]
        elem.send_keys(''*120)
      end
      elem.send_keys(data)
    end
  end

  def goto(path)
    if path !~ /^https?:/io
      path = "#{@url}/#{path.sub(%r{^/}, '')}"
    end
    Plog.info "Goto #{path}"
    @driver.navigate.to(path)
  end

  def method_missing(method, *argv)
    @driver.send(method.to_s, *argv)
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
      Plog.debug "Skipping previous action: #{mkey}"
      return true
    end
    @clogger.puts(mkey)
    @clogger.flush
    return false
  end
end

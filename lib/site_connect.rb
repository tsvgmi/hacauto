#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        site_connect.rb
# Date:        2019-01-19 16:50:40 -0800
# $Id$
#---------------------------------------------------------------------------
#++
require File.dirname(__FILE__) + "/../etc/toolenv"
require 'selenium-webdriver'

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
end

class SelPage
  attr_reader :sdriver, :page, :clicks

  def initialize(sdriver)
    @sdriver = sdriver
    @clicks  = 0
    refresh
  end

  def refresh
    @page = Nokogiri::HTML(@sdriver.page_source)
  end

  def find_and_click_links(lselector, rselector, options={})
    links = @page.css(lselector).map {|asong| asong['href']}
    click_links(links, rselector, options)
  end

  def click_links(links, rselector, options={})
    limit = (options[:limit] || 1000).to_i
    if links.size <= 0
      return
    end
    Plog.info("Click #{links.size} links")
    links.each do |link|
      goto(link)
      @sdriver.click_and_wait(rselector, 3)
      @clicks += 1
      break if @clicks >= limit
    end
  end

  def goto(link)
    @sdriver.goto(link)
    sleep(2)
    refresh
  end

  def method_missing(method, *argv)
    @sdriver.send(method.to_s, *argv)
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

class SiteConnect
  attr_reader :driver

  class << self
    def connect_hac(options)
      auth    = options[:auth] || 'thienv:kKtx75LUY9GA'
      identity, password = auth.split(':')
      hac_source = HacSource.new(options)
      sdriver    = SDriver.new(hac_source.base_url, user:identity,
                               browser:options[:browser])
      sdriver.click_and_wait('#login-link', 5)
      sdriver.type('#identity', identity)
      sdriver.type('#password', password)
      sdriver.click_and_wait('#submit-btn')
      sdriver
    end

    def connect_gmusic(options)
      auth    = options[:auth]
      identity, password = auth.split(':')
      sdriver = SDriver.new('https://play.google.com/music', user:identity,
                             browser:options[:browser])
      sdriver.click_and_wait('paper-button[data-action="signin"]')
      sdriver.type('#identifierId', identity + "\n")
      sdriver.type('input[name="password"]', password + "\n")

      STDERR.puts "Confirm authentication on cell phone and continue"
      STDIN.gets
      sdriver
    end

    def connect_zing(options)
      SDriver.new('https://mp3.zing.vn', browser:options[:browser])
    end

    def connect_nhacvn(options)
      SDriver.new('https://nhac.vn', browser:options[:browser])
    end

    def connect_smule(options)
      SDriver.new('https://www.smule.com', browser:options[:browser])
    end

    def connect_smule_download(options)
      SDriver.new('https://sing.salon', browser:options[:browser])
    end
  end
  
  def initialize(site, options={})
    Plog.info "Connect to site: #{site}"
    case site
    when :gmusic
      @driver = SiteConnect.connect_gmusic(options)
    when :zing
      @driver = SiteConnect.connect_zing(options)
    when :nhacvn
      @driver = SiteConnect.connect_nhacvn(options)
    when :smule
      @driver = SiteConnect.connect_smule(options)
    when :smule_download
      @driver = SiteConnect.connect_smule_download(options)
    when :hac
      @driver = SiteConnect.connect_hac(options)
    else
      raise "Unsupported target: #{site}"
    end
  end

  def close
    @driver.close
    @driver = nil
  end
end


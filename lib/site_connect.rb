#!/usr/bin/env rub
# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        site_connect.rb
# Date:        2019-01-19 16:50:40 -0800
# $Id$
#---------------------------------------------------------------------------
#++
require "#{File.dirname(__FILE__)}/../etc/toolenv"
require 'selenium-webdriver'
require 'openssl'
require 'open-uri'

# Docs for HtmlRes
module HtmlRes
  def get_page_curl(url, options={})
    content = `curl -ks #{url}`
    if options[:raw]
      content
    else
      Nokogiri::HTML(content)
    end
  end

  def get_page(url)
    # Some sites does not have good SSL certs.  That's OK here.

    # Plog.dump_info(url:url)
    fid  = URI.parse(url).open(ssl_verify_mode: OpenSSL::SSL::VERIFY_NONE)
    page = Nokogiri::HTML(fid.read)
    fid.close
    page
  end
end

# Docs for SelPage
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
    links = @page.css(lselector).map { |asong| asong['href'] }
    click_links(links, rselector, options)
  end

  def click_links(links, rselector, options={})
    limit = (options[:limit] || 1000).to_i
    return if links.size <= 0

    Plog.info("Click #{links.size} links")
    links.each do |link|
      goto(link)
      @sdriver.click_and_wait(rselector, 3)
      @clicks += 1
      break if @clicks >= limit
    end
  end

  def goto(link, wait=2)
    @sdriver.goto(link)
    sleep(wait)
    refresh
  end

  def css(spec)
    @page.css(spec)
  end

  def method_missing(method, *argv)
    @sdriver.send(method.to_s, *argv)
  end

  def respond_to_missing?(_method)
    true
  end
end

# Docs for SDriver
class SDriver
  attr_reader :driver, :auser

  def initialize(base_url, options={})
    @url     = base_url
    @options = options
    @auser   = options[:user]
    browser  = (options[:browser] || 'firefox').to_sym
    Plog.debug("Goto #{@url} using #{browser}")

    capabilities = Selenium::WebDriver::Remote::Capabilities.firefox(accept_insecure_certs: true)

    foptions = Selenium::WebDriver::Firefox::Options.new(
      prefs: {
        'browser.download.folderList'            => 1,
        'browser.download.dir'                   => Dir.pwd,
        'browser.download.lastDir'               => Dir.pwd,
        'browser.download.defaultFolder'         => Dir.pwd,
        'browser.download.useDownloadDir'        => true,
        'browser.helperApps.neverAsk.saveToDisk' => 'audio/m4a',
      }
    )
    @driver = Selenium::WebDriver.for(browser, desired_capabilities: capabilities,
                                      options: foptions)
    @driver.navigate.to(@url)
    sleep(1)
  end

  def clickit(selector, options={})
    wtime    = options[:wait] ||= 2
    index    = options[:index] ||= 0
    elements = @driver.find_elements(:css, selector)
    Plog.debug "Click on #{selector}[#{index}] (of #{elements.size})"
    if (element = elements[index]).nil?
      Plog.error "Element #{selector}[#{index}] not found"
      return false
    end
    @driver.action.move_to(element.location) if options[:move]
    element.click
    sleep(wtime) if wtime > 0
    true
  rescue StandardError => e
    Plog.error(e)
    false
  end

  def click_and_wait(selector, wtime=2, index=0)
    elements = @driver.find_elements(:css, selector)
    Plog.debug "Click on #{selector}[#{index}] (of #{elements.size})"
    if (element = elements[index]).nil?
      Plog.error "Element #{selector}[#{index}] not found"
      return false
    end
    element.click
    sleep(wtime) if wtime > 0
    true
  rescue StandardError => e
    Plog.error(e)
    false
  end

  def alert
    @driver.switch_to.alert
  end

  def type(selector, data, options={})
    return unless data

    Plog.debug "Enter on #{selector} - #{data[0..19]}"
    begin
      elem = @driver.find_element(:css, selector)
      elem.clear unless options[:append]
      elem.send_keys(data)
    rescue Selenium::WebDriver::Error::NoSuchElementError => e
      Plog.error(e)
      sleep(3)
    end
  end

  def goto(path)
    path = "#{@url}/#{path.sub(%r{^/}, '')}" if path !~ /^https?:/io
    Plog.debug "Goto #{path}"
    @driver.navigate.to(path)
  end

  def method_missing(method, *argv)
    @driver.send(method.to_s, *argv)
  end

  def respond_to_missing?(_method)
    true
  end
end

# Docs for SiteConnect
class SiteConnect
  attr_reader :driver

  class << self
    def connect_hac(options)
      auth = options[:auth]
      identity, password = auth.split(':')
      sdriver = SDriver.new(options[:url], user: identity,
                               browser: options[:browser],
                               verbose: options[:verbose])
      sdriver.click_and_wait('#login-link', 5)
      sdriver.type('#identity', identity)
      sdriver.type('#password', password)
      sdriver.click_and_wait('#submit-btn')
      sdriver
    end

    def connect_gmusic(options)
      auth = options[:auth]
      identity, password = auth.split(':')
      sdriver = SDriver.new(options[:url], user: identity,
                             browser: options[:browser],
                             verbose: options[:verbose])
      sdriver.click_and_wait('paper-button[data-action="signin"]')
      sdriver.type('#identifierId', "#{identity}\n")
      sdriver.type('input[name="password"]', "#{password}\n")

      warn 'Confirm authentication on cell phone and continue'
      $stdin.gets
      sdriver
    end

    def connect_smule(options)
      sdriver = SDriver.new(options[:url], options)
      if !options[:skip_auth] && !(auth = options[:auth]).nil?
        sdriver.goto('/user/login')
        identity, password = auth.split(':')
        sleep(3)
        # sdriver.click_and_wait('div.sc-dFJsGO.jSZyoC', 1, 3)
        sdriver.click_and_wait('span.sc-dUrnRO.AXFeE', 1, 3)
        sdriver.type('input[name="snp-username"]', "#{identity}\n")
        sleep 3
        sdriver.type('input[name="snp-password"]', "#{password}\n")
      end
      sdriver
    end

    def connect_singsalon(options)
      sdriver = SDriver.new('https://sing.salon', options)
      if !options[:skip_auth] && !(auth = options[:auth]).nil?
        identity, password = auth.split(':')
        sdriver.click_and_wait('#elUserSignIn')
        sdriver.type('input[name="auth"]', "#{identity}\n")
        sdriver.type('input[name="password"]', "#{password}\n")
        sdriver.click_and_wait('#elSignIn_submit')
      end
      sdriver
    end

    def connect_other(options)
      SDriver.new(options[:url], options)
    end
  end

  def initialize(site, options={})
    Plog.info "Connect to site: #{site}"
    config = YAML.safe_load_file('access.yml')[site.to_s]
    raise "Unsupported target: #{site}" unless config

    config.update(options.transform_keys(&:to_sym).compact)
    @driver = case site
              when :gmusic
                SiteConnect.connect_gmusic(config)
              when :smule
                SiteConnect.connect_smule(config)
              when :hac
                SiteConnect.connect_hac(config)
              when :singsalon
                SiteConnect.connect_singsalon(config)
              else
                SiteConnect.connect_other(config)
              end
  end

  def close
    @driver.close
    @driver = nil
  end
end

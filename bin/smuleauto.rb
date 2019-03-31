#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        hacauto.rb
# Date:        2017-07-29 09:54:48 -0700
# Copyright:   E*Trade, 2017
# $Id$
#---------------------------------------------------------------------------
#++
require File.dirname(__FILE__) + "/../etc/toolenv"
require 'nokogiri'
require 'yaml'
require 'cgi'
require 'byebug'
require 'core'
require 'site_connect'

module SmuleAuto
  extendCli __FILE__

  class Content
    attr_reader :content

    def initialize(user, cdir='.')
      @user  = user
      @cdir  = cdir
      @cfile = "#{cdir}/content-#{user}.yml"
      if test(?f, @cfile)
        @content = YAML.load_file(@cfile)
        if @content.is_a?(Array)
          content, @content = @content, {}
          content.each do |r|
            @content[r[:href]] = r
          end
        end
      else
        @content = {}
      end
    end

    def writeback
      # Backup copy to my home
      cfile = ENV['HOME'] + "/content-#{@user}.yml"
      [@cfile, cfile].each do |afile|
        File.open(afile, 'w') do |fod|
          Plog.info("Writing #{@content.size} entries to #{afile}")
          fod.puts @content.to_yaml
        end
      end
      self
    end

    def add_new(block)
      now = Time.now
      block.each do |r|
        r[:updated_at]     = now
        r[:sid]            = File.basename(r[:href])
        @content.delete(r[:href])
        @content[r[:sid]] = r
      end
      self
    end

    def list
      block = []
      @content.each do |href, r|
        title          = r[:title].scrub
        record_by      = r[:record_by].join(', ')
        block << [title, record_by]
      end
      block.sort_by {|t, r| "#{t.downcase}:#{r}"}.each do |title, record_by|
        puts "%-50.50s %s" % [title, record_by]
      end
      self
    end
  end

  class << self

    def _scan_user_list(user, options={})
      result = []
      pages  = (options[:pages] || 20).to_i
      _connect_site(:smule) do |spage|
        spage.goto(user)
        Plog.info "Scroll to end of page"
        (1..pages).each_with_index do |apage, index|
          spage.execute_script("window.scrollTo(0,1000000)")
          sleep 0.5
          #Plog.info "Loop #{index}"
        end
        spage.refresh
        #sitems = spage.page.css(".profile-content-block .recording-listItem")
        sitems       = spage.page.css("._8u57ot")
        collab_links = []
        sitems.each do |sitem|
          #if plink = sitem.css('a.playable')[0]
          plink = sitem.css('a._1sgodipg')[0]
          next unless plink
          next if sitem.css('._1wii2p1').size <= 0
          #record_by = sitem.css('.recording-by a').map{|rb| rb['title']}
          since = sitem.css('._1wii2p1')[2].text
          if options[:mysongs]
            if collabs = sitem.css('a._1ce31vza')[0]
              href = collabs['href']
              if href =~ /ensembles$/
                if (since =~ /(hr|d)$/)
                  collab_links << collabs['href']
                end
              end
            end
          end
          record_by = sitem.css('._1wcgsqp').map{|rb| rb.text.strip}
          result << {
            title:     plink.text.strip,
            href:      plink['href'],
            record_by: record_by,
            listens:   sitem.css('._1wii2p1')[0].text.to_i,
            loves:     sitem.css('._1wii2p1')[1].text.to_i,
            since:     since,
            avatar:    (sitem.css('img')[0] || {})['src'],
          }
        end

        s_singers = (options[:singers] || "").split(',').sort
        collab_links.each do |alink|
          spage.goto(alink)
          sitems       = spage.page.css(".duets.content .recording-listItem")
          sitems.each do |sitem|
            plink = sitem.css('a.playable')[0]
            next unless plink
            record_by = sitem.css('.recording-by a').map{|rb| rb['title']}
            if s_singers.size > 0
              if (s_singers & record_by) != record_by
                Plog.dump_info(msg:'Skip download for singers', s_singers:s_singers, record_by:record_by)
                next
              end
            end
            result << {
              title:     plink['title'].strip,
              href:      plink['href'],
              record_by: record_by,
              listens:   sitem.css('.stat-listens').first.text.to_i,
              loves:     sitem.css('.stat-loves').first.text.to_i,
              since:     sitem.css('.stat-timeago').first.text.strip,
              avatar:    plink['data-src'],
            }
          end
        end
      end
      Plog.info("Found #{result.size} songs")
      result
    end

    def _download_list(flist, tdir)
      options = getOption
      flist   = flist.select do |afile|
        odir  = tdir + "/#{afile[:record_by].sort.join('-')}"
        FileUtils.mkdir_p(odir, verbose:true) unless test(?d, odir)
        title = afile[:title].strip.gsub(/\//, '-')
        afile[:ofile] = File.join(odir, title + '.m4a')
        !test(?s, afile[:ofile])
      end
      if options[:limit]
        limit = options[:limit].to_i
        flist = flist[0..limit-1]
      end
      _connect_site(:smule_download) do |spage|
        flist.each do |afile|
          Plog.dump_info(afile:afile)
          surl   = "https://smule.com#{afile[:href]}"
          spage.goto('smule-downloader')
          spage.find_element(id:'url').clear
          spage.type('#url', surl)
          spage.click_and_wait('form input.ipsButton')
          spage.execute_script("window.scrollTo(0,1000)")
          spage.click_and_wait('a[download]')
          media_url = spage.current_url

          # Route to null in case quote causing -o to not take effect
          command   = "curl -o \"#{afile[:ofile]}\" \"#{media_url}\" >/dev/null"
          Plog.info("+ #{command}")
          system command
        end
      end
    end

    def _connect_site(site=:smule)
      if @sconnector
        do_close = false
      else
        @sconnector = SiteConnect.new(site, getOption)
        do_close    = true
      end
      yield SelPage.new(@sconnector.driver)
      if do_close
        @sconnector.close
        @sconnector = nil
      end
    end

    def download_for_user(user, tdir='.')
      options = getOption
      if options[:quick]
        result = Content.new(user, tdir).content
      else
        result = _scan_user_list(user, getOption)
        Content.new(user, tdir).add_new(result).writeback if tdir
      end
      if result.size <= 0
        Plog.info("Nothing found to download")
        return true
      end
      _download_list(result, tdir)
    end

    def download_from_file(sfile, tdir='.')
      _download_list(YAML.load_file(sfile), tdir)
    end

    def scan_user_list(user, tdir=nil)
      result = _scan_user_list(user, getOption)
      Content.new(user, tdir).add_new(result).writeback if tdir
      result.to_yaml
    end

    def show_content(user, tdir='.')
      Content.new(user, tdir).list
      true
    end

  end
end

if (__FILE__ == $0)
  SmuleAuto.handleCli(
    ['--auth',    '-a', 1],
    ['--browser', '-b', 1],
    ['--limit',   '-l', 1],
    ['--mysongs', '-m', 0],
    ['--pages',   '-p', 1],
    ['--quick',   '-q', 0],
    ['--singers', '-s', 1],
  )
end

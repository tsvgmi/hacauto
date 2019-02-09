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

class SmuleAuto
  extendCli __FILE__

  class << self
    def _scan_user_list(user)
      result = []
      require 'byebug'

      byebug
      _connect_site(:smule) do |spage|
        spage.goto(user)
        Plog.info "Scroll to end of page"
        (1..10).each_with_index do |apage, index|
          spage.execute_script("window.scrollTo(0,1000000)")
          sleep 0.5
          #Plog.info "Loop #{index}"
        end
        spage.refresh
        #sitems = spage.page.css(".profile-content-block .recording-listItem")
        sitems = spage.page.css("._8u57ot")
        sitems.each do |sitem|
          #if plink = sitem.css('a.playable')[0]
          if plink = sitem.css('a._1sgodipg')[0]
            next if sitem.css('._1wii2p1').size <= 0
            #record_by = sitem.css('.recording-by a').map{|rb| rb['title']}
            record_by = sitem.css('._1acrv77g .false').map{|rb| rb.text.strip}
            result << {
              title:     plink.text.strip,
              href:      plink['href'],
              record_by: record_by,
              #listens:   sitem.css('.stat-listens').first.text.to_i,
              listens:   sitem.css('._1wii2p1')[0].text.to_i,
              #loves:     sitem.css('.stat-loves').first.text.to_i,
              loves:     sitem.css('._1wii2p1')[1].text.to_i,
            }
          end
        end
      end
      Plog.info("Found #{result.size} songs")
      result
    end

    def download_for_user(user, tdir='.')
      _download_list(_scan_user_list(user), tdir)
    end

    def download_from_file(sfile, tdir='.')
      _download_list(YAML.load_file(sfile), tdir)
    end

    def _download_list(flist, tdir)
      options = getOption
      flist   = flist.select do |afile|
        odir  = tdir + "/smule/#{afile[:record_by].join('-')}"
        FileUtils.mkdir_p(odir, verbose:true) unless test(?d, odir)
        title = afile[:title].strip
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
  end
end

if (__FILE__ == $0)
  SmuleAuto.handleCli(
    ['--auth',    '-a', 1],
    ['--browser', '-b', 1],
    ['--limit',   '-l', 1],
  )
end

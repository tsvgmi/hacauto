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
          if options[:mysongs]
            if collabs = sitem.css('a._1ce31vza')[0]
              href = collabs['href']
              if href =~ /ensembles$/
                collab_links << collabs['href']
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
          }
        end

        collab_links.each do |alink|
          spage.goto(alink)
          sitems       = spage.page.css(".duets.content .recording-listItem")
          sitems.each do |sitem|
            plink = sitem.css('a.playable')[0]
            next unless plink
            record_by = sitem.css('.recording-by a').map{|rb| rb['title']}
            result << {
              title:     plink['title'],
              href:      plink['href'],
              record_by: record_by,
              listens:   sitem.css('.stat-listens').first.text.to_i,
              loves:     sitem.css('.stat-loves').first.text.to_i,
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

    def download_for_user(user, tdir='.')
      result = _scan_user_list(user, getOption)
      if tdir
        File.open("#{tdir}/content.yml") do |fod|
          fod.puts result.to_yaml
        end
      end
      _download_list(result, tdir)
    end

    def download_from_file(sfile, tdir='.')
      _download_list(YAML.load_file(sfile), tdir)
    end

    def scan_user_list(user, tdir=nil)
      result = _scan_user_list(user, getOption)
      if tdir
        File.open("#{tdir}/content.yml") do |fod|
          fod.puts result.to_yaml
        end
      end
      result.to_yaml
    end

    def show_content(tdir='.')
      data = YAML.load_file("#{tdir}/content.yml")
      data.map do |r|
        #title     = r[:title].encode('UTF-8', :invalid => :replace, :undef => :replace)
        title     = r[:title].scrub
        record_by = r[:record_by].join(', ')
        [title, record_by]
      end.sort_by {|t, r| "#{t.downcase}:#{r}"}.each do |title, record_by|
        puts "%-50.50s %s" % [title, record_by]
      end
      nil
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
    ['--singers', '-s', 1],
  )
end

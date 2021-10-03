#!/usr/bin/env ruby
# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        core.rb
# Date:        Tue Nov 13 15:52:52 -0800 2007
# $Id: core.rb 6 2010-11-26 10:59:34Z tvuong $
#---------------------------------------------------------------------------
#++

# A laod file with more options
module YAML
  def self.safe_load_file(file, options={})
    options[:filename] = file
    load(File.read(file), options)
  end
end

# Thor Extension
module ThorAddition
  def self.included(klass)
    klass.class_eval do
      def self.exit_on_failure?
        true
      end
    end
  end

  def cli_wrap
    if ENV['BYEBUG'] || ENV['PRYBUG']
      say_status(Time.now, "#{File.basename(__FILE__)}:#{__LINE__} Entering debug mode", :yellow)
      ENV.delete('BYEBUG')
      ENV.delete('PRYBUG')
      if true
        require 'pry-byebug'
        binding.pry
      else
        require 'byebug'
        byebug
      end
    end
    Signal.trap('SIGINT')  { exit(1) }
    Signal.trap('SIGQUIT') do
      Plog.info('Quitting from signal.')
      exit(0)
    end

    @logger = if options[:logfile]
                PLogger.new(value)
              else
                PLogger.new($stderr)
              end

    result = yield

    case result
    when FalseClass
      return(1)
    when TrueClass
      return(0)
    when String
      puts result
    else
      puts result.inspect
    end
    0
  end

  def writable_options
    options.transform_keys(&:to_sym)
  end
end

def progress_set(wset, title=nil)
  title ||= caller[0].split.last.gsub(/['"`]/, '')
  tstring = format('%<title>-16.16s %<size>3.3d [:bar] :percent',
                   title: title, size: wset.size)
  bar     = TTY::ProgressBar.new(tstring, total: wset.size)
  Plog.dump(set: wset)
  wset.each do |entry|
    break unless yield entry, bar

    bar.advance
  end
end

# Functions to support CLI interaction (i.e. options processing,
# help, result interpretation, exit handling)
module Cli
  def set_options(opt)
    @options ||= {}
    @options.merge!(opt)
  end

  def get_option(name=nil)
    @options ||= {}
    name ? @options[name] : @options
  end

  # Common handling of most CLI facing script.  It parse the command
  # line, set to class option, invoke class method if so specified.
  # If not, it yield back to object handler.  It then process the
  # result for output back to the shell.
  #
  # Processing is as followed:
  # * If --class option is specified, or if the class does not have
  #   any instance method, the command will be sent to class method
  # * If there is a processing block, yield(opt) is called to let
  #   the class handle the argument parsing.
  # * If the class respond to cliNew to instantiate default cli object,
  #   it will be called to instantiate an instance, and the rest of
  #   arguments sent to it
  # * Otherwise, the first argument is used as parameter to the
  #   object instantiation, and the rest of the argument is passed to
  #   it.
  #
  # Return handling (from class/object)
  #
  # * If the class support cliResult method, it will be called with
  #   the result and object (for instance invocation).
  # * Otherwise, a default handling of the result is done (i.e.
  #   printing of output and set exit cod)
  def handle_cli(*optset)
    imethods = instance_methods(false)
    optset << ['--class', '-c'] unless imethods.empty?
    @cli_options = optset
    opt = Cli.parse_options(*optset)
    set_options(opt)
    obj = nil
    if ARGV.empty?
      cli_usage
      return false
    end
    if opt[:class] || (imethods.size <= 0)
      method = ARGV.shift.gsub(/-/, '_')
      result = send(method, *ARGV)
    elsif block_given?
      result = yield opt
    # Class handle CLI instantiation?
    elsif respond_to?(:cliNew)
      obj = cliNew
      method = ARGV.shift.gsub(/-/, '_')
      result = obj.send(method, *ARGV)
    else
      obj    = new(ARGV.shift)
      method = ARGV.shift.gsub(/-/, '_')
      result = obj.send(method, *ARGV)
    end

    # Class handle result?
    if respond_to?(:cli_result)
      cli_result(result, obj)
    else
      Cli.shell_result = result
    end
  end

  # Print the message on cli usage (flag/method) and exit script
  def cli_usage
    warn "#{File.basename($PROGRAM_NAME)} #{Cli.show_options(@cli_options).join(' ')} [object] method ...'"
    Cli.class_usage(self)
  end

  # Print a prompt and wait for y/n answer
  def self.confirm(_prompt, default='n')
    $stderr.print ' # {prompt} (y/n) [n]? '
    ans = $stdin.gets
    ans = default if !ans || (ans == '')
    ans =~ /[Yy]/ ? true : false
  end

  # Print a message and just wait till user press enter
  def self.pause(msg='... Press return to continue ...')
    $stderr.print msg
    $stdin.gets
  end

  # Similar to ksh select functionality.  Select a member from an
  # input list
  def self.select(alist, aprompt=nil)
    maxwidth = 10
    alist.each do |entry|
      maxwidth = entry.size if entry.size > maxwidth
    end
    swidth = ENV['COLUMNS'] || 80
    swidth = swidth.to_i - 2
    cols   = swidth / (maxwidth + 5)
    cols   = 1 if cols <= 0
    pwidth = (swidth / cols) - 5
    pcol   = (alist.size + cols - 1) / cols
    loop do
      0.upto(pcol - 1) do |ridx|
        0.upto(cols - 1) do |cidx|
          idx   = ridx + cidx * pcol
          entry = alist[idx]
          $stderr.print(format("%2d. %-#{pwidth}s ", idx + 1, entry)) if entry
        end
        $stderr.puts
      end
      if block_given?
        ans = yield
      else
        $stderr.print "#{aprompt}: "
        ans = $stdin.gets
      end
      return nil unless ans

      ans.chomp!
      next if ans == ''
      return alist[ans.to_i - 1] if ans =~ /^[0-9]+$/

      break
    end
    nil
  end

  # Print the usage message for the class (instance and class methods)
  # to be used in display help
  def self.class_usage(klass)
    defs = {}
    mlist = klass.instance_methods(false).grep(/^[^_]/).map do |amethod|
      ['', amethod, klass.instance_method(amethod).arity]
    end +
            (klass.singleton_methods - Cli.instance_methods).map do |amethod|
              ["#{klass}.", amethod, klass.method(amethod).arity]
            end
    mlist.sort.each do |c, f, m|
      if defs[f]
        warn "  - #{c}#{f}(#{defs[f]})"
      else
        vlist =
          if m < 0
            "#{Array.new(-m, 'v').join(', ')}, ..."
          else
            Array.new(m, 'v').join(', ')
          end
        warn "  - #{c}#{f}(#{vlist})"
      end
    end
    $stderr.print "<Return> to quit or 'h' for help ..."
    result = $stdin.gets.chomp
    exit unless result =~ /^[hH]/
    exec "tman -r #{$PROGRAM_NAME}"
  end

  # Wait for an interval seconds and print progress dot ...
  def self.wait(interval, comment=nil)
    $stderr.print comment.to_s if comment
    $stderr.print "[#{interval}]: "
    interval.downto(1) do
      $stderr.print '.'
      $stderr.flush
      sleep(1)
    end
    warn ''
  end

  # Map output to shell (at exit) for ruby class output
  def self.shell_result=(result)
    case result
    when TrueClass
      exit(0)
    when FalseClass
      exit(1)
    when String
      puts result
    else
      puts result.inspect
    end
    exit(0)
  end

  def self.show_options(options)
    options.map do |long, short, type, _default|
      if type == 1
        "[#{long}|#{short} value]"
      else
        "[#{long}|#{short}]"
      end
    end
  end

  # Similar to parse, but model after perl getopt - i.e. all setting
  # is done to a returned hash.  That way, actual handling for option
  # could be defered, or the hash could be used directly as part of
  # the runtime configuration
  #
  # options is a list of tuple: long name, short name, type, default
  def self.parse_options(*options)
    require 'getoptlong'

    option = {}
    newopt = options.collect do |optspec|
      opt, tmp, type, default = optspec
      if type.nil?
        type = GetoptLong::NO_ARGUMENT
        optspec[2] = type
      end
      optname = opt[2..]
      option[optname.intern] = default
      [opt, tmp, type]
    end
    begin
      GetoptLong.new(*newopt).each do |opt, arg|
        optname = opt[2..]
        option[optname.intern] = arg == '' ? true : arg
      end
    rescue StandardError => e
      puts e
      puts "#{File.basename($PROGRAM_NAME)} #{show_options(options).join(' ')} ...."
    end
    option
  end
end

# Pf definition
module Pf
  def self.hostaddr(name)
    require 'socket'

    Socket.getaddrinfo(name, 0, nil, Socket::SOCK_STREAM)[0][3]
  end

  def self.hostname(addr, shortform: true)
    require 'socket'

    result = Socket.getaddrinfo(addr, 0, nil, Socket::SOCK_STREAM)[0][2]
    result.sub!(/\..*$/, '') if shortform && (result !~ /^[0-9.]+$/)
    result
  end

  # Run a system command with optional trace
  def self.system(command, trace=nil, logfile=nil)
    warn "+ #{command}" if trace
    Plog.debug("+ #{command}")
    command = "(time #{command} 2>&1; echo \":exit: $?\") | tee -a #{logfile}" if logfile
    rc = Kernel.system(command)
    if logfile
      fid = File.open(logfile)
      fid.seek(-10, IO::SEEK_END) if File.size(logfile) > 10
      rc = (fid.read.split.last == '0')
      fid.close
    end
    rc
  end

  # Exec a command with optional trace
  def self.exec(command, trace=0)
    warn "+ #{command}" if trace != 0
    Plog.debug("+ #{command}")
    Kernel.exec(command)
  end
end

# Kernel extension
module Kernel
  #--------------------------------------------------------- def: hostname
  # Purpose  :
  #-----------------------------------------------------------------------
  def hostname(shortform: nil)
    require 'socket'

    if shortform
      Socket.gethostname.split('.').first
    else
      Socket.gethostname
    end
  end

  #--------------------------------------------------------- def: catcherr
  # Purpose  : Emulate the tcl catch command
  #-----------------------------------------------------------------------
  def catcherr
    yield
    0
  rescue StandardError
    1
  end

  # Check if class is main CLI facing class and extend cli support
  # module to it
  def extend_cli(_file)
    # if (file == $PROGRAM_NAME)
    include Cli
    extend  Cli
    # end
  end
end

require 'logger'
# PLogger handling
class PLogger < Logger
  FORMAT2 = "%<sev>s %<time>s - [%<script>s] %<msg>s\n"
  attr_accessor :simple, :clevel

  def initialize(*args)
    super
    @simple = false
    @slevel = 2
    @clevel = 0
  end

  def format_message(severity, timestamp, progname, msg)
    # Look like this changes from diff versions.  So we need to detect
    script = caller[@slevel + @clevel].sub(/:in .*$/, '').sub(%r{^.*/}, '')
    if @simple
      format("%<sev>s - [%<script>s] %<msg>s\n",
             sev: severity[0..0], script: script, msg: msg)
    elsif timestamp.respond_to?(:strftime)
      format(FORMAT2, sev: severity[0..0], time: timestamp.strftime('%y/%m/%d %T'),
             script: script, msg: msg)
    else
      format(FORMAT2, sev: severity[0..0], time: timestamp,
             script: script, msg: progname)
    end
  end

  def _fmt_obj(obj)
    msg =
      if obj[:_ofmt] == 'Y'
        obj.to_yaml
      else
        obj.inspect
      end
    @clevel = 3
    yield msg
    @clevel = 0
  end

  def dump_info(obj)
    _fmt_obj(obj) { |msg| info(msg) }
  end

  def dump_error(obj)
    _fmt_obj(obj) { |msg| error(msg) }
  end

  def dump(obj)
    _fmt_obj(obj) { |msg| debug(msg) }
  end
end

# --- Class: Plog
#     Singleton class for application based global log
class Plog
  TIMESTAMP_FMT = '%Y-%m-%d %H:%M:%S'
  class << self
    private

    def my_logs
      # Beside singleton imp,  this is also done to defer log creation
      # to absolute needed to allow application to control addition
      # logger setting
      @my_logs ||= set_logger
    end

    public

    def set_logger
      logspec = (ENV['LOG_LEVEL'] || '')
      logger = if logspec =~ /:f/
                 PLogger.new(Regexp.last_match.post_match.sub(/:.*$/, ''))
               else
                 PLogger.new($stderr)
               end
      log_level, *logopts = logspec.split(':')
      logopts.each do |anopt|
        oname = anopt[0]
        # ovalue = anopt[1..]
        case oname
        when 's'
          logger.simple = true
        end
      end
      logger.level = if log_level && !log_level.empty?
                       log_level.to_i
                     else
                       Logger::INFO
                     end
      logger.datetime_format = TIMESTAMP_FMT
      @my_logs = logger
    end

    def _fmt_obj(obj)
      msg =
        if obj[:_ofmt] == 'Y'
          obj.to_yaml
        else
          obj.inspect
        end
      my_logs.clevel = 3
      yield msg
      my_logs.clevel = 0
    end

    def dump_info(obj)
      _fmt_obj(obj) { |msg| my_logs.info(msg) }
    end

    def dump_error(obj)
      _fmt_obj(obj) { |msg| my_logs.error(msg) }
    end

    def dump(obj)
      _fmt_obj(obj) { |msg| my_logs.debug(msg) }
    end

    def method_missing(symbol, *args)
      my_logs.clevel = 1
      result = my_logs.send(symbol, *args)
      my_logs.clevel = 0
      result
    end

    def respond_to_missing?(_method_name, _include_private=false)
      true
    end
  end
end

# Singleton class for application writing to syslog
class Psyslog
  class << self
    private

    def my_log
      unless @glog
        require 'syslog'

        @glog = Syslog
        @glog.open(File.basename($PROGRAM_NAME), Syslog::LOG_PID | Syslog::LOG_CONS,
                   Syslog::LOG_DAEMON)
      end
      @glog
    end

    def method_missing(symbol, *args)
      my_log.send(symbol, *args)
    end

    def respond_to_missing?(_method, _include_private=false)
      true
    end
  end
end

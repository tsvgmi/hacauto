#!/usr/bin/env ruby
#---------------------------------------------------------------------------
# File:        core.rb
# Date:        Tue Nov 13 15:52:52 -0800 2007
# $Id: core.rb 6 2010-11-26 10:59:34Z tvuong $
#---------------------------------------------------------------------------
#++
module ThorAddition
  def self.included(klass)
    klass.class_eval do
      def self.exit_on_failure?
        true
      end
    end
  end

  def cli_wrap
    if ENV['BYEBUG']
      say_status Time.now, "#{File.basename(__FILE__)}:#{__LINE__} " + "Entering debug mode", :yellow
      ENV.delete('BYEBUG')
      require 'byebug'
      byebug
    end
    Signal.trap('SIGINT')  { exit(1) }
    Signal.trap('SIGQUIT') { Elog.info "Quitting from signal."; exit(0) }

    if options[:logfile]
      @logger = PLogger.new(value)
    else
      @logger = PLogger.new(STDERR)
    end

    result = yield

    if result.is_a?(FalseClass)
      return(1)
    end
    if result.is_a?(TrueClass)
      return(0)
    elsif result.is_a?(String)
      puts result
    else
      puts result.inspect
    end
    return 0
  end

  def writable_options
    options.transform_keys(&:to_sym)
  end
end

def progress_set(wset, title=nil)
  title ||= caller[0].split.last.gsub(/['"`]/, '')
  tstring = "%-16.16s [:bar] :percent" % title
  bar     = TTY::ProgressBar.new(tstring, total:wset.size)
  wset.each do |entry|
    unless yield entry, bar
      break
    end
    bar.advance
  end
end

# Functions to support CLI interaction (i.e. options processing,
# help, result interpretation, exit handling)
module Cli
  def setOptions(opt)
    @options ||= {}
    @options.merge!(opt)
  end
  def getOption(name = nil)
    @options ||= {}
    return name ? @options[name] : @options
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
  def handleCli(*optset)
    imethods = self.instance_methods(false)
    if imethods.size > 0
      optset << ['--class', '-c']
    end
    @cliOptions = optset
    opt = Cli.parseOptions(*optset)
    setOptions(opt)
    obj = nil
    if opt[:class] || (imethods.size <= 0)
      (ARGV.length > 0) || self.cliUsage
      method = ARGV.shift.gsub(/-/, '_')
      result = self.send(method, *ARGV)
    elsif block_given?
      result = yield opt
    # Class handle CLI instantiation?
    elsif self.respond_to?(:cliNew)
      # ARGV could change during cliNew, so we check both places
      (ARGV.length > 0) || self.cliUsage
      obj = self.cliNew
      (ARGV.length > 0) || self.cliUsage
      method = ARGV.shift.gsub(/-/, '_')
      result = obj.send(method, *ARGV)
    else
      (ARGV.length > 0) || self.cliUsage
      obj    = self.new(ARGV.shift)
      method = ARGV.shift.gsub(/-/, '_')
      result = obj.send(method, *ARGV)
    end

    # Class handle result?
    if self.respond_to?(:cliResult)
      self.cliResult(result, obj)
    else
      Cli.setShellResult(result)
    end
  end

  def handleCli2(*optset)
    imethods = self.instance_methods(false)
    if imethods.size > 0
      optset << ['--class', '-c']
    end
    @cliOptions = optset
    opt = Cli.parseOptions(*optset)
    setOptions(opt)
    obj = nil
    if opt[:class] || (imethods.size <= 0)
      (ARGV.length > 0) || self.cliUsage
      result = self.send(*ARGV)
    elsif block_given?
      result = yield opt
    # Class handle CLI instantiation?
    elsif self.respond_to?(:cliNew)
      # ARGV could change during cliNew, so we check both places
      (ARGV.length > 0) || self.cliUsage
      obj = self.cliNew(@options)
      (ARGV.length > 0) || self.cliUsage
      result = obj.send(*ARGV)
    else
      (ARGV.length > 0) || self.cliUsage
      obj    = self.new(ARGV.shift, @options)
      result = obj.send(*ARGV)
    end

    # Class handle result?
    if self.respond_to?(:cliResult)
      self.cliResult(result, obj)
    else
      Cli.setShellResult(result)
    end
  end

  # Regenerate the command line option for self invocation use.
  def cliOptBuild
    result = ""
    @options.each do |k, v|
      if v
        if v == true
          result += " --#{k}"
        else
          result += " --#{k} #{v}"
        end
      end
    end
    result
  end

  # Print the message on cli usage (flag/method) and exit script
  def cliUsage
    $stderr.puts "#{File.basename($0)} " +
          Cli.showOptions(@cliOptions).join(" ") + " [object] method ..."
    Cli.classUsage(self)
  end

  # Print a prompt and wait for y/n answer
  def self.confirm(prompt, default="n")
    $stderr.print "#{prompt} (y/n) [n]? "
    ans = $stdin.gets
    if !ans || (ans == "")
      ans = default
    end
    return (ans =~ /[Yy]/) ? true : false
  end

  # Print a prompt and get back a string
  def self.getInput(prompt, default='')
    $stderr.print "#{prompt} [#{default}]: "
    result = $stdin.gets
    return (result != "\n") ? result.chomp : default
  end

  # Get user input from a specification template.  Template is a
  # list of tuple: type, flag, prompt, default value.
  # type:: u|l|D = convert to uppercase, lowercase, mysql date format
  # flag:: R = required
  def self.getInputTemplate(*template)
    maxprlen, maxdeflen = 0, 0
    template.each do |alist|
      _type, _flag, prompt, defval = alist
      maxprlen  = prompt.length if maxprlen < prompt.length
      maxdeflen = defval.length if maxdeflen < defval.length
    end
    result = []
    template.each do |alist|
      type, flag, prompt, defval = alist
      print "%#{maxprlen}s [%#{maxdeflen}s]: " % [prompt, defval]
      answer = $stdin.gets.strip
      answer = defval if (defval && (answer == ''))
      case type
      when 'l'
	answer = answer.downcase
      when 'u'
	answer = answer.upcase
      when 'D'
	answer = answer.mysqlDate
      end
      return [] if ((flag =~ /R/) && (answer == ''))
      result << answer
    end
    result
  end

  # Print a message and just wait till user press enter
  def self.pause(msg = "... Press return to continue ...")
    $stderr.print msg
    $stdin.gets
  end

  # Similar to ksh select functionality.  Select a member from an
  # input list
  def self.select(alist, aprompt=nil)
    maxwidth = 10
    alist.each do |entry|
      if entry.size > maxwidth
        maxwidth = entry.size
      end
    end
    swidth = ENV['COLUMNS'] || 80
    swidth = swidth.to_i - 2
    cols   = swidth/(maxwidth + 5)
    cols   = 1 if (cols <= 0)
    pwidth = (swidth/cols) - 5
    pcol   = (alist.size + cols - 1) / cols
    loop do
      0.upto(pcol-1) do |ridx|
        0.upto(cols-1) do |cidx|
          idx   = ridx + cidx*pcol
          entry = alist[idx]
          if entry
            $stderr.print("%2d. %-#{pwidth}s " % [idx+1, entry])
          end
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
      next if (ans == '')
      if (ans =~ /^[0-9]+$/)
	return alist[ans.to_i - 1]
      end
      break
    end
    nil
  end

  # Print the usage message for the class (instance and class methods)
  # to be used in display help
  def self.classUsage(klass)
    defs = {}
    mlist = klass.instance_methods(false).grep(/^[^_]/).map do |amethod|
      ["", amethod, klass.instance_method(amethod).arity]
    end +
    (klass.singleton_methods - Cli.instance_methods).map do |amethod|
      ["#{klass}.", amethod, klass.method(amethod).arity]
    end
    mlist.sort.each do |c, f, m|
      if defs[f]
        $stderr.puts "  - #{c}#{f}(#{defs[f]})"
      else
        vlist =
          if (m < 0)
            Array.new(-m, "v").join(", ") + ", ..."
          else
            Array.new(m, "v").join(", ")
          end
        $stderr.puts "  - #{c}#{f}(#{vlist})"
      end
    end
    $stderr.print "<Return> to quit or 'h' for help ..."
    result = $stdin.gets.chomp
    exit unless result =~ /^[hH]/
    exec "tman -r #{$0}"
  end

  # Wait for an interval seconds and print progress dot ...
  def self.wait(interval, comment = nil)
    $stderr.print "#{comment}" if comment
    $stderr.print "[#{interval}]: "
    interval.downto(1) {
      $stderr.print "."
      $stderr.flush
      sleep(1)
    }
    $stderr.puts ""
  end

  def self.shellResult
    if ENV['LOG_LEVEL'] && (ENV['LOG_LEVEL'] > "0")
      begin
	result = yield
	self.setShellResult(result)
      rescue => error
	$stderr.puts "+ #{$0}: #{error}"
	exit 1
      end
    else
      result = yield
      self.setShellResult(result)
    end
  end

  # Map output to shell (at exit) for ruby class output
  def self.setShellResult(result)
    if result.kind_of?(TrueClass)
      exit(0)
    elsif result.kind_of?(FalseClass)
      exit(1)
    elsif result.kind_of?(String)
      puts result
    else
      puts result.inspect
    end
    exit(0)
  end

  def self.showOptions(options)
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
  def self.parseOptions(*options)
    require 'getoptlong'

    option = Hash.new
    newopt = options.collect do |optspec|
      opt, tmp, type, default = optspec
      if (type == nil)
	type = GetoptLong::NO_ARGUMENT
	optspec[2] = type
      end
      optname = opt[2..-1]
      option[optname.intern] = default
      [opt, tmp, type]
    end
    begin
      GetoptLong.new(*newopt).each do |opt, arg|
        optname = opt[2..-1]
        option[optname.intern] = (arg == '') ? true : arg
      end
    rescue => errmsg
      puts errmsg
      puts "#{File.basename($0)} " + showOptions(options).join(" ") + "..."
    end
    option
  end
end

module Pf
  def self.hostaddr(name)
    require 'socket'

    Socket.getaddrinfo(name, 0, nil, Socket::SOCK_STREAM)[0][3]
  end

  def self.hostname(addr, shortform = true)
    require 'socket'

    result = Socket.getaddrinfo(addr, 0, nil, Socket::SOCK_STREAM)[0][2]
    if shortform && (result !~ /^[0-9.]+$/)
      result.sub!(/\..*$/, '')
    end
    result
  end

  # Run a system command with optional trace
  def self.system(command, trace = nil, logfile = nil)
    $stderr.puts "+ #{command}" if trace
    Plog.debug("+ #{command}")
    if logfile
      command = "(time #{command} 2>&1; echo \":exit: $?\") | tee -a #{logfile}"
    end
    rc = Kernel.system(command)
    if logfile
      fid = File.open(logfile)
      if File.size(logfile) > 10
        fid.seek(-10, IO::SEEK_END)
      end
      rc = (fid.read.split.last == "0")
      fid.close
    end
    rc
  end

 # Exec a command with optional trace
  def self.exec(command, trace = 0)
    $stderr.puts "+ #{command}" if trace != 0
    Plog.debug("+ #{command}")
    Kernel.exec(command)
  end

  # Run command as root (via sudo)
  def self.suRun(command, trace = 0)
    if Process.uid == 0
      Pf.system(command, trace)
    else
      Pf.system("sudo #{command}", trace)
    end
  end
end

# Extension to normal File class
class File
  # Equivalent perl method to check if file is text only
  def File.isText?(file, bsize=256)
    return true if File.extname(file) =~ /\.(java|c|h|m)/
    return false if File.size(file) == 0
    text = true
    File.open(file) do |fid|
      fid.read(bsize).each_byte do |abyte|
	if (abyte < 9) || (abyte > 0x7e)
	  text = false
	  break
	end
      end
    end
    text
  end
end

module Kernel
  #--------------------------------------------------------- def: hostname
  # Purpose  :
  #-----------------------------------------------------------------------
  def hostname(shortform = nil)
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
    begin
      yield
      0
    rescue
      1
    end
  end

  # Check if class is main CLI facing class and extend cli support
  # module to it
  def extendCli(_file)
    #if (file == $0)
      include Cli
      extend  Cli
    #end
  end
end

require 'logger'
class PLogger < Logger
  Format2    = "%s %s - [%s] %s\n"
  attr_accessor :simple, :clevel

  def initialize(*args)
    super
    @simple = false
    @slevel = 2
    @clevel = 0
  end

  def format_message(severity, timestamp, progname, msg)
    # Look like this changes from diff versions.  So we need to detect
    script = caller[@slevel+@clevel].sub(/:in .*$/, '').sub(/^.*\//, '')
    if @simple
      "%s - [%s] %s\n" % [severity[0..0], script, msg]
    else
      if timestamp.respond_to?(:strftime)
        Format2 % [severity[0..0], timestamp.strftime("%y/%m/%d %T"), script, msg]
      else
        Format2 % [severity[0..0], timestamp, script, progname]
      end
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
    _fmt_obj(obj) {|msg| self.info(msg) }
  end

  def dump_error(obj)
    _fmt_obj(obj) {|msg| self.error(msg) }
  end

  def dump(obj)
    _fmt_obj(obj) {|msg| self.debug(msg) }
  end
end

class Plog
=begin
--- Class: Plog
    Singleton class for application based global log
=end
  @@xglog        = nil
  @@timestampFmt = "%Y-%m-%d %H:%M:%S"
  @@dotrace      = false
  class << self

    private
    def myLogs
      # Beside singleton imp,  this is also done to defer log creation
      # to absolute needed to allow application to control addition
      # logger setting
      @@xglog ||= setLogger
    end

    public
    def setLogger
      logspec = (ENV['LOG_LEVEL'] || '')
      if logspec =~  /:f/
        logger = PLogger.new($'.sub(/:.*$/, ''))
      else
        logger = PLogger.new(STDERR)
      end
      log_level, *logopts = logspec.split(':')
      logopts.each do |anopt|
        oname  = anopt[0]
        ovalue = anopt[1..-1]
        case oname
        when 's'
          logger.simple = true
        end
      end
      if log_level && !log_level.empty?
        logger.level = log_level.to_i
      else
        logger.level = Logger::INFO
      end
      logger.datetime_format = @@timestampFmt
      @@xglog = logger
    end

    def _fmt_obj(obj)
      msg =
        if obj[:_ofmt] == 'Y'
          obj.to_yaml
        else
          obj.inspect
        end
      myLogs.clevel = 3
      yield msg
      myLogs.clevel = 0
    end

    def dump_info(obj)
      _fmt_obj(obj) {|msg| myLogs.info(msg) }
    end

    def dump_error(obj)
      _fmt_obj(obj) {|msg| myLogs.error(msg) }
    end

    def dump(obj)
      _fmt_obj(obj) {|msg| myLogs.debug(msg) }
    end

    def method_missing(symbol, *args)
      myLogs.clevel = 1
      result = myLogs.send(symbol, *args)
      myLogs.clevel = 0
      result
    end
  end
end

# Singleton class for application writing to syslog
class Psyslog
  @@glog = nil
  class << self
    private
    def myLog
      unless @@glog
	require 'syslog'

	@@glog = Syslog
	@@glog.open(File.basename($0), Syslog::LOG_PID|Syslog::LOG_CONS,
		     Syslog::LOG_DAEMON)
      end
      @@glog
    end

    def method_missing(symbol, *args)
      myLog.send(symbol, *args)
    end
  end
end

module Process
  def self.alive? pid
    pid = Integer("#{ pid }")
    begin
      Process.kill 0, pid
      true
    rescue Errno::EPERM
      true
    rescue Errno::ESRCH
      false
    end
  end
end

class Erb
  @@argv = nil
  # Get an argument for Erb processing.  This is used in erb templates
  # to allow command line to use ERBARG env variable to pass argument
  # to thte templates
  def self.argv
    unless @@argv
      @@argv = ENV['ERBARG'].split
    end
    @@argv
  end
end

module YamlConfig
  def configLoad(cfile, index = nil)
    @_ycfile = cfile
    if File.readable?(cfile)
      result = YAML.load(File.read(cfile))
      return index ? result[index] : result
    else
      nil
    end
  end

  def configSave(obj, index = nil)
    if index
      if File.readable?(@_ycfile)
        config = YAML.load(File.read(@_ycfile))
      else
        config = {}
      end
      config[index] = obj
      yobj = config
    else
      yobj = obj
    end
    File.open(@_ycfile, "w") do |fod|
      fod.puts(YAML.dump(yobj))
    end
  end
end

# Provides persistent configuration by association of yml data with
# a file
class YmlConfig
  attr_accessor :config
  attr_reader   :cfile

  def initialize(cfile, default = {})
    require 'yaml'

    @cfile  = cfile
    if File.readable?(cfile)
      @config = YAML.load(File.read(cfile))
    else
      @config = default
    end
  end

  def save(ofile = nil)
    require 'yaml'

    ofile ||= @cfile
    File.open(ofile, "w") do |fod|
      fod.puts(YAML.dump(@config))
    end
  end

  # Get an arbitrary value in the yml tree (hash and list index only)
  def getf(field)
    value = @config
    field.split(/\//).each do |af|
      return nil unless value
      if af =~ /^:/
        value = value[af[1..-1].intern]
      elsif af =~ /^\d+$/
        value = value[af.to_i]
      else
        value = value[af]
      end
    end
    value
  end

  # Set an arbitrary value in the yml tree (hash and list index only)
  # Creates storage on demand
  def setf(field, newval)
    pfields = field.split(/\//)
    store   = pfields.last

    # Traverse to the leaf
    value = @config
    fidx  = 0
    pfields.each do |af|
      if fidx < (pfields.size - 1)
        if af =~ /^:/
          index = af[1..-1].intern
        elsif af =~ /^\d+$/
          index = af.to_i
        else
          index = af
        end
        # Create storage if needed
        case pfields[fidx+1]
        when /^:/
          value[index] ||= {}
        when /^\d+$/
          value[index] ||= []
        else
          value[index] ||= {}
        end
        value = value[index]
      end
      fidx += 1
    end

    # Assign new value to the leaf
    if store =~ /^:/
      value[store[1..-1].intern] = newval
    elsif store =~ /^\d+$/
      value[store.to_i] = newval
    else
      value[store] = newval
    end
  end

  def method_missing(symbol, *args)
    @config.send(symbol, *args)
  end
end

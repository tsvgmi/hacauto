#---------------------------------------------------------------------------
# File:        toolenv.rb
# Date:        Thu Nov 22 18:45:57 -0500 2007
# Copyright:   Mocana, 2007
# Description: Bootstrap for MSS ruby scripts
# $Id: toolenv.rb 56 2010-06-29 17:47:56Z tvuong $
#---------------------------------------------------------------------------
#+++
if !ENV["TOOL_DEFINED"]
  ENV["TOOL_DEFINED"] = "1"
  ENV["T_TOOL_DIR"]  = T_TOOL_BASE = File.dirname(__FILE__) + "/.."
  ENV["T_TOOL_BIN"]  = ENV["T_TOOL_DIR"] + "/bin"
  $: << T_TOOL_BASE+'/bin'
  $: << T_TOOL_BASE+'/lib'
  ENV["T_ETC_DIR"]   = File.dirname(__FILE__)
  ENV["T_DATA_DIR"]  = ENV["T_TOOL_DIR"] + "/var"
  ENV["T_DATA_DIR0"] = ENV["T_DATA_DIR"]
  ENV["PATH"] += ":#{ENV['T_TOOL_BIN']}"
end

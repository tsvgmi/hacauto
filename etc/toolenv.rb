# frozen_string_literal: true

#---------------------------------------------------------------------------
# File:        toolenv.rb
#---------------------------------------------------------------------------
#+++
unless ENV['TOOL_DEFINED']
  ENV['TOOL_DEFINED'] = '1'
  ENV['T_TOOL_DIR']  = T_TOOL_BASE = "#{File.dirname(__FILE__)}/..".freeze
  ENV['T_TOOL_BIN']  = "#{ENV['T_TOOL_DIR']}/bin"
  $LOAD_PATH << "#{T_TOOL_BASE}/bin"
  $LOAD_PATH << "#{T_TOOL_BASE}/lib"
  ENV['T_ETC_DIR']   = File.dirname(__FILE__)
  ENV['T_DATA_DIR']  = "#{ENV['T_TOOL_DIR']}/var"
  ENV['T_DATA_DIR0'] = ENV['T_DATA_DIR']
  ENV['PATH'] += ":#{ENV['T_TOOL_BIN']}"
end

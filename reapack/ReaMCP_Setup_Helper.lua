-- @description ReaMCP Setup Helper
-- @version 0.1.0
-- @author Daniel Kinahan
-- @about
--   Displays a quick setup checklist for ReaMCP.

local msg = [[
ReaMCP setup checklist:

1) Install Python package:
   pip install -e .

2) In REAPER, install dependency via ReaPack:
   mavriq-lua-sockets

3) In REAPER, load and run bridge script:
   bridge/reaper_mcp_bridge.lua

4) Start your MCP server:
   python -m reaper_mcp

Then connect your MCP client to that stdio server.
]]

reaper.ShowMessageBox(msg, "ReaMCP Setup", 0)

--[[----------------------------------------------------------------------
  dom-main/controller/gpshost.lua -- lets this controller double as one
  of the (at least 4, non-coplanar) GPS anchor points CC:Tweaked's own
  gps.locate() needs, alongside its other duties.

  CC:Tweaked ships GPS hosting as the "gps" shell program (`gps host <x>
  <y> <z>`), not as a reusable Lua API -- M.run() below just drives that
  same program via shell.run(), the same way an operator would type it
  in by hand, as one more parallel.waitForAny branch (see
  dom-main/controller/controller_main.lua) alongside everything else
  this controller already does. gps host blocks forever answering
  gps.locate() requests over rednet, same shape as every other loop here.

  Position is persisted to /state/gpshost.state (same fs +
  textutils.serializeJSON pattern dom-main/controller/mode.lua uses),
  set once via server/turtlectl.py's `gpshost` shortcut. M.run() simply
  idles (does nothing) until a position has actually been configured --
  a controller with no configured position must never accidentally
  start answering GPS requests with (0, 0, 0) or some other default.
------------------------------------------------------------------------]]

if _G.__GPSHOST_MODULE then return _G.__GPSHOST_MODULE end

local STATE_PATH = "/state/gpshost.state"
local RETRY_BACKOFF = 5 -- seconds -- in case shell.run("gps","host",...) ever returns/errors

local M = {}

local position -- { x, y, z } once loaded/set, nil until then -- see loadState()
local loaded = false

local function save()
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(position))
  f.close()
end

local function loadState()
  if loaded then return end
  loaded = true
  if not fs.exists(STATE_PATH) then return end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" and decoded.x and decoded.y and decoded.z then
    position = decoded
  end
end

-- This controller's own configured GPS anchor position, or nil if none
-- has been set yet.
function M.get()
  loadState()
  return position
end

function M.set(x, y, z)
  position = { x = x, y = y, z = z }
  loaded = true
  save()
  return position
end

-- Blocks forever, answering gps.locate() requests at M.get()'s
-- position -- a no-op loop (nothing to host) until one's actually been
-- configured. Meant to run as its own parallel.waitForAny branch.
function M.run()
  while true do
    local pos = M.get()
    if not pos then
      sleep(RETRY_BACKOFF)
    else
      -- shell.run() blocks for as long as the program does -- gps host
      -- runs forever answering requests, same as this loop's other
      -- siblings; the RETRY_BACKOFF sleep below only ever matters if it
      -- somehow returns or errors (a modem hiccup, say), so this
      -- doesn't tight-loop retrying instantly.
      shell.run("gps", "host", tostring(pos.x), tostring(pos.y), tostring(pos.z))
      sleep(RETRY_BACKOFF)
    end
  end
end

_G.__GPSHOST_MODULE = M
return M

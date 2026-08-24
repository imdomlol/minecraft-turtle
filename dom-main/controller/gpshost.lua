--[[----------------------------------------------------------------------
  dom-main/controller/gpshost.lua -- lets this controller double as one
  of the (at least 4, non-coplanar) GPS anchor points CC:Tweaked's own
  gps.locate() needs, alongside its other duties.

  CC:Tweaked ships GPS hosting as the "gps" program (`gps host <x> <y>
  <z>`), not as a reusable Lua API -- M.run() below runs that same
  program's file directly via os.run(), the lower-level primitive
  shell.run() itself is built on, as one more parallel.waitForAny branch
  (see dom-main/controller/controller_main.lua) alongside everything
  else this controller already does. gps host blocks forever answering
  gps.locate() requests over rednet, same shape as every other loop here.

  os.run(), not shell.run(): confirmed live -- the `shell` global is
  ONLY ever injected into a program actually launched through an
  interactive shell session; a controller boots via startup.lua, which
  never gets one, so shell.run() here threw "attempt to index global
  'shell' (a nil value)" and, uncaught, took the ENTIRE controller
  down with it (parallel.waitForAny propagates any one branch's error
  to all the others). Every call into gps here is now pcall-wrapped for
  exactly that reason -- this file must never again be able to crash
  the whole controller, regardless of what else might be wrong with it
  (a bad ROM path included).

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

-- The real ROM location of CC:Tweaked's built-in "gps" program -- what
-- typing `gps` at a shell prompt actually resolves to and runs.
local GPS_PROGRAM_PATH = "rom/programs/gps.lua"

-- Blocks forever, answering gps.locate() requests at M.get()'s
-- position -- a no-op loop (nothing to host) until one's actually been
-- configured. Meant to run as its own parallel.waitForAny branch.
function M.run()
  local lastErr = nil
  while true do
    local pos = M.get()
    if not pos then
      sleep(RETRY_BACKOFF)
    else
      -- os.run() blocks for as long as the program does -- gps host
      -- runs forever answering requests, same as this loop's other
      -- siblings; the RETRY_BACKOFF sleep below only ever matters if it
      -- somehow returns or errors (a modem hiccup, a bad ROM path, a
      -- future CC:Tweaked version moving the program -- anything at
      -- all), so this doesn't tight-loop retrying instantly. pcall is
      -- the actual safety net -- see this file's own header comment for
      -- why an uncaught error here must never happen again.
      local ok, err = pcall(os.run, {}, GPS_PROGRAM_PATH,
        "host", tostring(pos.x), tostring(pos.y), tostring(pos.z))
      if not ok and tostring(err) ~= lastErr then
        print("gpshost: could not host GPS -- " .. tostring(err))
        lastErr = tostring(err)
      end
      sleep(RETRY_BACKOFF)
    end
  end
end

_G.__GPSHOST_MODULE = M
return M

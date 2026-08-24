--[[----------------------------------------------------------------------
  gps-anchor.lua -- standalone GPS anchor host.

  NOT part of the turtle fleet's manifest.txt/startup.lua OTA system --
  this is meant for a plain Computer dedicated purely to hosting GPS,
  nothing else, and it never gets fetched/updated by that bootstrap.

  Needs at least 4 of these (or a mix of these and a fleet controller
  configured via server/turtlectl.py's `gpshost` shortcut -- see
  dom-main/controller/gpshost.lua) positioned so they are NOT all in one
  plane -- see CC:Tweaked's own GPS setup documentation. Every turtle
  running lib/nav.lua then picks up a real position automatically the
  moment such a network exists and is in range -- see that file's own
  M.reacquireGPS() for upgrading a turtle that already has a manually-set
  position on file (the normal case for this fleet today).

  Install (once per dedicated computer):
    wget https://raw.githubusercontent.com/<repo>/main/gps-anchor.lua startup.lua
  then reboot -- the first boot prompts once for this computer's own
  real-world (x, y, z) coordinates (get them from a wall sign, F3, or
  wherever you planned the build) and remembers them from then on.
------------------------------------------------------------------------]]

local STATE_PATH = "/state/gps_anchor.state"
local RETRY_BACKOFF = 5 -- seconds -- in case gps host ever errors or returns

local function loadPosition()
  if not fs.exists(STATE_PATH) then return nil end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" and decoded.x and decoded.y and decoded.z then
    return decoded
  end
  return nil
end

local function savePosition(pos)
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(pos))
  f.close()
end

local function askNumber(label)
  while true do
    io.write(label .. ": ")
    local n = tonumber(read())
    if n then return math.floor(n) end
    print("not a number, try again")
  end
end

local function promptForPosition()
  print("gps-anchor: first boot -- enter this computer's own real-world coordinates.")
  local pos = { x = askNumber("x"), y = askNumber("y"), z = askNumber("z") }
  savePosition(pos)
  return pos
end

local pos = loadPosition() or promptForPosition()
print(("gps-anchor: hosting GPS at (%d, %d, %d)"):format(pos.x, pos.y, pos.z))

local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
if not modem then
  print("gps-anchor: no wireless/ender modem attached -- cannot host GPS.")
  return
end
local side = peripheral.getName(modem)
if not rednet.isOpen(side) then rednet.open(side) end

while true do
  local ok, err = pcall(shell.run, "gps", "host", tostring(pos.x), tostring(pos.y), tostring(pos.z))
  if not ok then print("gps-anchor: gps host errored -- " .. tostring(err)) end
  sleep(RETRY_BACKOFF)
end

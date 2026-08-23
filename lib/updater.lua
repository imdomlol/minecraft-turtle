--[[----------------------------------------------------------------------
  lib/updater.lua -- decides when this turtle should reboot to pick up
  new code, based on version numbers the controller reports (piggybacked
  on every heartbeat reply -- see dom-main/controller/roster.lua's
  upsert() and lib/fleet.lua's listenLoop).

  M.noteControllerVersion(v): the *first* version ever heard is adopted
  silently, no reboot -- a turtle that just booted is already running
  whatever code the controller currently expects, by definition. After
  that, a strictly newer v means the operator has pushed new code and
  manually bumped dom-main/controller/version.lua to signal it's ready
  to roll out (see that file's own header comment for why that's a
  deliberate manual step). Records it as pendingVersion and calls
  job.stop() exactly once -- the same graceful stop an operator's `stop`
  command already triggers. This is deliberately NOT "wait for the whole
  job to finish" -- dom-main/mining/vertical.lua's mine_vertical is often
  run uncapped, and could then never update; job.stop() reaches a safe
  pause (finishes the current leg/height-step, climbs back to column
  start) in roughly the same bounded time an operator's own stop already
  takes.

  M.checkAndReboot(): once pendingVersion is set and the job has actually
  wound down to idle, persists the new version (so the turtle doesn't
  immediately think itself stale again after rebooting) and reboots.
  Deliberately does not care whether the job wound down *cleanly* --
  lib/job.lua's checkpoint/dom-main/turtle_main.lua's boot-time resume
  handles picking back up if it was still mid-leg when job.stop() was
  requested, the same as they would for any other unplanned interruption.

  This turtle's own last-known-good version is persisted separately, to
  /state/version.state (survives startup.lua's wipe).
------------------------------------------------------------------------]]

if _G.__UPDATER_MODULE then return _G.__UPDATER_MODULE end

local VERSION_PATH = "/state/version.state"

local job = dofile("/lib/job.lua")

local M = {}

local pendingVersion = nil

local function loadVersion()
  if not fs.exists(VERSION_PATH) then return nil end
  local f = fs.open(VERSION_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" and type(decoded.version) == "number" then
    return decoded.version
  end
  return nil
end

local function saveVersion(v)
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(VERSION_PATH, "w")
  f.write(textutils.serializeJSON({ version = v }))
  f.close()
end

-- Exposed for tests/introspection.
function M.currentVersion()
  return loadVersion()
end

function M.noteControllerVersion(v)
  local mine = loadVersion()
  if mine == nil then
    saveVersion(v)
    return
  end
  if v > mine and pendingVersion == nil then
    pendingVersion = v
    print("updater: newer version " .. v .. " available (currently " .. mine
      .. ") -- will reboot once the current job reaches a safe pause")
    job.stop()
  end
end

function M.checkAndReboot()
  if pendingVersion and job.status().current == "idle" then
    saveVersion(pendingVersion)
    print("updater: rebooting to finish updating to version " .. pendingVersion)
    os.reboot()
  end
end

_G.__UPDATER_MODULE = M
return M

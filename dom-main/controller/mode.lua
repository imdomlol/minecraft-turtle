--[[----------------------------------------------------------------------
  dom-main/controller/mode.lua -- the controller's idle/passive/aggressive
  autopilot switch, adjustable by a remotely connected operator at any
  time regardless of what it's currently set to.

  idle:       the autopilot (dom-main/controller/scheduler.lua, not built
              yet) never issues commands, but the rest of the controller
              (roster tracking, block-sync pulls, operator-proxied
              commands) keeps working exactly as it does today.
  aggressive: the autopilot always issues commands, whether or not an
              operator is remotely connected right now.
  passive:    the autopilot issues commands only when nobody's connected
              -- the moment an operator connects, it defers to them
              (acts like idle) until they disconnect.

  The mode itself is persisted to /state/controller.state (same fs +
  textutils.serializeJSON pattern lib/nav.lua already uses for
  /state/nav.state), surviving reboot -- defaults to "idle" (the safest
  choice) the very first time a controller ever boots, before an
  operator has set anything.

  Whether an operator is *currently* connected is a different kind of
  fact -- true right now, about this boot session -- and is deliberately
  NOT persisted: a reboot always starts with nobody connected, correctly,
  without needing to remember anything. server/turtlectl.py's `console`
  command calls M.connect() once at session start and again periodically
  as a heartbeat (the same call serves both purposes -- idempotent), and
  M.disconnect() on a clean exit. isConnected() below also has a
  timeout, not just the connect()/disconnect() flag on its own, so a
  console session that crashes or loses network without reaching its
  disconnect() eventually stops blocking passive mode's autopilot
  instead of wedging it into "idle" forever.
------------------------------------------------------------------------]]

if _G.__MODE_MODULE then return _G.__MODE_MODULE end

local STATE_PATH = "/state/controller.state"
local CONNECTED_TIMEOUT = 20 * 1000 -- ms; how long a connect() stays valid with no follow-up

local VALID_MODES = { idle = true, passive = true, aggressive = true }

local M = {}

local mode -- lazily loaded, see loadState() below
local connected = false
local lastConnect = nil -- os.epoch("utc") of the most recent connect() call

local function save()
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON({ mode = mode }))
  f.close()
end

local function loadState()
  if mode then return end
  mode = "idle"
  if not fs.exists(STATE_PATH) then return end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" and VALID_MODES[decoded.mode] then
    mode = decoded.mode
  end
end

function M.get()
  loadState()
  return mode
end

function M.set(newMode)
  if not VALID_MODES[newMode] then
    error("invalid mode: " .. tostring(newMode) .. " (expected idle, passive, or aggressive)", 2)
  end
  loadState()
  mode = newMode
  save()
  return mode
end

function M.connect()
  connected = true
  lastConnect = os.epoch("utc")
end

function M.disconnect()
  connected = false
end

local function isConnected()
  if not connected or not lastConnect then return false end
  return (os.epoch("utc") - lastConnect) < CONNECTED_TIMEOUT
end

-- Whether the autopilot should be issuing commands right now -- see the
-- three modes described above. dom-main/controller/scheduler.lua (not
-- built yet) is meant to check this once per tick and simply do nothing
-- that tick if it's false.
function M.shouldAutopilot()
  loadState()
  if mode == "aggressive" then return true end
  if mode == "idle" then return false end
  return not isConnected()
end

_G.__MODE_MODULE = M
return M

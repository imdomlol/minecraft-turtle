--[[----------------------------------------------------------------------
  dom-main/controller/roster.lua -- tracks every turtle that has heard
  from this controller over rednet, and proxies a command to one of them
  on an operator's behalf.

  M.handleMessage(senderId, message) is the single entry point for every
  rednet message this controller receives on lib/fleet.lua's protocol --
  used both by dom-main/controller/fleet_listener.lua's main receive loop
  and reentrantly inside M.proxy()'s own wait-for-reply loop below, so a
  heartbeat/log arriving from some *other* turtle while we're waiting on
  a reply from *this* one still gets recorded instead of silently
  dropped. This works because CraftOS resumes every coroutine currently
  parked in rednet.receive() with the same event -- it doesn't hand the
  message to just one of them -- so two independent receive loops can
  coexist safely; see the CC:Tweaked parallel/os.pullEvent model.

  Registration has no relay to check for a name already in use the way
  lib/identity.lua's HTTP path does (see lib/fleet.lua's header comment),
  so this is also the single authority that can actually detect a real
  collision (two different computer ids reporting the same name) and
  tell the loser to pick a new one.

  Cached on _G like the other lib/*.lua singletons, so every dofile() of
  this file (the scheduler, turtlectl.py's proxied commands via
  controller_main.lua) shares the exact same roster.
------------------------------------------------------------------------]]

if _G.__ROSTER_MODULE then return _G.__ROSTER_MODULE end

local exec = dofile("/lib/exec.lua")
local PROTOCOL = dofile("/lib/fleet.lua").PROTOCOL

local DEFAULT_TIMEOUT = 60 -- seconds to wait for a proxied command's result

local M = {}

local roster = {}        -- name -> { computerId, label, fuel, position, job, lastSeen }
local cmdCounter = 0
local collisionCounter = 0

local function upsert(senderId, message)
  local name = message.id
  local existing = roster[name]
  if existing and existing.computerId ~= senderId then
    -- A different physical turtle is already registered under this name
    -- -- both picked it blind (no relay to check against). Tell this one
    -- to fall back to a fresh name instead of silently merging two
    -- turtles' status/results into one roster entry.
    collisionCounter = collisionCounter + 1
    local newName = name .. "-" .. collisionCounter
    rednet.send(senderId, { type = "rename", name = newName }, PROTOCOL)
    return
  end
  roster[name] = {
    computerId = senderId,
    label = message.label,
    fuel = message.fuel,
    position = message.position,
    job = message.job,
    lastSeen = os.epoch("utc"),
  }
end

-- Handles one incoming rednet message already known to be on our
-- protocol. "result" messages are deliberately not handled here -- they
-- only ever matter to a specific M.proxy() call waiting on a matching
-- cmd_id, which checks for them itself in its own wait loop below.
function M.handleMessage(senderId, message)
  if type(message) ~= "table" then return end
  if message.type == "heartbeat" then
    upsert(senderId, message)
  elseif message.type == "log" and message.id and message.text then
    exec.append("[" .. tostring(message.id) .. "] " .. tostring(message.text))
  end
end

-- Everything currently known about the fleet, for turtlectl.py's
-- `roster <controller>` command. secondsAgo lets an operator tell a
-- turtle that's gone quiet (out of range, crashed, out of fuel) apart
-- from one that's simply idle.
function M.report()
  local now = os.epoch("utc")
  local out = {}
  for name, entry in pairs(roster) do
    out[name] = {
      label = entry.label,
      fuel = entry.fuel,
      position = entry.position,
      job = entry.job,
      secondsAgo = math.floor((now - entry.lastSeen) / 1000),
    }
  end
  return out
end

-- Direct read access for dom-main/controller/scheduler.lua, which needs
-- to scan for idle turtles without going through the network -- roster
-- state is already local to this same computer.
function M.all()
  return roster
end

function M.get(name)
  return roster[name]
end

-- Sends `command` to turtle `name` as an exec request and blocks (up to
-- timeoutSeconds) for its result, exactly like lib/exec.lua's M.run()
-- would if it ran locally -- this is what lets
-- server/turtlectl.py's shortcuts work unchanged whether they're
-- targeting a turtle behind a controller or (in the old HTTP-direct
-- design) the turtle itself: build_shortcut() only ever builds the inner
-- Lua string, and this is the "where does it actually run" plumbing.
function M.proxy(name, command, timeoutSeconds)
  local entry = roster[name]
  if not entry then return false, "unknown turtle: " .. tostring(name) end

  cmdCounter = cmdCounter + 1
  local cmdId = tostring(cmdCounter)
  rednet.send(entry.computerId, { type = "exec", cmd_id = cmdId, command = command }, PROTOCOL)

  local deadline = os.clock() + (timeoutSeconds or DEFAULT_TIMEOUT)
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then
      return false, "timeout waiting for " .. name
    end
    local senderId, message = rednet.receive(PROTOCOL, remaining)
    if senderId == nil then
      return false, "timeout waiting for " .. name
    end
    if type(message) == "table" then
      if senderId == entry.computerId and message.type == "result" and message.cmd_id == cmdId then
        return message.ok, message.output
      end
      -- Not our reply -- still worth recording (another turtle's
      -- heartbeat/log arriving while we wait) rather than dropping it.
      M.handleMessage(senderId, message)
    end
  end
end

-- Runs `command` on every turtle currently in the roster, sequentially
-- (one proxy() at a time, so a slow/unreachable turtle only costs its
-- own timeout, not the others' turn) -- for server/turtlectl.py's
-- `send-fleet`. Returns { [name] = { ok, output } } for every turtle
-- attempted.
--
-- Snapshots the names to a plain array before looping: M.proxy() can add
-- a brand-new roster entry mid-wait (a turtle heartbeating for the first
-- time while we're blocked on a different one's reply, via
-- handleMessage()'s upsert()) -- mutating `roster` while pairs() is
-- iterating it directly would be undefined behavior.
function M.proxyAll(command, timeoutSeconds)
  local names = {}
  for name in pairs(roster) do names[#names + 1] = name end

  local out = {}
  for _, name in ipairs(names) do
    local ok, output = M.proxy(name, command, timeoutSeconds)
    out[name] = { ok = ok, output = output }
  end
  return out
end

_G.__ROSTER_MODULE = M
return M

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

local STATE_PATH = "/state/roster.state"

local roster = {}        -- name -> { computerId, label, fuel, position, job, lastSeen }
local cmdCounter = 0
local collisionCounter = 0

local function save()
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(roster))
  f.close()
end

-- Every turtle this controller has EVER heard from, not just this boot
-- session's -- the in-memory roster used to start completely empty on
-- every controller reboot, so a turtle that simply hadn't re-heartbeated
-- yet was indistinguishable from one that never existed at all.
-- lastSeen is loaded as-written (not reset to "now"), so
-- M.report()'s secondsAgo correctly shows how long it's ACTUALLY been
-- since a real heartbeat, through a controller reboot -- exactly the
-- signal needed to tell "just slow to reconnect" apart from "genuinely
-- gone silent". Runs once, at module load.
local function loadPersisted()
  if not fs.exists(STATE_PATH) then return end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" then
    for name, entry in pairs(decoded) do
      roster[name] = entry
    end
  end
end
loadPersisted()

-- name -> lib/fleet.lua log-push `seq` most recently appended -- see
-- M.handleMessage()'s "log" case for why this is needed at all.
-- Deliberately an exact-equality check there, not "seq must keep
-- increasing": every duplicate delivery of one push carries the exact
-- same seq (multiple listeners redundantly observing the one send), so
-- comparing for equality catches it -- and, unlike a monotonic
-- comparison, needs no special-casing for a turtle whose own seq
-- counter restarts from 1 after a reboot: that first post-reboot push
-- is simply a different value from whatever was last recorded, so it's
-- accepted immediately rather than being mistaken for a stale repeat.
local lastLogSeq = {}

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
  local now = os.epoch("utc")
  roster[name] = {
    computerId = senderId,
    label = message.label,
    fuel = message.fuel,
    fuelItems = message.fuelItems,
    position = message.position,
    job = message.job,
    lastSeen = now,
    -- Preserved across every heartbeat rather than reset -- this whole
    -- table gets replaced wholesale on every upsert, so without this a
    -- turtle's pull staleness would forget itself every ~3s. A turtle
    -- seen for the first time defaults to "now", making it immediately
    -- eligible for dom-main/controller/block_sync.lua's next pull rather
    -- than needing to wait out some arbitrary initial delay.
    lastBlockPull = existing and existing.lastBlockPull or now,
  }
  save()

  -- Piggybacked on every heartbeat rather than a separate round trip --
  -- see lib/updater.lua (turtle-side) for what it does with this.
  rednet.send(senderId, { type = "version", value = dofile("/dom-main/controller/version.lua").get() }, PROTOCOL)
end

-- Sent once at controller startup (see dom-main/controller/
-- fleet_listener.lua, right after rednet.host()) to every turtle this
-- controller has EVER heard from (see loadPersisted() above), addressed
-- directly by its last-known computerId -- not rednet.lookup(), which
-- is only for discovering an id we don't already have. lib/fleet.lua's
-- listenLoop answers a "ping" with an immediate heartbeat, so a
-- previously-known turtle that's still genuinely alive reappears in
-- M.report() within moments of this controller coming back up, rather
-- than waiting out its own ~3s heartbeat cadence. A turtle whose own
-- process has actually died can't answer this (or anything else) either
-- way -- this can't revive one, only shorten how long a live one stays
-- looking stale after a controller reboot.
function M.pingKnownTurtles()
  for _, entry in pairs(roster) do
    if entry.computerId then
      rednet.send(entry.computerId, { type = "ping" }, PROTOCOL)
    end
  end
end

-- A turtle's own screen is only 39 columns wide, and lib/exec.lua's
-- wrapTerm mirrors that real terminal faithfully -- CraftOS's print()
-- word-wraps anything longer than that INTO the pendingLog buffer
-- itself, as genuine embedded "\n"s, before a chunk of it is ever
-- shipped here. Prefixing the whole chunk once (the old behavior) tags
-- only its first physical line; every wrapped continuation line arrives
-- with no sender attribution at all -- confirmed live as bare fragments
-- like "the left" showing up with no context, and (worse for
-- `turtlectl.py console --silent`) with no way to tell they're the tail
-- of an otherwise-filtered "vertical: spotted ..." line. Prefixing every
-- physical line lets a human read a wrapped line's sender directly, and
-- lets console --silent's own continuation heuristic (see there) work
-- at all.
local function prefixEachLine(id, text)
  local prefix = "[" .. tostring(id) .. "] "
  local trailingNewline = text:sub(-1) == "\n"
  local body = trailingNewline and text:sub(1, -2) or text
  local out = {}
  for line in (body .. "\n"):gmatch("(.-)\n") do
    out[#out + 1] = prefix .. line
  end
  local result = table.concat(out, "\n")
  if trailingNewline then result = result .. "\n" end
  return result
end

-- Handles one incoming rednet message already known to be on our
-- protocol. "result" messages are deliberately not handled here -- they
-- only ever matter to a specific M.proxy() call waiting on a matching
-- cmd_id, which checks for them itself in its own wait loop below.
--
-- This is called both by dom-main/controller/fleet_listener.lua's own
-- always-on receive loop AND reentrantly by every currently-blocked
-- M.proxy() call (see that function's own comment) -- CraftOS resumes
-- every coroutine parked in rednet.receive() with the same event, so a
-- single log push from one turtle can reach this function once per
-- listener that happens to be blocked at that moment, not once overall.
-- Harmless for "heartbeat" (upsert() just overwrites the same roster
-- entry again), but "log" would otherwise append the same text N times
-- -- worse now that dom-main/controller/scheduler.lua dispatches
-- several turtles concurrently, since several proxy() calls can be
-- blocked at once. lastLogSeq skips a push already seen from that
-- sender, by lib/fleet.lua's own monotonic per-turtle `seq`.
function M.handleMessage(senderId, message)
  if type(message) ~= "table" then return end
  if message.type == "heartbeat" then
    upsert(senderId, message)
  elseif message.type == "log" and message.id and message.text then
    if message.seq == nil or lastLogSeq[message.id] ~= message.seq then
      lastLogSeq[message.id] = message.seq
      exec.append(prefixEachLine(message.id, tostring(message.text)))
    end
  elseif message.type == "route_request" and message.request_id and message.from and message.to then
    -- Only enqueues -- dom-main/controller/router.lua's own M.run()
    -- coroutine does the actual (potentially slow) A* search, so this
    -- stays fast enough to never delay dom-main/controller/
    -- fleet_listener.lua's receive loop from handling anything else.
    dofile("/dom-main/controller/router.lua").enqueue(senderId, message.request_id, message.from, message.to, message.tolerance)
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
      fuelItems = entry.fuelItems,
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

-- The turtle whose block observations have gone longest unpulled -- a
-- proxy for "has accumulated the most unreported data" without needing
-- turtles to report their own buffer size. dom-main/controller/
-- block_sync.lua's whole scheduling policy is just "call this, then
-- pull from whoever it names" -- naturally round-robins the entire
-- roster over time since pulling resets a turtle's own lastBlockPull to
-- the newest timestamp. Returns nil if the roster is empty.
function M.leastRecentlyPulled()
  local bestName, bestTime = nil, nil
  for name, entry in pairs(roster) do
    if bestTime == nil or entry.lastBlockPull < bestTime then
      bestName, bestTime = name, entry.lastBlockPull
    end
  end
  return bestName
end

function M.markBlockPull(name, timestamp)
  local entry = roster[name]
  if entry then entry.lastBlockPull = timestamp end
end

-- Requests up to maxEntries buffered block observations from turtle
-- `name` and blocks (up to timeoutSeconds) for the reply. A dedicated
-- message pair ("pull_blocks"/"blocks"), not M.proxy()'s exec/"result"
-- RPC -- that path stringifies its return value for human console
-- display (lib/exec.lua), which would mean serializing a block table to
-- text just to re-parse it back on this end. Returns the entries table
-- on success, or nil, reason on failure (unknown turtle or timeout).
function M.pullBlocks(name, maxEntries, timeoutSeconds)
  local entry = roster[name]
  if not entry then return nil, "unknown turtle: " .. tostring(name) end

  rednet.send(entry.computerId, { type = "pull_blocks", max_entries = maxEntries }, PROTOCOL)

  local deadline = os.clock() + (timeoutSeconds or DEFAULT_TIMEOUT)
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then
      return nil, "timeout waiting for " .. name
    end
    local senderId, message = rednet.receive(PROTOCOL, remaining)
    if senderId == nil then
      return nil, "timeout waiting for " .. name
    end
    if type(message) == "table" then
      if senderId == entry.computerId and message.type == "blocks" then
        return message.entries
      end
      -- Not our reply -- still worth recording, same reasoning as
      -- M.proxy()'s identical wait loop above.
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

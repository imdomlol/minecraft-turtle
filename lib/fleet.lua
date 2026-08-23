--[[----------------------------------------------------------------------
  lib/fleet.lua -- listens for commands from this dimension's controller
  over rednet, instead of lib/remote.lua's HTTP polling of the relay
  directly. This is what a turtle runs now: the controller is the only
  thing that talks to server/relay.py, and turtles talk to it over
  rednet through the ender modem equipped in their left slot.

  Discovery is automatic and needs no setup wizard (contrast
  remote-setup.lua's url/token prompt): PROTOCOL is a fixed constant, and
  rednet.lookup() only ever finds a controller in the same dimension,
  since ender modems can't cross dimensions -- there is nothing to type
  in and nothing that could point a turtle at the wrong dimension's
  controller by mistake.

  Identity (lib/identity.lua) is picked blind here -- there's no relay
  /status to check for a name already in use before persisting one, the
  way lib/remote.lua's cfg lets it do. So registration (piggybacked on
  the first heartbeat) can race another turtle onto the same name; the
  controller is the single authority that actually knows the whole
  roster, so it's the one that detects a real collision and tells the
  loser to rename via a "rename" message -- see listenLoop below.

  Like lib/remote.lua, delegates "run this command and capture its
  output" to lib/exec.lua, which is shared between both transports.

  Also installs lib/worldmap.lua at startup, so every turtle.inspect*()
  call anywhere in the codebase feeds the controller's world map; a
  "pull_blocks" message here just drains and forwards whatever's
  accumulated, on request.

  Every heartbeat reply piggybacks the controller's current version
  number (see dom-main/controller/roster.lua's upsert()) through to
  lib/updater.lua, and checks right after whether it's now safe to
  reboot for a pending update -- see that module for the actual policy.
------------------------------------------------------------------------]]

local exec = dofile("/lib/exec.lua")

local PROTOCOL           = "turtle-fleet-v1"
local MODEM_SIDE         = "left"  -- ender modem is always equipped here, per hardware convention
local DISCOVERY_BACKOFF  = 10      -- seconds between rednet.lookup() retries when no controller answers
local HEARTBEAT_INTERVAL = 3       -- seconds between status heartbeats (mirrors lib/remote.lua's POLL_INTERVAL)
local LOG_PUSH_INTERVAL  = 1.5     -- seconds between live-console flushes

local M = {}

-- Exposed so dom-main/controller/*.lua can dofile() this module purely to
-- get at the same constant, rather than duplicating the string and
-- risking the two sides drifting apart.
M.PROTOCOL = PROTOCOL

-- Blocks until a controller answers, retrying with backoff -- mirrors
-- lib/remote.lua's pollLoop error-backoff shape, just for discovery
-- instead of an HTTP error. rednet.lookup() with no hostname returns the
-- ids of every computer hosting PROTOCOL; only one is expected per
-- dimension, so the first is taken.
local function discoverController()
  local warned = false
  while true do
    local ids = { rednet.lookup(PROTOCOL) }
    if #ids > 0 then
      if warned then print("fleet: controller found.") end
      return ids[1]
    end
    if not warned then
      print("fleet: no controller found, retrying...")
      warned = true
    end
    sleep(DISCOVERY_BACKOFF)
  end
end

-- Blocks forever, answering exec requests from the controller and
-- applying a "rename" message (see header comment) by writing the new
-- identity through `ident` -- a shared mutable box (see M.run()) rather
-- than a plain upvalue, since heartbeatLoop/logLoop (separate closures,
-- run in parallel) need to see the change immediately too.
local function listenLoop(ident, controllerId)
  while true do
    local senderId, message = rednet.receive(PROTOCOL)
    if senderId == controllerId and type(message) == "table" then
      if message.type == "exec" then
        local ok, output = exec.run(message.command)
        rednet.send(controllerId, {
          type = "result", cmd_id = message.cmd_id, ok = ok, output = output,
        }, PROTOCOL)
      elseif message.type == "pull_blocks" then
        -- A dedicated request/reply pair rather than routing through
        -- exec/"result" -- that path stringifies its return value for
        -- human console display (see lib/exec.lua), which would mean
        -- serializing a block-observation table to text here just to
        -- re-parse it back into a table on the controller. rednet can
        -- carry the real table directly instead.
        local entries = dofile("/lib/worldmap.lua").drain(message.max_entries)
        rednet.send(controllerId, { type = "blocks", entries = entries }, PROTOCOL)
      elseif message.type == "rename" and message.name then
        print("fleet: controller renamed us to " .. message.name .. " (collision)")
        dofile("/lib/identity.lua").set(message.name)
        ident.id = message.name
      elseif message.type == "version" and message.value then
        dofile("/lib/updater.lua").noteControllerVersion(message.value)
      end
    end
  end
end

-- Sends a status heartbeat every HEARTBEAT_INTERVAL seconds -- doubles as
-- registration on the first send, since the controller has no separate
-- "register" message to wait for. Fire-and-forget over rednet -- there's
-- no delivery confirmation the way an HTTP response gives lib/remote.lua
-- one, so a heartbeat lost to the controller being briefly out of range
-- or mid-reboot is simply skipped; the next tick re-establishes
-- freshness regardless.
local function heartbeatLoop(ident, controllerId)
  local nav = dofile("/lib/nav.lua")
  local job = dofile("/lib/job.lua")
  local updater = dofile("/lib/updater.lua")
  local fuel = dofile("/lib/fuel.lua")

  while true do
    rednet.send(controllerId, {
      type = "heartbeat",
      id = ident.id,
      label = os.getComputerLabel(),
      fuel = turtle.getFuelLevel(),
      -- Distinct from `fuel` (tank level): how many unspent fuel items
      -- are sitting in inventory, right now the only thing
      -- dom-main/controller/scheduler.lua's fuel-rescue can actually
      -- hand to a stranded turtle.
      fuelItems = fuel.spareFuelItems(),
      position = nav.getPosition(),
      job = job.status(),
    }, PROTOCOL)
    -- Reuses this same ~3s cadence rather than adding a whole new loop
    -- just to poll "is it safe to reboot yet" -- see lib/updater.lua.
    updater.checkAndReboot()
    sleep(HEARTBEAT_INTERVAL)
  end
end

-- Ships exec's pendingLog to the controller every LOG_PUSH_INTERVAL
-- seconds, for `turtlectl.py console <controller>` to tail (the
-- controller aggregates every turtle's log into its own relay /log
-- feed). Same best-effort, no-retry shape as heartbeatLoop above.
local function logLoop(ident, controllerId)
  while true do
    sleep(LOG_PUSH_INTERVAL)
    local chunk = exec.pendingLog()
    if chunk ~= "" then
      rednet.send(controllerId, { type = "log", id = ident.id, text = chunk }, PROTOCOL)
      exec.dropSentLog(chunk)
    end
  end
end

-- Blocks forever: discovers this dimension's controller, registers via
-- the first heartbeat, then answers exec requests while streaming
-- status/log traffic back. Meant to run alongside job.run() via
-- parallel.waitForAny, same shape as lib/remote.lua's M.run().
function M.run()
  if not rednet then
    print("fleet: rednet api disabled, cannot reach a controller.")
    return
  end

  -- Retries rather than giving up outright: right after a server
  -- restart, peripheral attachment can briefly lag chunk loading, and a
  -- one-shot check-and-quit here would strand this turtle unreachable
  -- for the rest of the boot session (only a manual reboot would ever
  -- retry) -- exactly the kind of permanent-disconnect risk worth
  -- guarding against.
  local warnedNoModem = false
  while not peripheral.isPresent(MODEM_SIDE) do
    if not warnedNoModem then
      print("fleet: no modem equipped in the " .. MODEM_SIDE .. " slot, retrying...")
      warnedNoModem = true
    end
    sleep(DISCOVERY_BACKOFF)
  end
  if warnedNoModem then print("fleet: modem found.") end

  if not rednet.isOpen(MODEM_SIDE) then
    rednet.open(MODEM_SIDE)
  end

  dofile("/lib/worldmap.lua").install()

  local ident = { id = dofile("/lib/identity.lua").get(nil) }
  print("fleet: identity is " .. ident.id)

  print("fleet: looking for a controller...")
  local controllerId = discoverController()
  print("fleet: controller is computer #" .. controllerId)

  term.redirect(exec.wrapTerm(term.current()))

  parallel.waitForAny(
    function() listenLoop(ident, controllerId) end,
    function() heartbeatLoop(ident, controllerId) end,
    function() logLoop(ident, controllerId) end
  )
end

return M

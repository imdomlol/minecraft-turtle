--[[----------------------------------------------------------------------
  dom-main/controller/scheduler.lua -- the autopilot: keeps every turtle
  either working or being helped back to work, whenever
  dom-main/controller/mode.lua's M.shouldAutopilot() says it's allowed to.

  Every tick, for each turtle currently in the roster:
    - stranded (M.isStranded() -- can't reach the worksite's known
      chest under its own power at all) -> attemptRescue(): send the
      closest-to-chest turtle that CAN reach the chest (lib/rescue.lua --
      idle or currently mining, both equally eligible: either way it
      routes through the chest first to fetch fuel, both for itself and
      to hand over, rather than assuming it already has spare fuel on
      hand) to pause whatever it's doing, fetch fuel, hand half over to
      the stranded turtle, then resume its own paused work.
    - idle and needsSelfRefuel() (can reach the chest on its own, just
      not enough left to keep mining safely once there) -> M.dispatchToChest():
      send it to refuel itself, no second turtle needed, then back to
      work -- this is the common case a turtle's own dynamic minFuel
      floor (see dom-main/mining/vertical.lua) is actually SIZED for:
      it stops with enough margin to comfortably land here, not in
      M.isStranded() above.
    - idle otherwise -> assignWork(): claim this turtle's
      dom-main/controller/worksite.lua cell (sticky -- the same turtle
      always gets the same cell back), goto its origin, and start
      mine_vertical there with the worksite's known chest wired in as
      chestPos.

  A rescued turtle resumes from its checkpointed mid-pass position rather
  than restarting its cell from the beginning -- see assignWork()'s own
  checkpoint-resume branch. Every dispatch (rescue or ordinary work
  assignment) also requires a real, GPS-anchored position (see
  hasKnownPosition()) -- a turtle whose position is unanchored gets left
  alone rather than sent an absolute-coordinate command aimed at nowhere.

  Every dispatch (goto + start mining, or a rescue trip) is built from
  one or more blocking dom-main/controller/roster.lua M.proxy() calls,
  but every turtle needing attention in the same tick runs as its own
  concurrent task under parallel.waitForAll (see M.tick()) -- a slow
  dispatch only blocks that one turtle's own task, never the rest of the
  fleet, and (same as before) never the rest of the controller either
  (see controller_main.lua's own top-level parallel.waitForAny).
------------------------------------------------------------------------]]

if _G.__SCHEDULER_MODULE then return _G.__SCHEDULER_MODULE end

local roster = dofile("/dom-main/controller/roster.lua")
local worksite = dofile("/dom-main/controller/worksite.lua")
local mode = dofile("/dom-main/controller/mode.lua")
local fuel = dofile("/lib/fuel.lua")

-- table.unpack (Lua 5.2+/CC:Tweaked) vs the global unpack (Lua 5.1,
-- used by this repo's plain-lua5.1 test harnesses) -- whichever exists.
local unpack = table.unpack or unpack

local TICK_INTERVAL           = 5   -- seconds between scheduler passes
-- Flat fallback for M.isStranded()/M.needsSelfRefuel() ONLY when there's
-- no worksite chest or no known position to compute the real,
-- distance-based figures from (see both functions' own comments) --
-- not the primary judgment call whenever that info is available.
local STRANDED_FUEL_THRESHOLD = 20
local DISPATCH_TIMEOUT        = 300 -- seconds -- generous: a fresh/idle turtle's origin could be far away
-- Generous, well beyond DISPATCH_TIMEOUT above: lib/rescue.lua's trip
-- now includes waiting (bounded, up to 180s -- a full mining leg's
-- worth of real dig/move time, see its own PAUSE_WAIT_TIMEOUT comment)
-- for a mining rescuer's job to actually pause, PLUS a stop at the
-- chest before ever reaching the stranded turtle -- a much longer round
-- trip than the old direct-to-target dispatch. Must comfortably exceed
-- that 180s pause-wait on its own, with real room left over for the
-- actual travel.
local RESCUE_TIMEOUT          = 600
local REFUEL_TIMEOUT          = 30
local REFUEL_TRIP_TIMEOUT     = 120
local GPS_FIX_TIMEOUT         = 15
local HOMELINK_CHECK_TIMEOUT  = 15
local HOMELINK_RECOVER_TIMEOUT = 120 -- generous: recovery may involve a real trip back to the chest

local MINE_DEFAULT_LENGTH              = 10
local MINE_DEFAULT_OBSERVANT           = true
local MINE_DEFAULT_THOROUGH            = true
local MINE_DEFAULT_STEP_DOWN_OBSERVANT = 5
local MINE_DEFAULT_STEP_DOWN_PLAIN     = 2
local MINE_MAX_VEIN_BLOCKS             = 48

local M = {}

-- Serializes a plain Lua value (used for mine_vertical's params table)
-- into Lua source text, so a command built here can embed it directly --
-- the same job server/turtlectl.py's build_shortcut() does from the
-- Python side, just needed here too since this table is assembled
-- controller-side, not by an operator's CLI invocation.
local function luaLiteral(v)
  local t = type(v)
  if t == "nil" then return "nil" end
  if t == "string" then return string.format("%q", v) end
  if t == "number" or t == "boolean" then return tostring(v) end
  if t == "table" then
    local parts = {}
    for k, vv in pairs(v) do
      parts[#parts + 1] = "[" .. luaLiteral(k) .. "] = " .. luaLiteral(vv)
    end
    return "{ " .. table.concat(parts, ", ") .. " }"
  end
  error("scheduler: cannot serialize a " .. t .. " to a Lua literal", 2)
end

-- Pure decision helpers -- exported so tests can drive them directly
-- against a hand-built roster snapshot, without needing a real rednet
-- round trip.
function M.isIdle(entry)
  return entry.job ~= nil and entry.job.current == "idle"
end

-- `name` (optional) lets this peek at the turtle's ACTUAL prospective
-- cell (worksite.assignCell() is idempotent/sticky -- safe to call
-- speculatively, it never reassigns an existing turtle or hands out a
-- cell that isn't really about to be theirs) whenever entry.job.params
-- doesn't have a real length yet (idle, about to be freshly assigned,
-- or between passes -- job.lua's status() always reports params={}
-- while idle, regardless of what the last job actually used). Confirmed
-- live: without this, a turtle whose fuel was enough for the flat
-- MINE_DEFAULT_LENGTH estimate but not a zone's actual (longer) cell
-- length slipped through M.needsSelfRefuel() here, got dispatched to
-- mine anyway, and immediately self-stopped the instant dom-main/
-- mining/vertical.lua recomputed the real floor with the real length --
-- then got redispatched into the identical failure forever, since every
-- later tick's estimate was still wrong the same way (idle always
-- resets params to {}, so the mismatch never self-corrected).
local function miningFuelBudget(entry, name)
  local params = entry.job and entry.job.params or {}
  if not params.length and name then
    local cell = worksite.assignCell(name)
    if cell then params = worksite.jobFor(cell).params end
  end
  local length = params.length or MINE_DEFAULT_LENGTH
  local observant = params.observant
  if observant == nil then observant = MINE_DEFAULT_OBSERVANT end
  local thorough = params.thorough
  if thorough == nil then thorough = MINE_DEFAULT_THOROUGH end
  local stepDown = params.stepDown
    or (observant and MINE_DEFAULT_STEP_DOWN_OBSERVANT or MINE_DEFAULT_STEP_DOWN_PLAIN)
  return length + stepDown + (thorough and MINE_MAX_VEIN_BLOCKS or 0)
end

local function selfRefuelTarget(entry, chest, name)
  return fuel.safeReturnFuel(entry.position, chest) + miningFuelBudget(entry, name)
end

local function hasInventoryFuel(entry)
  return type(entry.fuelItems) == "number" and entry.fuelItems > 0
end

-- Genuinely can't reach the worksite's known chest under its own power
-- -- fuel below the direct (1x) travel cost there, per lib/fuel.lua's
-- M.travelCost(). This is deliberately NOT the same bar as dom-main/
-- mining/vertical.lua's own minFuel floor (M.safeReturnFuel()'s 2x
-- default): that one is set to make a turtle stop with a comfortable
-- safety margin still in the tank, specifically so it USUALLY lands in
-- M.needsSelfRefuel() below (can still get itself to the chest) rather
-- than here. M.isStranded() is for the narrower, more serious case --
-- can't even make it that far -- which actually needs another turtle's
-- help. Falls back to the flat STRANDED_FUEL_THRESHOLD when there's no
-- known position or no worksite chest to compute the real distance
-- from (can't judge "can it reach the chest" without knowing where
-- either one is).
function M.isStranded(entry)
  if type(entry.fuel) ~= "number" then return false end
  if not M.hasKnownPosition(entry) then
    return entry.fuel < STRANDED_FUEL_THRESHOLD
  end
  local chest = worksite.nearestChest(entry.position)
  if not chest then
    return entry.fuel < STRANDED_FUEL_THRESHOLD
  end
  return entry.fuel < fuel.travelCost(entry.position, chest)
end

-- Can reach the chest on its own, but doesn't have enough to keep
-- mining safely once there and back -- exactly the gap that used to
-- fall through both checks entirely: below dom-main/mining/
-- vertical.lua's own (now dynamic) minFuel floor, but well above
-- M.isStranded()'s much narrower "can't even reach the chest" bar, so
-- nothing ever recognized it needed anything. Confirmed live: a turtle
-- in exactly this state just kept getting redispatched into the
-- identical immediate "insufficient fuel" stop, forever, with no rescue
-- ever triggered (M.isStranded()'s old flat threshold never crossed)
-- and no attempt to send it to refuel either. Cheaper than a full
-- rescue -- no second turtle tied up -- since it can get there itself;
-- see M.dispatchToChest() below.
function M.needsSelfRefuel(entry, name)
  if type(entry.fuel) ~= "number" then return false end
  if not M.hasKnownPosition(entry) then return false end
  local chest = worksite.nearestChest(entry.position)
  if not chest then return false end
  if M.isStranded(entry) then return false end
  return entry.fuel < selfRefuelTarget(entry, chest, name)
end

-- False for a turtle whose reported position isn't anchored to the real
-- world -- lib/nav.lua's own boot default (no persisted position, no GPS
-- fix) is source="relative", an arbitrary local (0,0,0) with no
-- relationship to actual world coordinates. Dispatching ANY absolute-
-- coordinate command (a rescue target, a goto, a cell origin) built from
-- or aimed at an entry like that sends a turtle to nowhere -- confirmed
-- live: a stranded turtle stuck at a fictional (0,0,0) got "rescued" by
-- sending a perfectly good turtle to pathfind.goto(0, 0, 0), hundreds of
-- blocks outside the working area. Every dispatch below (rescue target,
-- rescuer choice, and ordinary work assignment) must check this first;
-- an unanchored turtle needs an operator's `setpos` before autopilot can
-- touch it at all.
function M.hasKnownPosition(entry)
  return entry.position ~= nil and entry.position.gpsFixed == true
end

local function expectedWorksiteId(name)
  local cell = worksite.assignCell(name)
  if not cell then return nil end
  return worksite.jobFor(cell).params.__worksiteId
end

function M.isCurrentWorksiteJob(name, params)
  if type(params) ~= "table" then return false end
  local expected = expectedWorksiteId(name)
  return expected ~= nil and params.__worksiteId == expected
end

local function isIgnored(name)
  return mode.isIgnored and mode.isIgnored(name)
end

local function isStaleMiningJob(name, entry)
  if isIgnored(name) then return false end
  return entry and entry.job and entry.job.current == "mine_vertical"
    and not M.isCurrentWorksiteJob(name, entry.job.params)
end

-- The best rescuer for `strandedName`: not itself stranded (it needs to
-- be able to reach the chest under its own power to fetch fuel there --
-- see M.attemptRescue()/lib/rescue.lua, which routes every rescue
-- through the worksite's chest rather than assuming the rescuer already
-- has spare fuel on hand), not in `exclude` (every turtle already given
-- an order elsewhere this same tick -- see M.tick()), with a real
-- position (M.hasKnownPosition -- an unanchored rescuer can't reliably
-- pathfind to anything either). Idle and currently-mining turtles are
-- deliberately equally eligible -- a mining candidate has its job paused
-- and resumed automatically (lib/rescue.lua, lib/job.lua's
-- M.resumeOrRequest()), and either way the rescuer is topping up at the
-- chest anyway, so "already has fuel to spare" no longer matters for the
-- choice. Ranked by whichever eligible candidate is closest to the
-- chest nearest the STRANDED turtle (see worksite.lua's M.nearestChest()
-- -- with multiple chests configured, this is the one the rescuer will
-- actually be sent to fetch fuel from and deliver from, so it's the only
-- leg of the total trip that actually varies by which turtle gets
-- picked). nil if nobody qualifies, or if there's no worksite chest
-- configured at all (nowhere to send anyone to fetch fuel from).
function M.pickRescuer(snapshot, strandedName, exclude)
  local strandedEntry = snapshot[strandedName]
  local chest = strandedEntry and M.hasKnownPosition(strandedEntry)
    and worksite.nearestChest(strandedEntry.position)
  if not chest then return nil end

  local best, bestCost = nil, nil
  for name, entry in pairs(snapshot) do
    if name ~= strandedName and not (exclude and exclude[name])
        and not isIgnored(name) and not M.isStranded(entry) and M.hasKnownPosition(entry) then
      local cost = fuel.travelCost(entry.position, chest)
      if not best or cost < bestCost then
        best, bestCost = name, cost
      end
    end
  end
  return best
end

-- Claims (or reuses) this turtle's worksite cell, and dispatches it
-- there to start mining -- unless it already has a resumable checkpoint
-- for mine_vertical (see lib/job.lua's M.checkpoint()/M.resumeOrRequest()
-- and dom-main/mining/vertical.lua's "insufficient fuel" path, currently
-- the only way one gets left behind), in which case it resumes exactly
-- where it left off instead: no reason to walk back to the cell's
-- origin and re-dig already-open ground just because a stop happened to
-- be a fuel-rescue rather than a crash. This applies uniformly to every
-- idle-turtle dispatch, not just a just-rescued turtle -- a rescuer
-- turtle that itself has unfinished business in its own cell (it was
-- only ever picked from turtles already idle, so it's not being pulled
-- off active work, but it could have its own leftover checkpoint from
-- some earlier stop) gets exactly the same treatment the next time it's
-- assigned. Returns true, output on success, or false, reason (no
-- worksite configured, every cell taken, couldn't reach the cell, etc).
function M.assignWork(name)
  local cell, cellErr = worksite.assignCell(name)
  if not cell then
    return false, cellErr
  end

  local jobSpec = worksite.jobFor(cell)
  -- Whichever configured chest is nearest the cell's own origin -- with
  -- multiple chests (see worksite.lua's M.nearestChest()), a turtle's
  -- unload trips should head for the one actually close to where it's
  -- working, not always the same fixed one regardless of cell.
  local chest = worksite.nearestChest(jobSpec.origin)
  if chest then
    jobSpec.params.chestPos = { x = chest.x, y = chest.y, z = chest.z, bounds = chest.bounds }
  end

  local command = string.format(
    'local job = dofile("/lib/job.lua"); '
      .. 'local expectedWorksiteId = %s; '
      .. 'local saved = job.loadCheckpoint(); '
      .. 'if saved and saved.name == "mine_vertical" and job.hasJob("mine_vertical") then '
      .. '  local params = saved.params or {}; '
      .. '  if params.__worksiteId == expectedWorksiteId then '
      .. '    params.__resume = saved.checkpoint; '
      .. '    job.request("mine_vertical", params); '
      .. '    return true, "resumed from checkpoint"; '
      .. '  end; '
      .. '  job.clearCheckpoint(); '
      .. 'end; '
      .. 'job.request("goto_then_mine", { x = %d, y = %d, z = %d, tolerance = 0, allowDig = "safe", jobParams = %s }); '
      .. 'return true, "queued goto_then_mine"',
    luaLiteral(jobSpec.params.__worksiteId), jobSpec.origin.x, jobSpec.origin.y, jobSpec.origin.z,
    luaLiteral(jobSpec.params)
  )

  local ok, output = roster.proxy(name, command, DISPATCH_TIMEOUT)
  if not ok then
    print("scheduler: could not get " .. name .. " to its cell: " .. tostring(output))
    return false, output
  end
  print("scheduler: " .. name .. " mining its cell (" .. tostring(output) .. ")")
  return true, output
end

function M.cancelStaleWork(name, entry)
  local currentId = entry and entry.job and entry.job.params and entry.job.params.__worksiteId
  local expectedId = expectedWorksiteId(name)
  print("scheduler: stopping stale mining job for " .. name
    .. " (current=" .. tostring(currentId) .. ", expected=" .. tostring(expectedId) .. ")")
  local command = 'local job = dofile("/lib/job.lua"); job.stop(); job.clearCheckpoint(); return true, job.status()'
  local ok, output = roster.proxy(name, command, REFUEL_TIMEOUT)
  if not ok then
    print("scheduler: could not stop stale mining job for " .. name .. ": " .. tostring(output))
    return false, output
  end
  return true, output
end

function M.refreshGPS(name)
  local command = 'local nav = dofile("/lib/nav.lua"); local ok, result = nav.reacquireGPS(); if not ok then error(result) end; return nav.report()'
  local ok, output = roster.proxy(name, command, GPS_FIX_TIMEOUT)
  if not ok then
    print("scheduler: gpsfix failed for " .. name .. ": " .. tostring(output))
    return false, output
  end
  return true, output
end

-- How long a home-link chest may plausibly sit in "placed" state before
-- it's treated as stuck rather than mid-transfer: dom-main/mining/
-- vertical.lua's tryHomeLink() runs place -> refuel -> drop -> pickUp
-- as one uninterrupted synchronous call with no cooperative-stop check
-- anywhere in between, so under normal operation this never takes more
-- than a few seconds. Anything still "placed" this much later means
-- whatever ran that trip got cut off outright (crash, reboot, chunk
-- unload) before ever reaching pickUp() -- lib/homelink.lua's own
-- M.place() now self-heals this on a turtle's own next unload attempt
-- (see that commit), but a turtle whose inventory doesn't fill up again
-- for a while would otherwise leave its chest sitting exposed in the
-- world for just as long, unnoticed by anyone. This sweep exists so the
-- autopilot notices and fixes it long before that.
local HOMELINK_STALE_MS = 60000

-- Sends `name` the "recover_home_link" job (dom-main/turtle_main.lua)
-- -- a plain job.request(), the same cooperative interrupt mechanism
-- goto/stop already use, so this never races a job that's actively
-- moving the turtle via some OTHER concurrently-running exec command.
function M.recoverHomeLink(name, ageMs)
  if ageMs then
    print("scheduler: " .. name .. "'s home-link chest has been stuck \"placed\" for "
      .. math.floor(ageMs / 1000) .. "s -- sending it back to reclaim it")
  else
    print("scheduler: " .. name .. " went idle with an un-recovered home-link chest -- sending it back to reclaim it")
  end
  local recovered, info = roster.proxy(name, 'return dofile("/lib/job.lua").request("recover_home_link", {})', HOMELINK_RECOVER_TIMEOUT)
  if not recovered then
    print("scheduler: could not send " .. name .. " to recover its home-link chest: " .. tostring(info))
  end
end

-- Reads (never moves) `name`'s own recorded home-link state. Returns
-- the age in ms since it was placed if status == "placed", or nil if
-- it's anything else (including unreachable this tick -- try again
-- next sweep, not worth logging).
local function homeLinkPlacedAge(name)
  local statusCmd = 'local f = fs.open("/state/homelink.state", "r"); '
    .. 'if not f then return "none" end; '
    .. 'local text = f.readAll(); f.close(); '
    .. 'local ok, decoded = pcall(textutils.unserializeJSON, text); '
    .. 'if not ok or type(decoded) ~= "table" or decoded.status ~= "placed" then return "none" end; '
    .. 'return "placed:" .. tostring(os.epoch("utc") - (decoded.at or 0))'
  local ok, output = roster.proxy(name, statusCmd, HOMELINK_CHECK_TIMEOUT)
  if not ok then return nil end
  local ageStr = output and output:match("placed:(%d+)")
  return ageStr and tonumber(ageStr)
end

-- Background sweep for a turtle that's STAYING busy (mining) with a
-- home-link chest stuck "placed" the whole time -- see
-- M.tick()'s own idle-dispatch pass for the OTHER half of this: the
-- moment covered here alone used to lose a race against ordinary work
-- dispatch (confirmed live -- a turtle that finished/failed
-- recover_home_link and landed idle got sent straight back to mining
-- by that same tick's idle pass, before this sweep (which only runs
-- every HOMELINK_CHECK_EVERY_N_TICKS) ever got a chance to notice
-- again). HOMELINK_STALE_MS's grace window exists because a MINING
-- turtle can legitimately be mid-transfer for a few seconds; an idle
-- one never can (tryHomeLink() only ever runs while mine_vertical is
-- the current job), which is why the idle-dispatch check needs no such
-- grace window at all.
function M.checkHomeLink(name)
  local age = homeLinkPlacedAge(name)
  if not age or age <= HOMELINK_STALE_MS then return end
  M.recoverHomeLink(name, age)
end

-- Sends `rescuerName` (already chosen -- see M.tick()/M.pickRescuer())
-- to pause its own work (if any), fetch fuel at the worksite's chest,
-- and hand half of what it's carrying to `strandedName` -- see
-- lib/rescue.lua for the actual turtle-side sequence -- then has the
-- stranded turtle refuel and reassigns it its own (same, sticky) cell.
function M.attemptRescue(strandedName, strandedEntry, rescuerName)
  local pos = strandedEntry.position
  local chest = worksite.nearestChest(pos)
  print("scheduler: dispatching " .. rescuerName .. " to fetch fuel and refuel stranded turtle " .. strandedName)

  local rescueCommand = string.format(
    'return dofile("/lib/rescue.lua").perform(%d, %d, %d, %d, %d, %d, %s)',
    pos.x, pos.y, pos.z, chest.x, chest.y, chest.z, luaLiteral(chest.bounds)
  )

  local ok, output = roster.proxy(rescuerName, rescueCommand, RESCUE_TIMEOUT)
  if not ok then
    print("scheduler: rescue by " .. rescuerName .. " failed: " .. tostring(output))
    return false, output
  end
  print("scheduler: " .. rescuerName .. " -- " .. tostring(output))

  -- Target dom-main/mining/vertical.lua's own dynamic minFuel floor
  -- (lib/fuel.lua's M.safeReturnFuel(), from the stranded turtle's
  -- OWN current position -- unchanged since the rescuer came TO it,
  -- not the other way around), not just "1" -- ensureFuel(1) used to
  -- be enough back when minFuel was a flat, much lower number, but
  -- against the now-dynamic floor it would routinely leave the turtle
  -- still below what mine_vertical needs, hitting the identical
  -- "insufficient fuel" stop again the moment it resumed.
  local refuelTarget = chest and selfRefuelTarget(strandedEntry, chest, strandedName) or 1
  local refuelOk, refuelOutput = roster.proxy(strandedName,
    "local ok, reason = dofile(\"/lib/fuel.lua\").ensureFuel(" .. refuelTarget .. "); "
      .. "if not ok then error(tostring(reason), 0) end; "
      .. "return true, \"refueled to \" .. tostring(turtle.getFuelLevel())",
    REFUEL_TIMEOUT)
  if not refuelOk then
    print("scheduler: " .. strandedName .. " still couldn't refuel after the rescue: " .. tostring(refuelOutput))
    return false, "refuel after rescue failed: " .. tostring(refuelOutput)
  end

  print("scheduler: " .. strandedName .. " refueled -- sending it back to its cell")
  return M.assignWork(strandedName)
end

-- For a turtle that M.needsSelfRefuel() -- enough fuel to reach the
-- worksite's known chest under its own power, just not enough to keep
-- mining safely once there -- rather than tying up a second turtle for
-- a full M.attemptRescue(), send it to the chest itself: reach it (
-- lib/chestfinder.lua, same non-destructive search dom-main/mining/
-- vertical.lua's own unloadIfFull() uses), top up from whatever fuel
-- is sitting there (lib/fuel.lua's M.ensureFuel(), which already tries
-- the turtle's own inventory first), then resume its cell exactly like
-- any other idle dispatch (M.assignWork() -- picks the checkpoint back
-- up if there is one, same as a real rescue does).
function M.dispatchToChest(name, entry)
  local chest = worksite.nearestChest(entry.position)
  local target = selfRefuelTarget(entry, chest, name)
  print("scheduler: sending " .. name .. " to the chest to refuel (enough to get there, not enough to keep mining safely)")

  local command = string.format(
    'local chestfinder = dofile("/lib/chestfinder.lua"); '
      .. 'local found, reason = chestfinder.find({ x = %d, y = %d, z = %d, bounds = %s }); '
      .. 'if not found then return false, "could not reach the chest: " .. tostring(reason) end; '
      .. 'local ok, refuelReason = dofile("/lib/fuel.lua").ensureFuel(%d); '
      .. 'if not ok then error("reached the chest but could not refuel: " .. tostring(refuelReason), 0) end; '
      .. 'return true, "refueled to " .. tostring(turtle.getFuelLevel())',
    chest.x, chest.y, chest.z, luaLiteral(chest.bounds), target
  )

  local ok, output = roster.proxy(name, command, REFUEL_TRIP_TIMEOUT)
  if not ok then
    print("scheduler: " .. name .. " couldn't refuel at the chest: " .. tostring(output))
    return false, output
  end
  print("scheduler: " .. name .. " " .. tostring(output) .. " -- sending it back to its cell")
  return M.assignWork(name)
end

-- Before dispatching a separate rescue turtle, let a stranded turtle
-- burn fuel items it is already carrying. This covers the common
-- handoff edge case where a rescuer successfully dropped coal into the
-- stranded turtle, but the controller never reached the post-delivery
-- refuel command because the rescuer later failed or timed out on its
-- own return trip.
function M.refuelFromInventory(name, entry)
  local chest = M.hasKnownPosition(entry) and worksite.nearestChest(entry.position)
  local target = chest and selfRefuelTarget(entry, chest, name) or 1
  print("scheduler: " .. name .. " is stranded but has fuel items -- trying inventory refuel before rescue")
  local ok, output = roster.proxy(name,
    "local ok, reason = dofile(\"/lib/fuel.lua\").ensureFuel(" .. target .. "); "
      .. "if not ok then error(tostring(reason), 0) end; "
      .. "return true, \"refueled to \" .. tostring(turtle.getFuelLevel())",
    REFUEL_TIMEOUT)
  if not ok then
    print("scheduler: " .. name .. " could not refuel from inventory: " .. tostring(output))
    return false, output
  end
  print("scheduler: " .. name .. " refueled from inventory -- sending it back to its cell")
  return M.assignWork(name)
end

-- One autopilot pass. Snapshots the roster's names to a plain array
-- first -- roster.proxy()'s own wait loop can add a brand-new entry
-- mid-dispatch (a turtle heartbeating for the first time while we're
-- blocked on someone else's), the same reasoning as roster.lua's own
-- proxyAll().
--
-- Rescues are resolved in their own pass, strictly before work
-- assignment, and every turtle a rescue touches (rescuer or rescued) is
-- recorded in `dispatched` immediately -- both here, before any
-- dispatch even starts, and checked by every later pickRescuer() call
-- and by the work-assignment pass below. Iteration order over a plain
-- Lua table (pairs()) isn't guaranteed, and without this a turtle picked
-- as a rescuer for one stranded turtle could otherwise also get handed
-- its own work order in the very same tick (if it's visited later in
-- the loop), or get picked as the rescuer for a *second* stranded
-- turtle before its first rescue trip is even done -- either way,
-- sending it two conflicting orders back to back.
--
-- Every turtle's dispatch (a rescue trip, or a plain work assignment) is
-- collected as its own task and run concurrently via
-- parallel.waitForAll, rather than one at a time in a plain loop: each
-- task's underlying roster.proxy() calls block only THAT task's own
-- coroutine on rednet.receive, so while one turtle is mid-journey to its
-- cell (or a rescuer is mid-journey to a stranded turtle), every other
-- turtle's dispatch is already in flight too, instead of queued up
-- behind it. Confirmed live as a real problem, not a hypothetical one:
-- with several turtles needing dispatch/rescue at once, the old
-- sequential loop visibly moved one turtle at a time, leaving the rest
-- idle for the full duration of whoever was dispatched first.
-- Ticks between each "scheduler: tick N, ..." heartbeat print -- purely
-- a liveness/visibility signal (there was previously no way to tell
-- from the console whether the autopilot was actually running at all,
-- versus just quiet because nothing currently needs attention), so it's
-- throttled well below TICK_INTERVAL's own cadence to avoid adding to
-- the console's existing noise.
local HEARTBEAT_EVERY_N_TICKS = 12 -- ~60s at the default 5s TICK_INTERVAL
local GPS_FIX_EVERY_N_TICKS = 12 -- ~60s at the default 5s TICK_INTERVAL
-- Deliberately tighter than GPS_FIX_EVERY_N_TICKS -- HOMELINK_STALE_MS
-- above is already a 60s grace window on top of this, so checking any
-- less often than that would just add pure detection lag on top of a
-- threshold that's already generous.
local HOMELINK_CHECK_EVERY_N_TICKS = 6 -- ~30s at the default 5s TICK_INTERVAL
local tickCount = 0

function M.tick()
  tickCount = tickCount + 1
  if not mode.shouldAutopilot() then
    if tickCount % HEARTBEAT_EVERY_N_TICKS == 0 then
      print("scheduler: tick " .. tickCount .. " -- autopilot off (mode=" .. tostring(mode.get()) .. ")")
    end
    return
  end

  local snapshot = roster.all()
  local names = {}
  for name in pairs(snapshot) do names[#names + 1] = name end

  local strandedCount, idleCount = 0, 0
  for name, entry in pairs(snapshot) do
    if not isIgnored(name) then
      if M.isStranded(entry) then strandedCount = strandedCount + 1
      elseif M.isIdle(entry) then idleCount = idleCount + 1 end
    end
  end
  if tickCount % HEARTBEAT_EVERY_N_TICKS == 0 then
    print("scheduler: tick " .. tickCount .. " -- " .. #names .. " known, "
      .. strandedCount .. " stranded, " .. idleCount .. " idle")
  end

  local dispatched = {}
  local tasks = {}
  local rescues = {} -- { {strandedName, entry, rescuerName}, ... }, resolved before any are dispatched
  for _, name in ipairs(names) do
    if isIgnored(name) then dispatched[name] = true end
  end

  for _, name in ipairs(names) do
    local entry = snapshot[name]
    if not dispatched[name] and isStaleMiningJob(name, entry) then
      dispatched[name] = true
      tasks[#tasks + 1] = function() M.cancelStaleWork(name, entry) end
    end
  end

  for _, name in ipairs(names) do
    local entry = snapshot[name]
    if entry and not dispatched[name] and M.isStranded(entry) then
      dispatched[name] = true
      if not M.hasKnownPosition(entry) then
        print("scheduler: " .. name .. " is stranded but has no reliable position -- needs a manual `setpos` before it can be rescued")
      elseif hasInventoryFuel(entry) then
        tasks[#tasks + 1] = function() M.refuelFromInventory(name, entry) end
      else
        local rescuerName = M.pickRescuer(snapshot, name, dispatched)
        if rescuerName then
          dispatched[rescuerName] = true
          rescues[#rescues + 1] = { name, entry, rescuerName }
        end
      end
    end
  end
  for _, r in ipairs(rescues) do
    local strandedName, strandedEntry, rescuerName = r[1], r[2], r[3]
    tasks[#tasks + 1] = function() M.attemptRescue(strandedName, strandedEntry, rescuerName) end
  end

  for _, name in ipairs(names) do
    local entry = snapshot[name]
    if entry and not dispatched[name] and M.isIdle(entry) then
      if not M.hasKnownPosition(entry) then
        print("scheduler: " .. name .. " is idle but has no reliable position -- needs a manual `setpos` before autopilot will dispatch it")
      else
        dispatched[name] = true
        -- The home-link check here is a real network round trip
        -- (roster.proxy), so it belongs inside this deferred task (runs
        -- concurrently with every other turtle's, via
        -- parallel.waitForAll below) rather than in the decision loop
        -- itself, which -- unlike this -- only ever does cheap local
        -- reads off the snapshot. Checked BEFORE ordinary work dispatch,
        -- every tick, not just on HOMELINK_CHECK_EVERY_N_TICKS's slower
        -- cadence -- see M.checkHomeLink()'s own comment for why this
        -- exact spot is what actually closes the race that sweep alone
        -- couldn't.
        tasks[#tasks + 1] = function()
          local age = homeLinkPlacedAge(name)
          if age then
            M.recoverHomeLink(name, age)
          elseif M.needsSelfRefuel(entry, name) then
            M.dispatchToChest(name, entry)
          else
            M.assignWork(name)
          end
        end
      end
    end
  end

  if tickCount % GPS_FIX_EVERY_N_TICKS == 0 then
    for _, name in ipairs(names) do
      if not dispatched[name] then
        tasks[#tasks + 1] = function() M.refreshGPS(name) end
      end
    end
  end

  if tickCount % HOMELINK_CHECK_EVERY_N_TICKS == 0 then
    for _, name in ipairs(names) do
      if not dispatched[name] and not isIgnored(name) then
        tasks[#tasks + 1] = function() M.checkHomeLink(name) end
      end
    end
  end

  if #tasks > 0 then
    parallel.waitForAll(unpack(tasks))
  end
end

function M.run()
  while true do
    sleep(TICK_INTERVAL)
    M.tick()
  end
end

_G.__SCHEDULER_MODULE = M
return M

--[[----------------------------------------------------------------------
  dom-main/controller/scheduler.lua -- the autopilot: keeps every turtle
  either working or being helped back to work, whenever
  dom-main/controller/mode.lua's M.shouldAutopilot() says it's allowed to.

  Every tick, for each turtle currently in the roster:
    - stranded (real fuel level, not "unlimited", below
      STRANDED_FUEL_THRESHOLD) -> attemptRescue(): find an idle turtle
      carrying spare fuel ITEMS (lib/fuel.lua's M.spareFuelItems() --
      distinct from fuel LEVEL, see there for why), send it to stand next
      to the stranded one and hand over half its spare fuel, then have
      the stranded turtle refuel and go back to work.
    - idle (and not stranded) -> assignWork(): claim this turtle's
      dom-main/controller/worksite.lua cell (sticky -- the same turtle
      always gets the same cell back), goto its origin, and start
      mine_vertical there with the worksite's known chest wired in as
      chestPos.

  A rescued turtle currently restarts its cell from the beginning rather
  than resuming its exact mid-pass position -- mine_vertical's own
  "insufficient fuel" stop is a graceful return, which lib/job.lua
  deliberately clears the checkpoint for (same as any other graceful
  stop), so there's nothing finer-grained left to resume from without
  changing that clearing behavior. Always safe (no overlap, since it's
  the same cell either way; already-dug ground costs nothing extra to
  walk back through) -- just not maximally efficient. A reasonable
  trade-off, not an oversight.

  Every dispatch (goto + start mining, or a rescue trip) is a single
  blocking dom-main/controller/roster.lua M.proxy() call -- this only
  blocks the scheduler's own coroutine branch (see controller_main.lua's
  parallel.waitForAny), not the rest of the controller, so a slow
  dispatch never delays relay polling, rednet listening, or block
  syncing. Multiple turtles needing attention in the same tick are
  handled one at a time, in whatever order pairs() happens to visit the
  roster in -- fine for the turtle counts this is meant for.
------------------------------------------------------------------------]]

if _G.__SCHEDULER_MODULE then return _G.__SCHEDULER_MODULE end

local roster = dofile("/dom-main/controller/roster.lua")
local worksite = dofile("/dom-main/controller/worksite.lua")
local mode = dofile("/dom-main/controller/mode.lua")

local TICK_INTERVAL           = 5   -- seconds between scheduler passes
local STRANDED_FUEL_THRESHOLD = 20  -- real fuel level below this counts as stranded
local RESCUE_MIN_FUEL_ITEMS   = 4   -- a rescuer needs at least this many spare fuel items to bother sending
local DISPATCH_TIMEOUT        = 300 -- seconds -- generous: a fresh/idle turtle's origin could be far away
local RESCUE_TIMEOUT          = 120
local REFUEL_TIMEOUT          = 30

local M = {}

-- Serializes a plain Lua value (used for mine_vertical's params table)
-- into Lua source text, so a command built here can embed it directly --
-- the same job server/turtlectl.py's build_shortcut() does from the
-- Python side, just needed here too since this table is assembled
-- controller-side, not by an operator's CLI invocation.
local function luaLiteral(v)
  local t = type(v)
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

function M.isStranded(entry)
  return type(entry.fuel) == "number" and entry.fuel < STRANDED_FUEL_THRESHOLD
end

-- The best rescuer for `strandedName`: idle, not itself stranded, not in
-- `exclude` (every turtle already given an order elsewhere this same
-- tick -- see M.tick()), with the most spare fuel items (at least
-- RESCUE_MIN_FUEL_ITEMS -- not worth sending a turtle empty-handed). nil
-- if nobody qualifies.
function M.pickRescuer(snapshot, strandedName, exclude)
  local best, bestItems = nil, RESCUE_MIN_FUEL_ITEMS - 1
  for name, entry in pairs(snapshot) do
    if name ~= strandedName and not (exclude and exclude[name])
        and M.isIdle(entry) and not M.isStranded(entry) then
      local items = entry.fuelItems or 0
      if items > bestItems then
        best, bestItems = name, items
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
  local chest = worksite.chest()
  if chest then jobSpec.params.chestPos = chest end

  local command = string.format(
    'local job = dofile("/lib/job.lua"); '
      .. 'local saved = job.loadCheckpoint(); '
      .. 'if saved and saved.name == "mine_vertical" and job.hasJob("mine_vertical") then '
      .. '  local params = saved.params or {}; '
      .. '  params.__resume = saved.checkpoint; '
      .. '  job.request("mine_vertical", params); '
      .. '  return true, "resumed from checkpoint"; '
      .. 'end; '
      .. 'local pathfind = dofile("/lib/pathfind.lua"); '
      .. 'local reached, info = pathfind.goto(%d, %d, %d, { tolerance = 0, allowDig = "safe" }); '
      .. 'if reached then job.request("mine_vertical", %s) end; '
      .. 'return reached, (info and info.reason)',
    jobSpec.origin.x, jobSpec.origin.y, jobSpec.origin.z, luaLiteral(jobSpec.params)
  )

  local ok, output = roster.proxy(name, command, DISPATCH_TIMEOUT)
  if not ok then
    print("scheduler: could not get " .. name .. " to its cell: " .. tostring(output))
    return false, output
  end
  print("scheduler: " .. name .. " mining its cell (" .. tostring(output) .. ")")
  return true, output
end

-- Sends `rescuerName` (already chosen -- see M.tick()) to stand next to
-- `strandedName` and hand over half its spare fuel items, then has the
-- stranded turtle refuel and reassigns it its own (same, sticky) cell.
function M.attemptRescue(strandedName, strandedEntry, rescuerName)
  local pos = strandedEntry.position
  print("scheduler: dispatching " .. rescuerName .. " to refuel stranded turtle " .. strandedName)

  local rescueCommand = string.format(
    'local nav = dofile("/lib/nav.lua"); '
      .. 'local pathfind = dofile("/lib/pathfind.lua"); '
      .. 'local reached, info = pathfind.goto(%d, %d, %d, { tolerance = 1, allowDig = "safe" }); '
      .. 'if not reached then return false, "could not reach stranded turtle: " .. tostring(info and info.reason) end; '
      .. 'local facingStranded = false; '
      .. 'for i = 1, 4 do '
      .. '  local found, data = turtle.inspect(); '
      .. '  if found and nav.isComputerCraftBlock(data.name) then facingStranded = true break end; '
      .. '  nav.turnRight(); '
      .. 'end; '
      .. 'if not facingStranded then return false, "reached the area but no turtle is adjacent" end; '
      .. 'local dropped = 0; '
      .. 'for slot = 1, 16 do '
      .. '  turtle.select(slot); '
      .. '  local count = turtle.getItemCount(slot); '
      .. '  if count > 0 and turtle.refuel(0) then '
      .. '    local giveCount = math.floor(count / 2); '
      .. '    if giveCount > 0 and turtle.drop(giveCount) then dropped = dropped + giveCount end '
      .. '  end '
      .. 'end; '
      .. 'turtle.select(1); '
      .. 'return true, "dropped " .. dropped .. " fuel item(s)"',
    pos.x, pos.y, pos.z
  )

  local ok, output = roster.proxy(rescuerName, rescueCommand, RESCUE_TIMEOUT)
  if not ok then
    print("scheduler: rescue by " .. rescuerName .. " failed: " .. tostring(output))
    return false, output
  end
  print("scheduler: " .. rescuerName .. " reached " .. strandedName .. " -- " .. tostring(output))

  local refuelOk, refuelOutput = roster.proxy(strandedName, 'return dofile("/lib/fuel.lua").ensureFuel(1)', REFUEL_TIMEOUT)
  if not refuelOk then
    print("scheduler: " .. strandedName .. " still couldn't refuel after the rescue: " .. tostring(refuelOutput))
    return false, "refuel after rescue failed: " .. tostring(refuelOutput)
  end

  print("scheduler: " .. strandedName .. " refueled -- sending it back to its cell")
  return M.assignWork(strandedName)
end

-- One autopilot pass. Snapshots the roster's names to a plain array
-- first -- roster.proxy()'s own wait loop can add a brand-new entry
-- mid-dispatch (a turtle heartbeating for the first time while we're
-- blocked on someone else's), the same reasoning as roster.lua's own
-- proxyAll().
--
-- Rescues are resolved in their own pass, strictly before work
-- assignment, and every turtle a rescue touches (rescuer or rescued) is
-- recorded in `dispatched` immediately -- both here, before that
-- rescue's own (blocking) dispatch even starts, and checked by every
-- later pickRescuer() call and by the work-assignment pass below.
-- Iteration order over a plain Lua table (pairs()) isn't guaranteed,
-- and without this a turtle picked as a rescuer for one
-- stranded turtle could otherwise also get handed its own work order in
-- the very same tick (if it's visited later in the loop), or get picked
-- as the rescuer for a *second* stranded turtle before its first rescue
-- trip is even done -- either way, sending it two conflicting orders
-- back to back.
function M.tick()
  if not mode.shouldAutopilot() then return end

  local snapshot = roster.all()
  local names = {}
  for name in pairs(snapshot) do names[#names + 1] = name end

  local dispatched = {}
  local rescues = {} -- { {strandedName, entry, rescuerName}, ... }, resolved before any are dispatched
  for _, name in ipairs(names) do
    local entry = snapshot[name]
    if entry and M.isStranded(entry) then
      local rescuerName = M.pickRescuer(snapshot, name, dispatched)
      dispatched[name] = true
      if rescuerName then
        dispatched[rescuerName] = true
        rescues[#rescues + 1] = { name, entry, rescuerName }
      end
    end
  end
  for _, r in ipairs(rescues) do
    M.attemptRescue(r[1], r[2], r[3])
  end

  for _, name in ipairs(names) do
    local entry = snapshot[name]
    if entry and not dispatched[name] and M.isIdle(entry) then
      M.assignWork(name)
    end
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

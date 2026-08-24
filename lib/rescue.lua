--[[----------------------------------------------------------------------
  lib/rescue.lua -- turtle-side fuel rescue.

  Pauses whatever job is currently running (if any -- a rescuer no longer
  has to be idle to begin with, see dom-main/controller/scheduler.lua's
  M.pickRescuer()), travels to the worksite's known chest to fetch fuel
  -- both a generous refuel for itself and some spare items to hand
  over, since either way this trip needs the chest regardless of how
  much fuel the rescuer started with -- delivers half of whatever fuel
  it's now carrying to the stranded turtle, returns to exactly where it
  paused, and resumes its own job from there via the same checkpoint/
  resume machinery an unplanned interruption already uses.

  Dispatched by dom-main/controller/scheduler.lua's M.attemptRescue() via
  roster.proxy(). Kept as its own module, unit-testable the same way as
  everything else in lib/, rather than one long inline command string.
------------------------------------------------------------------------]]

if _G.__RESCUE_MODULE then return _G.__RESCUE_MODULE end

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")
local job = dofile("/lib/job.lua")
local fuel = dofile("/lib/fuel.lua")
local chestfinder = dofile("/lib/chestfinder.lua")

local M = {}

-- shouldStop() (what job.stop() actually sets) is only checked once per
-- completed stepDown+leg+turn cycle, not instantly -- dom-main/mining/
-- vertical.lua's digColumn() only checks it at the top of that cycle,
-- so the wait can genuinely span a full stepDown (up to `stepDown`
-- blocks) plus a full leg (up to `length` blocks, routinely 20+) of
-- real dig/move/scan time -- comfortably over a minute on a real
-- server, confirmed live (a 30s bound here let a rescue start walking
-- the turtle toward the chest while mine_vertical's own coroutine was
-- STILL running and could still move it too -- two things driving the
-- same turtle at once). This bounds how long to wait before giving up
-- -- see M.perform()'s own use of the return value: unlike the old
-- behavior, timing out here means ABORTING the rescue, never proceeding
-- with movement while the job might still be running.
local PAUSE_WAIT_TIMEOUT = 180
-- Bounds how many items to pull from the chest hunting for fuel --
-- mirrors dom-main/mining/vertical.lua's own MAX_CHESTS_PER_UNLOAD-style
-- philosophy of every retry loop in this codebase having an explicit cap.
local MAX_FUEL_GRAB_ATTEMPTS = 16

-- Requests a stop on whatever job is currently running (if any) and
-- waits (bounded) for it to actually reach idle, so the rescue trip
-- below never starts moving the turtle while mine_vertical's own
-- coroutine might still be running and moving it too. Returns paused
-- (true if it was already idle, or actually reached idle in time; false
-- if it never did -- the caller MUST abort without moving anything in
-- that case, not proceed anyway), and the job name/params to resume
-- afterward (nil, nil if it was already idle -- nothing to pause).
local function pauseCurrentJob()
  local status = job.status()
  if status.current == "idle" then return true, nil, nil end

  local name, params = status.current, status.params
  job.stop()
  local waited = 0
  while job.status().current ~= "idle" and waited < PAUSE_WAIT_TIMEOUT do
    sleep(1)
    waited = waited + 1
  end
  return job.status().current == "idle", name, params
end

-- Sucks up to maxAttempts items out of whatever's in `direction`,
-- keeping only ones that pass turtle.refuel(0)'s dry-run fuel check and
-- putting anything else straight back -- the chest this runs against is
-- also where mined-out ore gets dropped off (dom-main/controller/
-- worksite.lua's M.chest()), so nothing here should walk off with
-- someone else's ore while hunting for fuel. Returns how many fuel
-- items were kept.
local function grabFuelItems(direction, maxAttempts)
  local inspect, suck, dropFn = turtle.inspect, turtle.suck, turtle.drop
  if direction == "up" then inspect, suck, dropFn = turtle.inspectUp, turtle.suckUp, turtle.dropUp
  elseif direction == "down" then inspect, suck, dropFn = turtle.inspectDown, turtle.suckDown, turtle.dropDown end

  local found, data = inspect()
  if not (found and data.name and data.name:lower():find("chest", 1, true)) then return 0 end

  local originalSlot = turtle.getSelectedSlot()
  local kept = 0
  for _ = 1, maxAttempts do
    local before = {}
    for slot = 1, 16 do before[slot] = turtle.getItemCount(slot) end
    if not suck() then break end

    for slot = 1, 16 do
      local pulled = turtle.getItemCount(slot) - before[slot]
      if pulled > 0 then
        turtle.select(slot)
        if turtle.refuel(0) then
          kept = kept + pulled
        else
          dropFn(pulled)
        end
        break
      end
    end
  end
  turtle.select(originalSlot)
  return kept
end

-- Drops half of every fuel-type stack currently carried, to whatever's
-- immediately in front -- same dry-run-fuel-check pattern as
-- grabFuelItems above, giving instead of taking. Returns how many items
-- were dropped.
local function giveHalfFuel()
  local originalSlot = turtle.getSelectedSlot()
  local dropped = 0
  for slot = 1, 16 do
    turtle.select(slot)
    local count = turtle.getItemCount(slot)
    if count > 0 and turtle.refuel(0) then
      local giveCount = math.floor(count / 2)
      if giveCount > 0 and turtle.drop(giveCount) then
        dropped = dropped + giveCount
      end
    end
  end
  turtle.select(originalSlot)
  return dropped
end

-- Turns to face whichever of the 4 horizontal neighbors is a
-- ComputerCraft block -- the stranded turtle is assumed to be
-- immediately adjacent to the pathfind target above. Returns true once
-- facing it, false if none of the 4 sides is one.
local function faceStrandedTurtle()
  for _ = 1, 4 do
    local found, data = turtle.inspect()
    if found and nav.isComputerCraftBlock(data.name) then return true end
    nav.turnRight()
  end
  return false
end

-- Performs a full rescue. Returns true, message on success, or false,
-- reason on failure -- a failure partway through (couldn't reach the
-- chest, couldn't reach the stranded turtle) leaves any already-paused
-- job stopped rather than resumed, rather than risk resuming from the
-- wrong position.
function M.perform(strandedX, strandedY, strandedZ, chestX, chestY, chestZ)
  local pausedPos = nav.getPosition()
  local paused, resumeName, resumeParams = pauseCurrentJob()
  if not paused then
    -- Never move the turtle here -- mine_vertical's own coroutine may
    -- still be actively running and moving it too. The job's own stop
    -- request (already sent by pauseCurrentJob() above) stays pending
    -- and will still take effect on its own; this rescue attempt simply
    -- didn't get there in time and needs to be retried (the scheduler's
    -- next tick will see this turtle is still stranded and try again,
    -- hopefully against a rescuer that's actually free by then).
    return false, "job (" .. tostring(resumeName) .. ") did not pause within " .. PAUSE_WAIT_TIMEOUT
      .. "s -- aborting rather than risk moving the turtle while it might still be running"
  end

  local chest, chestErr = chestfinder.find({ x = chestX, y = chestY, z = chestZ })
  if not chest then
    return false, "could not reach the chest to fetch fuel: " .. tostring(chestErr)
  end

  -- Refuel the rescuer's OWN tank first, before grabbing anything extra
  -- to hand over -- CC:Tweaked's turtle.refuel() with no count argument
  -- consumes an ENTIRE stack from the selected slot, not "just enough";
  -- grabFuelItems() below merges everything it pulls into one stack, so
  -- calling ensureFuel() AFTER that could burn the whole donation in one
  -- shot reaching a modest target, leaving nothing left to give away
  -- (caught by this file's own test). Ensuring the rescuer's own need is
  -- met first, from whatever's already on hand or pulled fresh from the
  -- chest, means anything grabbed afterward is genuine surplus, safe to
  -- keep entirely as portable items.
  --
  -- 2x the direct chest<->stranded-turtle distance -- comfortably covers
  -- getting there and back, same convention as lib/fuel.lua's own
  -- M.safeReturnFuel() everywhere else it's used.
  local refuelTarget = fuel.safeReturnFuel(
    { x = chestX, y = chestY, z = chestZ }, { x = strandedX, y = strandedY, z = strandedZ })
  local fuelOk, fuelErr = fuel.ensureFuel(refuelTarget)
  if not fuelOk then
    return false, "couldn't reach a safe fuel level at the chest: " .. tostring(fuelErr)
  end

  grabFuelItems(chest.direction, MAX_FUEL_GRAB_ATTEMPTS)

  local reached, info = pathfind.goto(strandedX, strandedY, strandedZ, { tolerance = 1, allowDig = "safe" })
  if not reached then
    return false, "could not reach stranded turtle: " .. tostring(info and info.reason)
  end
  if not faceStrandedTurtle() then
    return false, "reached the area but no turtle is adjacent"
  end

  local dropped = giveHalfFuel()

  local backReached = pathfind.goto(pausedPos.x, pausedPos.y, pausedPos.z, { tolerance = 0, allowDig = "safe" })
  if not backReached then
    return false, "delivered " .. dropped .. " fuel item(s), but could not get back to resume its own paused job"
  end
  nav.face(pausedPos.heading)

  if resumeName then
    job.resumeOrRequest(resumeName, resumeParams)
    return true, "dropped " .. dropped .. " fuel item(s), resumed " .. resumeName
  end
  return true, "dropped " .. dropped .. " fuel item(s)"
end

_G.__RESCUE_MODULE = M
return M

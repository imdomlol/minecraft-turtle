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
local routing = dofile("/lib/routing.lua")
local job = dofile("/lib/job.lua")
local fuel = dofile("/lib/fuel.lua")
local chestfinder = dofile("/lib/chestfinder.lua")
local inventory = dofile("/lib/inventory.lua")
local homelink = dofile("/lib/homelink.lua")

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
-- Bounds how many different chests to try while hunting for a fuel stack
-- in a mixed worksite storage area. A turtle cannot ask turtle.suck()
-- for "coal"; it can only pull whatever stack the inventory exposes
-- first. If a chest's first extractable stack is stone/cobble/etc,
-- pulling and dropping it back can otherwise hit that same stack forever.
local MAX_FUEL_CHESTS = 8

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

local function suckFn(direction)
  if direction == "up" then return turtle.suckUp end
  if direction == "down" then return turtle.suckDown end
  return turtle.suck
end

local function dropFn(direction)
  if direction == "up" then return turtle.dropUp end
  if direction == "down" then return turtle.dropDown end
  return turtle.drop
end

local function firstNonEmptySlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then return slot end
  end
  return nil
end

local function topUpFromSelectedStack(minLevel)
  if fuel.hasFuel(minLevel) then return true end
  if not turtle.refuel(0) then return false end
  while not fuel.hasFuel(minLevel) and turtle.getItemCount() > 0 do
    if not turtle.refuel(1) then break end
  end
  return fuel.hasFuel(minLevel)
end

-- Finds a nearby chest whose first extractable stack is fuel. At each
-- candidate chest, dump everything first so the rescuer has room for one
-- pulled stack, pull exactly one stack, and dry-run it with refuel(0).
-- Non-fuel stacks are put back and that chest is excluded before trying
-- another chest. On success the fuel stack stays in inventory for the
-- rescue; the selected slot is left on that stack so the caller can
-- consume only as much as needed for its own tank before donating the
-- rest.
local function takeOneFuelStack(chestX, chestY, chestZ, chestBounds)
  local excluded = {}
  for _ = 1, MAX_FUEL_CHESTS do
    local chest, chestErr = chestfinder.find({
      x = chestX, y = chestY, z = chestZ,
      exclude = excluded,
      bounds = chestBounds,
    })
    if not chest then return nil, "could not find a fuel chest: " .. tostring(chestErr) end

    inventory.dropAll(chest.direction)
    if not inventory.isEmpty() then
      excluded[chestfinder.posKey(chest.x, chest.y, chest.z)] = true
    else
      local suck = suckFn(chest.direction)
      local drop = dropFn(chest.direction)
      if not suck() then
        excluded[chestfinder.posKey(chest.x, chest.y, chest.z)] = true
      else
        local slot = firstNonEmptySlot()
        if slot then
          turtle.select(slot)
          if turtle.refuel(0) then
            return chest, slot
          end
          if homelink.isItem(slot) then
            homelink.moveToReserved(slot)
          else
            drop()
          end
        end
        excluded[chestfinder.posKey(chest.x, chest.y, chest.z)] = true
      end
    end
  end
  return nil, "no fuel stack found after checking " .. MAX_FUEL_CHESTS .. " chest(s)"
end

-- Drops half of every fuel-type stack currently carried, in the given
-- direction ("front" (default), "up", or "down" -- matches
-- lib/chestfinder.lua's own found.direction shape) -- same dry-run-fuel-
-- check pattern as grabFuelItems above, giving instead of taking.
-- Returns how many items were dropped.
local function giveHalfFuel(direction)
  local drop = turtle.drop
  if direction == "up" then drop = turtle.dropUp
  elseif direction == "down" then drop = turtle.dropDown end

  local originalSlot = turtle.getSelectedSlot()
  local dropped = 0
  for slot = 1, 16 do
    turtle.select(slot)
    local count = turtle.getItemCount(slot)
    if homelink.isItem(slot) then
      homelink.moveToReserved(slot)
    elseif count > 0 and turtle.refuel(0) then
      local giveCount = math.floor(count / 2)
      if giveCount > 0 and drop(giveCount) then
        dropped = dropped + giveCount
      end
    end
  end
  turtle.select(originalSlot)
  return dropped
end

-- Finds whichever of the stranded turtle's 6 neighbors is a
-- ComputerCraft block -- pathfind.goto's tolerance=1 approach (see
-- M.perform() below) only guarantees Euclidean distance <=1, which is
-- satisfied just as easily by landing directly above/below it as beside
-- it -- lib/pathfind.lua's y-first movement preference (see its own
-- header comment) actually makes landing above/below the MORE common
-- case now, not a rare edge case, so checking only the 4 horizontal
-- sides (an earlier version of this function) missed it routinely --
-- confirmed live: a rescuer reaching the area, standing directly above
-- the stranded turtle, and reporting "no turtle is adjacent" every
-- time, no fuel ever delivered. Checks up/down first (no turning
-- needed, cheap), then the 4 horizontal sides. Returns the direction
-- ("up", "down", or "front", already facing it for "front") it was
-- found in, or nil if none of the 6 is one.
local function faceStrandedTurtle()
  local foundUp, upData = turtle.inspectUp()
  if foundUp and nav.isComputerCraftBlock(upData.name) then return "up" end
  local foundDown, downData = turtle.inspectDown()
  if foundDown and nav.isComputerCraftBlock(downData.name) then return "down" end

  for _ = 1, 4 do
    local found, data = turtle.inspect()
    if found and nav.isComputerCraftBlock(data.name) then return "front" end
    nav.turnRight()
  end
  return nil
end

-- Performs a full rescue. chestBounds (optional, see lib/chestfinder.lua's
-- opts.bounds) constrains takeOneFuelStack()'s search to a configured
-- chest range rather than the exact chestX/Y/Z point. Returns true,
-- message on success, or false, reason on failure -- a failure partway
-- through (couldn't reach the chest, couldn't reach the stranded turtle)
-- leaves any already-paused job stopped rather than resumed, rather than
-- risk resuming from the wrong position.
function M.perform(strandedX, strandedY, strandedZ, chestX, chestY, chestZ, chestBounds)
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

  local chest, chestErr = takeOneFuelStack(chestX, chestY, chestZ, chestBounds)
  if not chest then
    return false, "could not reach the chest to fetch fuel: " .. tostring(chestErr)
  end

  -- 2x the direct chest<->stranded-turtle distance -- comfortably covers
  -- getting there and back, same convention as lib/fuel.lua's own
  -- M.safeReturnFuel() everywhere else it's used.
  local refuelTarget = fuel.safeReturnFuel(
    { x = chestX, y = chestY, z = chestZ }, { x = strandedX, y = strandedY, z = strandedZ })
  if not topUpFromSelectedStack(refuelTarget) then
    return false, "found fuel, but not enough to reach a safe fuel level at the chest"
  end

  local reached, info = routing.goto(strandedX, strandedY, strandedZ, { tolerance = 1, allowDig = "safe" })
  if not reached then
    return false, "could not reach stranded turtle: " .. tostring(info and info.reason)
  end
  local strandedDirection = faceStrandedTurtle()
  if not strandedDirection then
    return false, "reached the area but no turtle is adjacent"
  end

  local dropped = giveHalfFuel(strandedDirection)

  local backReached = routing.goto(pausedPos.x, pausedPos.y, pausedPos.z, { tolerance = 0, allowDig = "safe" })
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

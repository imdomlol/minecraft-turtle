--[[----------------------------------------------------------------------
  lib/fuel.lua -- keeps a turtle from silently failing to move for lack
  of fuel, by first trying to refuel from whatever's immediately at hand
  before giving up.

  M.hasFuel(minLevel): true if fuel is at least minLevel (default 1 --
  "any fuel at all"), or the turtle needs none.

  M.ensureFuel(minLevel): if the turtle already meets minLevel, does
  nothing and returns true immediately. Otherwise:
    1. tries turtle.refuel() against every inventory slot in turn (not
       just whatever's currently selected -- see refuelAllSlots() below
       for why that distinction matters), repeating a slot until it stops
       helping, since one item's worth might not be enough to reach
       minLevel.
    2. checks all 6 directions immediately touching it right now --
       front, up, down, then (since turning costs no fuel -- even a
       turtle at 0 fuel can still spin in place) left and right too --
       and sucks from any that look like a chest, running the same
       whole-inventory refuel check after every item pulled in.
  Returns true once fuel reaches minLevel (or is unlimited), or false,
  reason if nothing nearby was enough. Always leaves the turtle facing
  the way it started -- any left/right peek turns back before returning.

  minLevel lets the same function serve two different callers: nav.lua's
  movement wrappers call it with no argument (minLevel defaults to 1 --
  they just need enough for the one move they're about to attempt), while
  dom-main/mining/vertical.lua's own minFuel check passes its actual
  minFuel target, since "has 1 fuel" isn't "has enough to keep working".

  Deliberately does NOT do a lib/chestfinder.lua-style radius search:
  that requires moving the turtle to explore, which is exactly what 0
  fuel makes impossible. A wider preventive top-up, with fuel still in
  the tank to spare for travel, is a different concern -- see
  dom-main/mining/vertical.lua's own minFuel check, which calls this
  first and can still fall back on a real chestfinder search of its own,
  since it runs before fuel actually reaches 0.

  Doesn't dofile("/lib/nav.lua") -- nav.lua calls INTO this module (to
  recover before reporting a movement failure), so depending on nav.lua
  back would be circular (nav.lua would try to load fuel.lua before
  nav.lua itself finishes initializing, which would try to load nav.lua
  again, and so on). Uses raw turtle.turnLeft/turnRight directly instead
  of nav's wrappers, always turning back to the original heading before
  returning, so nav's own tracked heading never needs to know about the
  momentary peek.
------------------------------------------------------------------------]]

if _G.__FUEL_MODULE then return _G.__FUEL_MODULE end

local M = {}

local function looksLikeChest(name)
  if not name then return false end
  return name:lower():find("chest", 1, true) ~= nil
end

function M.hasFuel(minLevel)
  minLevel = minLevel or 1
  local level = turtle.getFuelLevel()
  return level == "unlimited" or level >= minLevel
end

-- The most fuel this turtle can ever hold -- turtle.getFuelLimit()'s own
-- real value (20,000 for a plain Turtle, 100,000 for an Advanced one),
-- or "unlimited" if this world has fuel disabled entirely, never a
-- hardcoded guess at which tier a given turtle happens to be. Read at
-- call time rather than cached -- cheap, and never changes mid-run
-- anyway. M.hasFuel()/M.ensureFuel() already treat "unlimited" as
-- always-satisfied regardless of the target level, so
-- M.ensureFuel(M.maxFuel()) is always safe to call even on an
-- unlimited-fuel turtle.
function M.maxFuel()
  return turtle.getFuelLimit()
end

-- Manhattan distance between two {x,y,z} positions -- the number of
-- individual moves a direct trip between them costs, since every
-- successful forward/up/down/back move burns exactly 1 fuel regardless
-- of digging (only movement costs fuel). Pure arithmetic, no turtle.*
-- calls -- unlike everything else in this module, safe to call from a
-- controller too (dom-main/controller/scheduler.lua uses this to judge
-- a turtle's fuel against its OWN distance from the worksite's chest,
-- without needing the `turtle` API a controller doesn't have).
function M.travelCost(fromPos, toPos)
  return math.abs(toPos.x - fromPos.x) + math.abs(toPos.y - fromPos.y) + math.abs(toPos.z - fromPos.z)
end

-- The fuel level worth keeping in reserve to comfortably make it from
-- `fromPos` back to `toPos` (typically a worksite's known chest) --
-- `multiplier` (default 2) times the direct travelCost() above, as a
-- safety margin against a real path being longer than a straight
-- Manhattan line (obstacles, backtracking) and against needing fuel for
-- anything else along the way. Both dom-main/mining/vertical.lua's own
-- minFuel check and dom-main/controller/scheduler.lua's stranded/
-- self-refuel judgment call this the same way, with no multiplier
-- given -- letting the default live in exactly one place is what keeps
-- the two permanently in agreement instead of drifting apart the way a
-- turtle's own job-level minFuel and the scheduler's old flat
-- STRANDED_FUEL_THRESHOLD did (confirmed live: a turtle below its job's
-- minFuel but above that unrelated flat threshold just got redispatched
-- into the identical immediate failure, forever, with no rescue ever
-- triggered).
function M.safeReturnFuel(fromPos, toPos, multiplier)
  return (multiplier or 2) * M.travelCost(fromPos, toPos)
end

-- How many fuel-type items this turtle is carrying, distinct from its
-- current fuel LEVEL (tank contents already burned into fuel level
-- can't be un-burned and handed to another turtle -- only unspent items
-- still sitting in inventory can). turtle.refuel(0) is CC:Tweaked's
-- documented dry-run form: checks whether the selected slot's item is
-- valid fuel without actually consuming it. Used by dom-main/
-- controller/scheduler.lua (via a heartbeat field) to pick a fuel-rescue
-- donor for a stranded turtle -- a turtle with a high fuel *level* but
-- no spare *items* has nothing left to physically hand over.
function M.spareFuelItems()
  local originalSlot = turtle.getSelectedSlot()
  local total = 0
  for slot = 1, 16 do
    local count = turtle.getItemCount(slot)
    if count > 0 then
      turtle.select(slot)
      if turtle.refuel(0) then total = total + count end
    end
  end
  turtle.select(originalSlot)
  return total
end

-- turtle.refuel() only ever burns whatever's in the CURRENTLY SELECTED
-- slot -- it doesn't scan the rest of the inventory on its own. That
-- bit twice over here: the turtle's own pre-existing fuel might not
-- happen to already be in the selected slot, and turtle.suck() drops a
-- pulled item into whichever slot it lands in (the first empty or
-- already-matching one), not necessarily the selected one either -- so a
-- bare turtle.refuel() right after a successful suck() can easily be
-- checking the wrong slot and finding nothing there, even though fuel
-- really did just get pulled in. Everything below goes through this
-- instead, checking every slot rather than assuming the right one's
-- already selected. Restores the original selection before returning
-- either way, so a caller's own selected slot isn't left disturbed.
local function refuelAllSlots(minLevel)
  local originalSlot = turtle.getSelectedSlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      while turtle.refuel() do
        if M.hasFuel(minLevel) then
          turtle.select(originalSlot)
          return true
        end
      end
    end
  end
  turtle.select(originalSlot)
  return M.hasFuel(minLevel)
end

-- Sucks everything out of one adjacent direction, trying to refuel from
-- the whole inventory after each item (see refuelAllSlots() above --
-- not just the slot the item happened to land in), stopping as soon as
-- fuel reaches minLevel. Bounded by 16 (inventory slot count) so a chest
-- holding more than that doesn't get pulled from forever once the
-- inventory's already full anyway.
local function drain(inspect, suck, minLevel)
  local found, data = inspect()
  if not (found and looksLikeChest(data.name)) then return end
  for _ = 1, 16 do
    if not suck() then return end
    if refuelAllSlots(minLevel) then return end
  end
end

-- Sucks from `suck` (e.g. turtle.suck/suckUp/suckDown) and refuels from
-- whatever comes in, stopping once minLevel is reached or the source
-- stops producing anything -- the same suck+refuelAllSlots loop
-- M.ensureFuel()'s own private drain() uses against a chest it first
-- verified LOOKS like a chest by name (looksLikeChest() above), but
-- usable directly by a caller that already knows FOR CERTAIN what's in
-- that direction -- e.g. lib/homelink.lua's shared home-link Ender
-- Chest, whose real block name isn't guaranteed to contain "chest" at
-- all depending on the mod's exact registry ID (EnderStorage's is not a
-- vanilla-style name). Skips that name check entirely rather than risk
-- silently refusing to pull from a real, known-good fuel source just
-- because it doesn't happen to match a generic heuristic. Bounded the
-- same way (16 attempts, matching inventory size).
function M.refuelFrom(suck, minLevel)
  minLevel = minLevel or 1
  if M.hasFuel(minLevel) then return true end
  for _ = 1, 16 do
    if not suck() then break end
    if refuelAllSlots(minLevel) then return true end
  end
  return M.hasFuel(minLevel)
end

function M.ensureFuel(minLevel)
  minLevel = minLevel or 1
  if M.hasFuel(minLevel) then return true end

  -- One item's worth of fuel might not reach minLevel, and the fuel
  -- already in the inventory might not be in the selected slot to begin
  -- with -- refuelAllSlots checks every slot, repeating each one until
  -- it stops helping, rather than trying just the current selection once.
  if refuelAllSlots(minLevel) then return true end

  drain(turtle.inspect, turtle.suck, minLevel)
  if M.hasFuel(minLevel) then return true end

  drain(turtle.inspectUp, turtle.suckUp, minLevel)
  if M.hasFuel(minLevel) then return true end

  drain(turtle.inspectDown, turtle.suckDown, minLevel)
  if M.hasFuel(minLevel) then return true end

  turtle.turnLeft()
  drain(turtle.inspect, turtle.suck, minLevel)
  local gotFromLeft = M.hasFuel(minLevel)
  turtle.turnRight() -- back to the original heading
  if gotFromLeft then return true end

  turtle.turnRight()
  drain(turtle.inspect, turtle.suck, minLevel)
  local gotFromRight = M.hasFuel(minLevel)
  turtle.turnLeft() -- back to the original heading
  if gotFromRight then return true end

  return false, "nothing usable as fuel in inventory or touching any of the 6 adjacent sides"
end

_G.__FUEL_MODULE = M
return M

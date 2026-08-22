--[[----------------------------------------------------------------------
  lib/fuel.lua -- keeps a turtle from silently failing to move for lack
  of fuel, by first trying to refuel from whatever's immediately at hand
  before giving up.

  M.hasFuel(minLevel): true if fuel is at least minLevel (default 1 --
  "any fuel at all"), or the turtle needs none.

  M.ensureFuel(minLevel): if the turtle already meets minLevel, does
  nothing and returns true immediately. Otherwise:
    1. tries turtle.refuel() (repeatedly, since one item's worth might
       not be enough to reach minLevel) on whatever's already in its own
       inventory (free, instant, no movement needed).
    2. checks all 6 directions immediately touching it right now --
       front, up, down, then (since turning costs no fuel -- even a
       turtle at 0 fuel can still spin in place) left and right too --
       and sucks from any that look like a chest, retrying refuel()
       after every item pulled in.
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

-- Sucks everything out of one adjacent direction, trying to refuel after
-- each item, stopping as soon as fuel reaches minLevel. Bounded by 16
-- (inventory slot count) so a chest holding more than that doesn't get
-- pulled from forever once the inventory's already full anyway.
local function drain(inspect, suck, minLevel)
  local found, data = inspect()
  if not (found and looksLikeChest(data.name)) then return end
  for _ = 1, 16 do
    if not suck() then return end
    turtle.refuel()
    if M.hasFuel(minLevel) then return end
  end
end

function M.ensureFuel(minLevel)
  minLevel = minLevel or 1
  if M.hasFuel(minLevel) then return true end

  -- One item's worth of fuel might not reach minLevel -- keep burning
  -- whatever's already in the inventory until it runs out or minLevel
  -- is reached, rather than trying just once.
  while turtle.refuel() do
    if M.hasFuel(minLevel) then return true end
  end

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

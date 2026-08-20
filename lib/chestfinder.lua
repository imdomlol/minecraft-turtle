--[[----------------------------------------------------------------------
  lib/chestfinder.lua -- locates a nearby chest by physically searching
  for one, since a turtle has no long-range scanning API -- only
  turtle.inspect() of whatever's immediately touching it.

  Defaults to searching around lib/home.lua's recorded position; pass
  x/y/z to search around somewhere else instead. Non-destructive: never
  digs, and gives up (rather than plowing through obstacles) if a step is
  blocked, since a locator digging through walls to search would be a
  surprising thing for it to do on its own.
------------------------------------------------------------------------]]

if _G.__CHESTFINDER_MODULE then return _G.__CHESTFINDER_MODULE end

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")
local home = dofile("/lib/home.lua")

local M = {}

local DEFAULT_MAX_RADIUS = 8
local DELTA = {
  [0] = { x = 0,  z = -1 }, [1] = { x = 1,  z = 0 },
  [2] = { x = 0,  z = 1 },  [3] = { x = -1, z = 0 },
}

local function looksLikeChest(name, matchName)
  if not name then return false end
  if matchName then return matchName(name) end
  return name:lower():find("chest", 1, true) ~= nil
end

-- Checks the 4 horizontal neighbors (turning through all of them) plus
-- up/down of the turtle's current cell. Returns the chest's world
-- position, block name, and which turtle.drop*() variant reaches it
-- ("front", "up", or "down"), leaving the turtle facing it (or unmoved,
-- for up/down) -- or nil if nothing here matches.
local function scanHere(matchName)
  for _ = 1, 4 do
    local found, data = turtle.inspect()
    if found and looksLikeChest(data.name, matchName) then
      local pos = nav.getPosition()
      local d = DELTA[pos.heading]
      return { x = pos.x + d.x, y = pos.y, z = pos.z + d.z, name = data.name, direction = "front" }
    end
    nav.turnRight()
  end

  local foundUp, dataUp = turtle.inspectUp()
  if foundUp and looksLikeChest(dataUp.name, matchName) then
    local pos = nav.getPosition()
    return { x = pos.x, y = pos.y + 1, z = pos.z, name = dataUp.name, direction = "up" }
  end

  local foundDown, dataDown = turtle.inspectDown()
  if foundDown and looksLikeChest(dataDown.name, matchName) then
    local pos = nav.getPosition()
    return { x = pos.x, y = pos.y - 1, z = pos.z, name = dataDown.name, direction = "down" }
  end

  return nil
end

-- Classic expanding square spiral: leg lengths 1,1,2,2,3,3,... turning
-- right after each leg, covering a roughly (maxRadius*2)-wide square
-- around the starting point. Scans every cell it visits along the way.
local function spiralSearch(maxRadius, matchName)
  local found = scanHere(matchName)
  if found then return found end

  local legLength = 1
  local turnsAtThisLength = 0

  while legLength <= maxRadius * 2 do
    for _ = 1, legLength do
      local ok = nav.forward()
      if not ok then return nil, "search blocked" end
      local f = scanHere(matchName)
      if f then return f end
    end
    nav.turnRight()
    turnsAtThisLength = turnsAtThisLength + 1
    if turnsAtThisLength == 2 then
      turnsAtThisLength = 0
      legLength = legLength + 1
    end
  end

  return nil, "not found within radius " .. maxRadius
end

-- Searches for a chest-like block near (x, y, z) -- default: lib/home.lua's
-- recorded position. opts.maxRadius (default 8) bounds the search;
-- opts.matchName(name) overrides the default "name contains 'chest'"
-- check, for modded storage blocks that don't follow that convention.
-- Returns the chest's position/name on success. On failure, returns nil,
-- reason, and the turtle is returned to wherever the search started from
-- (not left stranded mid-spiral); on success, it's left facing the chest
-- (or in place, for one above/below), ready to interact with it.
function M.find(opts)
  opts = opts or {}
  local maxRadius = opts.maxRadius or DEFAULT_MAX_RADIUS
  local matchName = opts.matchName

  local target = opts
  if not (opts.x and opts.y and opts.z) then
    target = home.get()
    if not target then
      return nil, "no location given and no home position recorded (call home.mark() first)"
    end
  end

  local reached, info = pathfind.goto(target.x, target.y, target.z, { tolerance = 0, allowDig = false })
  if not reached then
    return nil, "could not reach search center: " .. tostring(info.reason)
  end

  local searchStart = nav.getPosition()
  local found, reason = spiralSearch(maxRadius, matchName)
  if found then return found end

  pathfind.goto(searchStart.x, searchStart.y, searchStart.z, { tolerance = 0, allowDig = false })
  return nil, reason
end

_G.__CHESTFINDER_MODULE = M
return M

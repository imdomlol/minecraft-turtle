--[[----------------------------------------------------------------------
  lib/chestfinder.lua -- locates a nearby chest by physically searching
  for one, since a turtle has no long-range scanning API -- only
  turtle.inspect() of whatever's immediately touching it.

  M.find(): defaults to searching around lib/home.lua's recorded
  position; pass x/y/z to search around somewhere else instead. Getting
  to that search center digs through obstacles ("safe" mode -- never a
  chest or ComputerCraft block, see lib/pathfind.lua), since it's
  typically a trip home from wherever a job just finished digging, not
  part of the search itself. The search once there stays non-destructive
  though: it gives up (rather than plowing through obstacles) if a step
  is blocked, since a locator digging through walls near a base full of
  player-built structures would be a surprising thing for it to do on
  its own.

  M.dump(): finds a chest (like M.find(), but defaulting to searching
  around the turtle's own current position instead of home) and empties
  the inventory into it in one call -- see its own comment below for how
  x/y/z and maxRadius interact.
------------------------------------------------------------------------]]

if _G.__CHESTFINDER_MODULE then return _G.__CHESTFINDER_MODULE end

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")
local home = dofile("/lib/home.lua")
local inventory = dofile("/lib/inventory.lua")

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
-- Reaching (x, y, z) in the first place digs through obstacles ("safe"
-- mode, see above); the search itself, once there, never does. Returns
-- the chest's position/name on success. On failure, returns nil,
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

  -- "safe" (dig/attack through obstacles, but never a chest or
  -- ComputerCraft block -- see lib/pathfind.lua), not false: this trip is
  -- typically home from wherever a mining job just dug to, through
  -- terrain nothing has opened up yet, not a step of the search itself --
  -- see the spiral search below, which stays deliberately non-destructive.
  local reached, info = pathfind.goto(target.x, target.y, target.z, { tolerance = 0, allowDig = "safe" })
  if not reached then
    return nil, "could not reach search center: " .. tostring(info.reason)
  end

  local searchStart = nav.getPosition()
  local found, reason = spiralSearch(maxRadius, matchName)
  if found then return found end

  pathfind.goto(searchStart.x, searchStart.y, searchStart.z, { tolerance = 0, allowDig = false })
  return nil, reason
end

-- Finds a chest and drops the whole inventory into it -- M.find() above,
-- then inventory.dropAll(). Unlike M.find() (which defaults to
-- searching around lib/home.lua's remembered position when no x/y/z is
-- given), this defaults to searching around the turtle's OWN current
-- position instead: "dump nearby" is the natural ad-hoc default here,
-- as opposed to a mining job's own unload, which wants the long-lived
-- remembered home location.
--
-- opts.x/y/z (give all three, or none) and opts.maxRadius interact:
--   no coords, no maxRadius  -> search around here,       radius 8
--   no coords, maxRadius= N  -> search around here,       radius N
--   coords given, no radius  -> search around those coords, radius 0 (exact)
--   coords given, radius = N -> search around those coords, radius N (an "error" margin)
-- i.e. maxRadius defaults to 0 when coordinates are given (they're
-- assumed to BE the chest) and to the usual 8 otherwise.
--
-- Returns { chest = <M.find()'s result>, emptied = <slots dropped> } on
-- success, or nil, reason on failure (chest not found, same as M.find()).
function M.dump(opts)
  opts = opts or {}
  local hasCoords = opts.x and opts.y and opts.z

  local x, y, z
  if hasCoords then
    x, y, z = opts.x, opts.y, opts.z
  else
    local pos = nav.getPosition()
    x, y, z = pos.x, pos.y, pos.z
  end

  local maxRadius = opts.maxRadius
  if maxRadius == nil then
    maxRadius = hasCoords and 0 or DEFAULT_MAX_RADIUS
  end

  local found, reason = M.find({ x = x, y = y, z = z, maxRadius = maxRadius, matchName = opts.matchName })
  if not found then
    return nil, reason
  end

  local emptied = inventory.dropAll(found.direction)
  return { chest = found, emptied = emptied }
end

_G.__CHESTFINDER_MODULE = M
return M

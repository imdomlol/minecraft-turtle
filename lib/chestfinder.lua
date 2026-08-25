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
local routing = dofile("/lib/routing.lua")
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

local function posKey(x, y, z)
  return x .. "," .. y .. "," .. z
end

-- bounds (optional): { minX, minY, minZ, maxX, maxY, maxZ }, from e.g.
-- dom-main/controller/worksite.lua's M.chestBounds(). nil means
-- unbounded (unchanged behavior) -- every position is "within" it.
local function withinBounds(x, y, z, bounds)
  if not bounds then return true end
  return x >= bounds.minX and x <= bounds.maxX
    and y >= bounds.minY and y <= bounds.maxY
    and z >= bounds.minZ and z <= bounds.maxZ
end

-- Checks the 4 horizontal neighbors (turning through all of them) plus
-- up/down of the turtle's current cell. Returns the chest's world
-- position, block name, and which turtle.drop*() variant reaches it
-- ("front", "up", or "down"), leaving the turtle facing it (or unmoved,
-- for up/down) -- or nil if nothing here matches.
--
-- `exclude` (optional, a set keyed by posKey(x,y,z)) skips a chest
-- whose position is in it, continuing on as if it weren't there at all
-- -- see M.find()'s own comment on why a caller needs this: without it,
-- re-searching from right next to a chest that's already been tried
-- (and is still full) would just immediately re-"find" that exact same
-- one, over and over, never reaching a genuinely different chest.
-- bounds (optional, see withinBounds() above): a candidate outside it is
-- skipped exactly like an excluded one -- the search continues as if it
-- weren't there, rather than accepting a chest outside the configured
-- range.
local function scanHere(matchName, exclude, bounds)
  for _ = 1, 4 do
    local found, data = turtle.inspect()
    if found and looksLikeChest(data.name, matchName) then
      local pos = nav.getPosition()
      local d = DELTA[pos.heading]
      local x, y, z = pos.x + d.x, pos.y, pos.z + d.z
      if not (exclude and exclude[posKey(x, y, z)]) and withinBounds(x, y, z, bounds) then
        return { x = x, y = y, z = z, name = data.name, direction = "front" }
      end
    end
    nav.turnRight()
  end

  local foundUp, dataUp = turtle.inspectUp()
  if foundUp and looksLikeChest(dataUp.name, matchName) then
    local pos = nav.getPosition()
    local x, y, z = pos.x, pos.y + 1, pos.z
    if not (exclude and exclude[posKey(x, y, z)]) and withinBounds(x, y, z, bounds) then
      return { x = x, y = y, z = z, name = dataUp.name, direction = "up" }
    end
  end

  local foundDown, dataDown = turtle.inspectDown()
  if foundDown and looksLikeChest(dataDown.name, matchName) then
    local pos = nav.getPosition()
    local x, y, z = pos.x, pos.y - 1, pos.z
    if not (exclude and exclude[posKey(x, y, z)]) and withinBounds(x, y, z, bounds) then
      return { x = x, y = y, z = z, name = dataDown.name, direction = "down" }
    end
  end

  return nil
end

-- Chests are routinely stacked vertically -- one directly above/below
-- another -- not just spread out horizontally. scanHere()'s own up/down
-- inspect can't detect that on its own: it looks directly above/below
-- the TURTLE's cell, not above/below whatever chest it's facing, and
-- the horizontal spiral below never changes height at all. Right after
-- excluding a chest (see M.find()'s own `exclude` comment), the turtle
-- is still standing adjacent to it, still facing it (scanHere()'s own
-- full 4-turn loop ends back at the heading it started with) -- so
-- before spiraling outward, check straight up and down from exactly
-- here first: moving the turtle itself up/down one level at a time,
-- level with a potential neighbor, is what lets its FRONT-facing
-- inspect (not up/down) actually find one. Restores the turtle to its
-- original height before returning on failure, so the horizontal
-- spiral (or the caller) starts from exactly where it expects to.
local VERTICAL_SEARCH_HEIGHT = 6

local function verticalSearch(matchName, exclude, maxHeight, bounds)
  local up = 0
  while up < maxHeight do
    if not nav.up() then break end
    up = up + 1
    local found = scanHere(matchName, exclude, bounds)
    if found then return found end
  end
  for _ = 1, up do nav.down() end

  local down = 0
  while down < maxHeight do
    if not nav.down() then break end
    down = down + 1
    local found = scanHere(matchName, exclude, bounds)
    if found then return found end
  end
  for _ = 1, down do nav.up() end

  return nil
end

-- If genuinely nothing's here but the direction the spiral is about to
-- start walking is blocked, turns toward an open one first (up to a
-- full turn) -- doesn't touch the spiral's own geometry at all, just
-- makes sure its first step isn't walking straight into a wall.
-- Routinely needed on a retry (see M.find()'s own `exclude` comment):
-- right after excluding a chest that's still full, the turtle is
-- usually standing right next to it, still facing it -- a real, solid
-- block, just already tried -- and without this, the very first spiral
-- step would immediately report "search blocked" and give up, even
-- with a genuinely different chest just a few blocks past it in
-- another direction. Only tried before the FIRST step, not for a
-- later, genuine dead-end deeper in the search -- that should still
-- stop rather than force a way through, same as before.
local function faceOpenDirection()
  for _ = 1, 4 do
    if not turtle.inspect() then return end
    nav.turnRight()
  end
end

-- Classic expanding square spiral: leg lengths 1,1,2,2,3,3,... turning
-- right after each leg, covering a roughly (maxRadius*2)-wide square
-- around the starting point. Scans every cell it visits along the way.
-- Tries straight up/down first (see verticalSearch above) before ever
-- moving horizontally.
local function spiralSearch(maxRadius, matchName, exclude, bounds)
  local found = scanHere(matchName, exclude, bounds)
  if found then return found end

  found = verticalSearch(matchName, exclude, VERTICAL_SEARCH_HEIGHT, bounds)
  if found then return found end

  faceOpenDirection()

  local legLength = 1
  local turnsAtThisLength = 0

  while legLength <= maxRadius * 2 do
    for _ = 1, legLength do
      local ok = nav.forward()
      if not ok then return nil, "search blocked" end
      local f = scanHere(matchName, exclude, bounds)
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

-- posKey(x, y, z) is the exact string M.find()'s own `exclude` set (see
-- below) must be keyed by -- exposed so a caller (e.g. dom-main/mining/
-- vertical.lua's own retry-the-next-chest loop) can build one.
M.posKey = posKey

-- Searches for a chest-like block near (x, y, z) -- default: lib/home.lua's
-- recorded position. opts.maxRadius (default 8) bounds the search;
-- opts.matchName(name) overrides the default "name contains 'chest'"
-- check, for modded storage blocks that don't follow that convention.
-- opts.exclude (optional, a set keyed by M.posKey(x,y,z)) skips any
-- chest whose position is in it, as if it weren't there at all -- for a
-- caller retrying after a chest it already found turned out to be full
-- (or already tried some other way): without this, re-searching from
-- right next to that same chest would just immediately re-"find" it
-- again, never reaching a genuinely different one.
-- opts.bounds (optional, { minX, minY, minZ, maxX, maxY, maxZ } -- see
-- dom-main/controller/worksite.lua's M.chestBounds()) rejects any
-- candidate chest outside it, as if it weren't there at all -- same
-- mechanism as opts.exclude, just geometric instead of by-position. When
-- given and opts.maxRadius isn't, the search radius is widened (never
-- narrowed) to reach every corner of the box from the search center, so
-- a large configured range doesn't get cut off by the usual default.
-- Reaching (x, y, z) in the first place digs through obstacles ("safe"
-- mode, see above); the search itself, once there, never does. Returns
-- the chest's position/name on success. On failure, returns nil,
-- reason, and the turtle is returned to wherever the search started from
-- (not left stranded mid-spiral); on success, it's left facing the chest
-- (or in place, for one above/below), ready to interact with it.
function M.find(opts)
  opts = opts or {}
  local matchName = opts.matchName
  local bounds = opts.bounds

  local target = opts
  if not (opts.x and opts.y and opts.z) then
    target = home.get()
    if not target then
      return nil, "no location given and no home position recorded (call home.mark() first)"
    end
  end

  local maxRadius = opts.maxRadius
  if not maxRadius and bounds then
    maxRadius = math.max(
      DEFAULT_MAX_RADIUS,
      math.abs(target.x - bounds.minX), math.abs(target.x - bounds.maxX),
      math.abs(target.z - bounds.minZ), math.abs(target.z - bounds.maxZ)
    )
  end
  maxRadius = maxRadius or DEFAULT_MAX_RADIUS

  -- If the turtle is already directly above/below target (same x/z,
  -- within verticalSearch()'s own reach on y) -- exactly where a
  -- previous scanHere()/verticalSearch() success in THIS SAME search
  -- left it -- try right here first, before ever forcing a trip back to
  -- target's own tolerance=1 adjacency below. A caller retrying after
  -- excluding a chest that turned out full (dom-main/mining/vertical.lua's
  -- unloadIfFull(), looping this whole function) routinely lands in
  -- exactly that position; unconditionally re-approaching target's
  -- adjacency every retry would walk any vertical progress right back
  -- down, only to immediately re-climb it -- confirmed live, a wasted
  -- down-then-up-again bounce every time a vertical chest stack's next
  -- candidate was also full. A genuinely fresh call (turtle elsewhere
  -- entirely) never satisfies this, so it can't accidentally match some
  -- unrelated chest far from the intended search area.
  -- Horizontal distance <=1, not ==0: verticalSearch() only ever moves
  -- via nav.up()/nav.down(), so it preserves the turtle's x/z EXACTLY as
  -- they were when it was first invoked -- which is wherever the
  -- initial tolerance=1 adjacency landed it (an orthogonal neighbor of
  -- target, per this function's own tolerance=1 comment below -- off by
  -- 1 on exactly one of x/z, not sitting exactly on target.x/target.z).
  local herePos = nav.getPosition()
  local horizontalDist = math.abs(herePos.x - target.x) + math.abs(herePos.z - target.z)
  if horizontalDist <= 1 and math.abs(herePos.y - target.y) <= VERTICAL_SEARCH_HEIGHT then
    local nearby = scanHere(matchName, opts.exclude, bounds)
      or verticalSearch(matchName, opts.exclude, VERTICAL_SEARCH_HEIGHT, bounds)
    if nearby then return nearby end
  end

  -- "safe" (dig/attack through obstacles, but never a chest or
  -- ComputerCraft block -- see lib/pathfind.lua), not false: this trip is
  -- typically home from wherever a mining job just dug to, through
  -- terrain nothing has opened up yet, not a step of the search itself --
  -- see the spiral search below, which stays deliberately non-destructive.
  --
  -- tolerance=1, not 0: a caller-given (x, y, z) is routinely the chest's
  -- OWN block position (e.g. a fleet controller's dom-main/controller/
  -- worksite.lua chest location, given as exactly where the chest sits),
  -- which is solid and, being a chest, explicitly never dug through
  -- (shouldSkipDig in lib/pathfind.lua) even in "safe" mode -- tolerance=0
  -- would demand the turtle occupy that same cell, which is permanently
  -- impossible, so it would exhaust every escape move trying anyway
  -- (confirmed live: turtles fumbling around a chest they could never
  -- reach, eventually giving up, still full, and looping the exact same
  -- failure forever on their next dispatch). tolerance=1 stops the turtle
  -- adjacent instead -- since movement here is strictly axis-aligned one
  -- step at a time, the first position within 1 block of an integer
  -- target is always an orthogonal neighbor (never a diagonal one), so
  -- scanHere()'s immediate 4-direction-plus-up/down inspect (right below)
  -- reliably finds a chest sitting exactly at the given coordinates
  -- without the spiral even needing to run. The same fix already exists
  -- for the analogous case in dom-main/controller/scheduler.lua's rescue
  -- dispatch (reaching a stranded turtle -- also a solid, occupied cell).
  local reached, info = routing.goto(target.x, target.y, target.z, { tolerance = 1, allowDig = "safe" })
  if not reached then
    return nil, "could not reach search center: " .. tostring(info.reason)
  end

  local searchStart = nav.getPosition()
  local found, reason = spiralSearch(maxRadius, matchName, opts.exclude, bounds)
  if found then return found end

  routing.goto(searchStart.x, searchStart.y, searchStart.z, { tolerance = 0, allowDig = false })
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

  local found, reason = M.find({ x = x, y = y, z = z, maxRadius = maxRadius, matchName = opts.matchName, bounds = opts.bounds })
  if not found then
    return nil, reason
  end

  local emptied = inventory.dropAll(found.direction)
  return { chest = found, emptied = emptied }
end

_G.__CHESTFINDER_MODULE = M
return M

--[[----------------------------------------------------------------------
  dom-main/controller/worksite.lua -- the fleet's mining zones (horizontal
  bounds, height/Y-band, and how each is divided into one non-overlapping
  cell per turtle), plus the shared, fleet-wide chest locations turtles
  unload/refuel at.

  Operator-managed (turtlectl.py `addzone`/`removezone`/`zones` and
  `addchest`/`removechest`/`chests`), persisted to /state/worksite.state.
  Chest locations are entirely independent of zones -- every turtle in
  every zone shares the same chest list (M.nearestChest() below), which
  is what lets a brand-new zone be added without any chest reconfiguring
  at all. Chest location is manual for now -- auto-discovering one from
  dom-main/controller/worldstore.lua's own recorded blocks is a
  deliberate future step, not built yet.

  Multiple zones exist specifically so a fleet can target more than one
  ore-bearing Y-band at once (e.g. one zone capped to the diamond band,
  another to the ancient-debris band) without one continuous top-to-
  bottom dig wasting time through the dead stone in between -- see
  M.addZone()'s own `height` parameter.

  Each zone divides into a grid of `capacity` disjoint rectangular cells
  (as close to square as the zone's own aspect ratio allows) ONCE, at
  M.addZone() time, rather than recomputing it as the roster's size
  changes later -- reshuffling an already-assigned cell's boundaries out
  from under a turtle mid-job would risk exactly the overlap this whole
  thing exists to prevent. Each cell, once handed to a turtle
  (M.assignCell()), stays that turtle's for as long as this zone exists;
  picking a `capacity` a bit above your current turtle count leaves room
  to add more turtles later without redividing anything.

  M.assignCell(name) is also where turtles get balanced ACROSS zones: a
  turtle with no assignment yet goes to whichever eligible zone (one
  with an unclaimed cell) currently has the FEWEST turtles assigned, not
  simply the first zone with room -- so the fleet spreads evenly across
  every zone that can still take one, rather than filling zones in
  order. This is a live check on every call, not a one-time split at
  startup: nothing here assumes today's fleet size is fixed. The fleet
  can't dynamically grow yet (no code creates a new turtle and adds it
  to the roster on its own), but when that day comes, a fresh turtle's
  first M.assignCell() call lands wherever's currently least loaded,
  with no separate rebalancing step ever needed -- the same logic that
  balances the existing fleet today already handles it for free.

  M.jobFor(cell) turns one cell into ready-to-launch mine_vertical params
  (widthFacing always "south", lengthFacing always "east" -- a fixed,
  uniform orientation; correctness here only depends on every turtle's
  legs staying inside its own cell, which a fixed orientation already
  guarantees just as well as a fancier alternating layout would, without
  the added complexity).
------------------------------------------------------------------------]]

if _G.__WORKSITE_MODULE then return _G.__WORKSITE_MODULE end

local STATE_PATH = "/state/worksite.state"

-- Blocks between width positions -- see dom-main/mining/vertical.lua's
-- own tuning notes on columnDY/stepDown interleaving; this just needs to
-- be "reasonably dense", not perfectly tuned.
local COLUMN_STEP = 3
-- Kept clear at a cell's far edge so floating-point cell-boundary
-- rounding can never push a leg one block into the next cell over.
local LENGTH_MARGIN = 1
-- A cell narrower than this in either dimension isn't a sensible
-- independent mining lane anyway, and M.jobFor()'s minimum-1 clamp on
-- length/width (a job needs to dig *something*) can no longer guarantee
-- staying inside a cell this small -- see M.addZone()'s own validation
-- against this, which is the real fix; M.jobFor()'s clamp below is
-- defense in depth for a cell that somehow gets through anyway (a
-- hand-edited state file, say), not the primary guard.
local MIN_CELL_SIZE = 4

local M = {}

local state -- { zones = { {minX,maxX,minZ,maxZ,y,height,capacity,cells,assignments}, ... }, chests = {...} }

local function save()
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(state))
  f.close()
end

-- Unlike a single-site design, `state` is always a usable table once
-- this returns -- zones/chests are independent concerns, and chest
-- management shouldn't need a zone to exist first (or vice versa).
local function loadState()
  if state ~= nil then return end
  if fs.exists(STATE_PATH) then
    local f = fs.open(STATE_PATH, "r")
    local text = f.readAll()
    f.close()
    local ok, decoded = pcall(textutils.unserializeJSON, text)
    if ok and type(decoded) == "table" then state = decoded end
  end
  if not state then state = {} end
  state.zones = state.zones or {}
  state.chests = state.chests or {}
end

-- Splits a minX/maxX/minZ/maxZ rectangle into `capacity` disjoint cells
-- arranged in a grid whose column/row counts approximate the
-- rectangle's own aspect ratio, so cells end up roughly square rather
-- than absurdly thin strips at high turtle counts.
local function buildCells(minX, maxX, minZ, maxZ, capacity)
  local width, depth = maxX - minX, maxZ - minZ
  local cols = math.floor(math.sqrt(capacity * width / depth) + 0.5)
  cols = math.max(1, math.min(cols, capacity))
  local rows = math.ceil(capacity / cols)

  local cellW = width / cols
  local cellD = depth / rows

  local cells = {}
  for i = 0, capacity - 1 do
    local col = i % cols
    local row = math.floor(i / cols)
    local cellMinX = minX + col * cellW
    local cellMinZ = minZ + row * cellD
    cells[#cells + 1] = {
      minX = cellMinX, maxX = math.min(cellMinX + cellW, maxX),
      minZ = cellMinZ, maxZ = math.min(cellMinZ + cellD, maxZ),
    }
  end
  return cells
end

local function worksiteIdFor(cell, originX, originZ, length, width)
  return table.concat({
    tostring(cell.minX),
    tostring(cell.maxX),
    tostring(cell.minZ),
    tostring(cell.maxZ),
    tostring(cell.y),
    tostring(cell.height or ""),
    tostring(originX),
    tostring(originZ),
    tostring(length),
    tostring(width),
    tostring(COLUMN_STEP),
  }, ":")
end

-- minX/minZ/maxX/maxZ: the zone's horizontal bounds (either corner
-- order works). y: height to start mining passes from. capacity: how
-- many cells to divide the zone into. height (optional): caps how many
-- blocks a pass descends before stopping on its own (nil = dig to
-- bedrock, the default) -- this is what lets a zone target a specific
-- Y-band (e.g. y=174, height=81 covers exactly the diamond band down to
-- y=93) instead of one continuous dig through everything in between.
--
-- Refuses (returns nil, reason -- doesn't add anything) a capacity that
-- would produce any cell narrower than MIN_CELL_SIZE in either
-- dimension: M.jobFor()'s minimum-1 length/width clamp (a job has to
-- dig *something*) can push a job's reach a full block past a cell that
-- small, into the neighbor's territory or past the zone's own outer
-- edge -- confirmed by testing (capacity=3000 over a 79x79 area put
-- more than half the cells' jobs outside their own bounds; some
-- capacities put *every* cell outside). Checking every cell rather than
-- just the nominal cellW/cellD, since the last row/column can come out
-- smaller than the rest (see buildCells()'s own maxX/maxZ clamp).
function M.addZone(minX, minZ, maxX, maxZ, y, capacity, height)
  local loX, hiX = math.min(minX, maxX), math.max(minX, maxX)
  local loZ, hiZ = math.min(minZ, maxZ), math.max(minZ, maxZ)

  local cells = buildCells(loX, hiX, loZ, hiZ, capacity)
  for _, cell in ipairs(cells) do
    local w, d = cell.maxX - cell.minX, cell.maxZ - cell.minZ
    if w < MIN_CELL_SIZE or d < MIN_CELL_SIZE then
      return nil, ("capacity %d is too high for a %gx%g area -- cells would be as small as %.1fx%.1f blocks "
        .. "(minimum %d); try a lower capacity"):format(capacity, hiX - loX, hiZ - loZ, w, d, MIN_CELL_SIZE)
    end
  end

  -- Embedded directly on each cell (not just the zone) so M.jobFor(cell)
  -- stays self-contained -- it never needs to look up which zone a cell
  -- came from.
  for _, cell in ipairs(cells) do
    cell.y = y
    cell.height = height
  end

  loadState()
  local zone = {
    minX = loX, maxX = hiX, minZ = loZ, maxZ = hiZ, y = y, height = height,
    capacity = capacity,
    cells = cells,
    assignments = {}, -- turtle name -> cell index (0-based)
  }
  state.zones[#state.zones + 1] = zone
  save()
  return zone
end

-- Removes the zone at `index` (1-based, matching M.listZones()'s own
-- ordering). Refuses (returns false, reason) while any turtle is still
-- assigned there -- release them first (M.releaseCell()) rather than
-- silently orphaning a turtle's sticky cell out from under it.
function M.removeZone(index)
  loadState()
  local zone = state.zones[index]
  if not zone then return false, "no zone at index " .. tostring(index) end
  if next(zone.assignments) ~= nil then
    return false, "zone " .. index .. " still has turtles assigned -- release them first"
  end
  table.remove(state.zones, index)
  save()
  return true
end

-- Every configured zone, in the order M.assignCell()'s sticky lookup and
-- M.removeZone()'s indexing both use.
function M.listZones()
  loadState()
  return state.zones
end

-- Adds one chest location: either an exact point (maxX/Y/Z all nil), or
-- a box (any/all of maxX/Y/Z given -- an axis with no max collapses to a
-- single coordinate on that axis, so e.g. only maxY need be given to
-- allow a chest anywhere in a vertical range at a fixed x/z) that a
-- chest may be found anywhere within. Multiple chests can be added --
-- e.g. one at (0,0,0) and a separate, unrelated one at (10,10,10) -- each
-- tracked independently; M.nearestChest() below picks whichever is
-- closest to a given position. Shared fleet-wide, independent of zones
-- entirely -- no zone needs to exist first.
function M.addChest(x, y, z, maxX, maxY, maxZ)
  loadState()

  local bounds = nil
  local point = { x = x, y = y, z = z }
  if maxX or maxY or maxZ then
    bounds = {
      minX = math.min(x, maxX or x), maxX = math.max(x, maxX or x),
      minY = math.min(y, maxY or y), maxY = math.max(y, maxY or y),
      minZ = math.min(z, maxZ or z), maxZ = math.max(z, maxZ or z),
    }
    -- The representative point used for distance/goto math is the box's
    -- center -- a sensible search starting point when the exact chest
    -- position within the box isn't known yet, rounded to the nearest
    -- integer since a turtle can only stand on one.
    point = {
      x = math.floor((bounds.minX + bounds.maxX) / 2 + 0.5),
      y = math.floor((bounds.minY + bounds.maxY) / 2 + 0.5),
      z = math.floor((bounds.minZ + bounds.maxZ) / 2 + 0.5),
    }
  end

  local entry = { x = point.x, y = point.y, z = point.z, bounds = bounds }
  state.chests[#state.chests + 1] = entry
  save()
  return entry
end

-- Removes the chest at `index` (1-based, matching M.listChests()'s own
-- ordering). Returns true, or false, reason if the index doesn't exist.
function M.removeChest(index)
  loadState()
  if not state.chests[index] then return false, "no chest at index " .. tostring(index) end
  table.remove(state.chests, index)
  save()
  return true
end

-- Every configured chest -- an array of { x, y, z, bounds }, bounds nil
-- for an exact point (see M.addChest() above).
function M.listChests()
  loadState()
  return state.chests
end

-- Whichever configured chest's representative point (see M.addChest())
-- is closest to `pos`, by the same Manhattan-distance metric
-- lib/fuel.lua's M.travelCost() uses everywhere else a turtle's fuel is
-- judged against a trip -- so picking "nearest" here and judging whether
-- a turtle can reach it stay in agreement. nil if no chest has been
-- added yet.
function M.nearestChest(pos)
  loadState()
  if #state.chests == 0 then return nil end

  local best, bestDist = nil, nil
  for _, entry in ipairs(state.chests) do
    local dist = math.abs(pos.x - entry.x) + math.abs(pos.y - entry.y) + math.abs(pos.z - entry.z)
    if not best or dist < bestDist then
      best, bestDist = entry, dist
    end
  end
  return best
end

-- The cell already assigned to `name` (in whichever zone that turned
-- out to be -- checked across every zone, since a turtle's assignment
-- is sticky for as long as ITS zone exists, regardless of what else has
-- been added since), or a freshly claimed one in whichever eligible
-- zone (one with an unclaimed cell) currently has the FEWEST assigned
-- turtles -- see this file's own header comment for why this balances
-- across zones instead of filling them in order. Returns nil, reason if
-- there are no zones configured at all, or every zone is already at its
-- own capacity.
function M.assignCell(name)
  loadState()
  if #state.zones == 0 then return nil, "no zones configured" end

  for _, zone in ipairs(state.zones) do
    local existingIndex = zone.assignments[name]
    if existingIndex then
      return zone.cells[existingIndex + 1]
    end
  end

  local best, bestCount = nil, nil
  for _, zone in ipairs(state.zones) do
    local count = 0
    for _ in pairs(zone.assignments) do count = count + 1 end
    if count < zone.capacity and (not best or count < bestCount) then
      best, bestCount = zone, count
    end
  end
  if not best then return nil, "every zone is at capacity" end

  local taken = {}
  for _, idx in pairs(best.assignments) do taken[idx] = true end
  for i = 0, best.capacity - 1 do
    if not taken[i] then
      best.assignments[name] = i
      save()
      return best.cells[i + 1]
    end
  end
  return nil, "zone selection inconsistency" -- unreachable: best was chosen for having room
end

-- Releases `name`'s sticky cell, wherever it is -- searches every zone
-- since the caller doesn't (and shouldn't need to) know which one a
-- turtle landed in.
function M.releaseCell(name)
  loadState()
  for _, zone in ipairs(state.zones) do
    if zone.assignments[name] ~= nil then
      zone.assignments[name] = nil
      save()
      return
    end
  end
end

-- Turns a cell into { origin = {x,y,z}, params = {...} } -- origin is
-- where to goto before starting the job; params is ready to hand
-- straight to dofile("/lib/job.lua").request("mine_vertical", params)
-- (the caller still needs to merge in its own chestPos -- see
-- M.nearestChest() -- since that's shared across every cell, not
-- per-cell). Self-contained: y/height come from the cell itself (set by
-- M.addZone() when the cell was created), not a lookup back to whatever
-- zone it came from.
function M.jobFor(cell)
  -- Cell boundaries are floats (a zone split into `capacity` pieces
  -- rarely divides evenly), but a turtle only ever stands on integer
  -- coordinates -- rounding the origin *inward* (ceil, never west/north
  -- of the true boundary) and the far edge *inward* (floor, never
  -- east/south of it) keeps every integer coordinate this job actually
  -- touches strictly inside the cell, regardless of which way the float
  -- boundary happened to split. Rounding the origin the other way
  -- (floor) is exactly the bug this fixes: it can land one block *west*
  -- of the cell, inside the previous one.
  local originX = math.ceil(cell.minX)
  local originZ = math.ceil(cell.minZ)
  local innerMaxX = math.floor(cell.maxX)
  local innerMaxZ = math.floor(cell.maxZ)

  -- Clamped to a minimum of 0, not 1: M.addZone() already refuses any
  -- cell small enough for this to matter in practice (see
  -- MIN_CELL_SIZE), so this is a defense-in-depth floor, not the
  -- primary guard -- and 0 is the *safe* floor. dom-main/mining/
  -- vertical.lua's digColumn() handles length=0 (an immediate "blocked"
  -- leg, no horizontal movement at all) and width=0 (one pass at the
  -- origin, then the width cap stops it) both without ever stepping
  -- outside the cell; clamping to 1 instead, like this used to, is
  -- exactly what could push a too-small cell's job a full block past
  -- its own edge.
  local length = math.max(0, (innerMaxX - originX) - LENGTH_MARGIN)
  local width = math.max(0, math.floor((innerMaxZ - originZ) / COLUMN_STEP))
  local params = {
    widthFacing = "south",
    lengthFacing = "east",
    length = length,
    columnStep = COLUMN_STEP,
    width = width,
    __worksiteId = worksiteIdFor(cell, originX, originZ, length, width),
    __worksiteOrigin = { x = originX, y = cell.y, z = originZ },
  }
  if cell.height then params.height = cell.height end
  return {
    origin = { x = originX, y = cell.y, z = originZ },
    params = params,
  }
end

_G.__WORKSITE_MODULE = M
return M

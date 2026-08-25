--[[----------------------------------------------------------------------
  dom-main/controller/worksite.lua -- the current mining site's horizontal
  bounds and known chest location, and how it's divided into one
  non-overlapping cell per turtle.

  Operator-set (turtlectl.py `worksite`), persisted to
  /state/worksite.state. Chest location is manual for now -- auto-
  discovering one from dom-main/controller/worldstore.lua's own recorded
  blocks is a deliberate future step, not built yet.

  Divides the site into a grid of `capacity` disjoint rectangular cells
  (as close to square as the site's own aspect ratio allows) ONCE, at
  M.set() time, rather than recomputing it as the roster's size changes
  later -- reshuffling an already-assigned cell's boundaries out from
  under a turtle mid-job would risk exactly the overlap this whole thing
  exists to prevent. Each cell, once handed to a turtle (M.assignCell()),
  stays that turtle's for as long as this worksite is configured; picking
  a `capacity` a bit above your current turtle count leaves room to add
  more turtles later without redividing anything.

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
-- staying inside a cell this small -- see M.set()'s own validation
-- against this, which is the real fix; M.jobFor()'s clamp below is
-- defense in depth for a cell that somehow gets through anyway (a
-- hand-edited state file, say), not the primary guard.
local MIN_CELL_SIZE = 4

local M = {}

local site -- { minX, maxX, minZ, maxZ, y, chest, capacity, cells, assignments }

local function save()
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(site))
  f.close()
end

local function loadState()
  if site ~= nil then return end
  if not fs.exists(STATE_PATH) then return end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" then site = decoded end
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

-- minX/minZ/maxX/maxZ: the site's horizontal bounds (either corner
-- order works). y: height to start mining passes from. capacity: how
-- many cells to divide the site into. Chest locations are managed
-- separately -- see M.addChest()/M.removeChest()/M.listChests()/
-- M.nearestChest() below -- and, once set, survive a later M.set() call
-- that only touches bounds/y/capacity (e.g. widening the site or
-- changing turtle count shouldn't force re-entering every chest).
--
-- Refuses (returns nil, reason -- doesn't change the current worksite)
-- a capacity that would produce any cell narrower than MIN_CELL_SIZE in
-- either dimension: M.jobFor()'s minimum-1 length/width clamp (a job has
-- to dig *something*) can push a job's reach a full block past a cell
-- that small, into the neighbor's territory or past the site's own
-- outer edge -- confirmed by testing (capacity=3000 over a 79x79 area
-- put more than half the cells' jobs outside their own bounds; some
-- capacities put *every* cell outside). Checking every cell rather than
-- just the nominal cellW/cellD, since the last row/column can come out
-- smaller than the rest (see buildCells()'s own maxX/maxZ clamp).
function M.set(minX, minZ, maxX, maxZ, y, capacity)
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

  loadState()
  site = {
    minX = loX, maxX = hiX, minZ = loZ, maxZ = hiZ, y = y,
    chests = site and site.chests or {}, -- carried forward, see comment above
    capacity = capacity,
    cells = cells,
    assignments = {}, -- turtle name -> cell index (0-based)
  }
  save()
  return site
end

function M.get()
  loadState()
  return site
end

-- Adds one chest location: either an exact point (maxX/Y/Z all nil), or
-- a box (any/all of maxX/Y/Z given -- an axis with no max collapses to a
-- single coordinate on that axis, so e.g. only maxY need be given to
-- allow a chest anywhere in a vertical range at a fixed x/z) that a
-- chest may be found anywhere within. Multiple chests can be added --
-- e.g. one at (0,0,0) and a separate, unrelated one at (10,10,10) -- each
-- tracked independently; M.nearestChest() below picks whichever is
-- closest to a given position. Returns the added entry, or nil, reason
-- if no worksite is configured yet (M.set() must run first -- there's
-- nowhere to attach a chest to otherwise).
function M.addChest(x, y, z, maxX, maxY, maxZ)
  loadState()
  if not site then return nil, "no worksite configured -- run worksite set first" end

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
  site.chests[#site.chests + 1] = entry
  save()
  return entry
end

-- Removes the chest at `index` (1-based, matching M.listChests()'s own
-- ordering). Returns true, or false, reason if the index doesn't exist.
function M.removeChest(index)
  loadState()
  if not site then return false, "no worksite configured" end
  if not site.chests[index] then return false, "no chest at index " .. tostring(index) end
  table.remove(site.chests, index)
  save()
  return true
end

-- Every configured chest -- an array of { x, y, z, bounds }, bounds nil
-- for an exact point (see M.addChest() above). Empty (not nil) if a
-- worksite is configured but no chest has been added yet; nil if no
-- worksite is configured at all.
function M.listChests()
  loadState()
  return site and site.chests or nil
end

-- Whichever configured chest's representative point (see M.addChest())
-- is closest to `pos`, by the same Manhattan-distance metric
-- lib/fuel.lua's M.travelCost() uses everywhere else a turtle's fuel is
-- judged against a trip -- so picking "nearest" here and judging whether
-- a turtle can reach it stay in agreement. nil if no worksite is
-- configured, or none has any chest added yet.
function M.nearestChest(pos)
  loadState()
  if not site or #site.chests == 0 then return nil end

  local best, bestDist = nil, nil
  for _, entry in ipairs(site.chests) do
    local dist = math.abs(pos.x - entry.x) + math.abs(pos.y - entry.y) + math.abs(pos.z - entry.z)
    if not best or dist < bestDist then
      best, bestDist = entry, dist
    end
  end
  return best
end

-- The cell already assigned to `name`, or the next unclaimed one
-- (claimed and persisted on the spot). Returns nil, reason if there's no
-- worksite configured at all, or every cell is already taken.
function M.assignCell(name)
  loadState()
  if not site then return nil, "no worksite configured" end

  local existingIndex = site.assignments[name]
  if existingIndex then
    return site.cells[existingIndex + 1]
  end

  local taken = {}
  for _, idx in pairs(site.assignments) do taken[idx] = true end
  for i = 0, site.capacity - 1 do
    if not taken[i] then
      site.assignments[name] = i
      save()
      return site.cells[i + 1]
    end
  end
  return nil, "every cell already claimed"
end

function M.releaseCell(name)
  loadState()
  if site and site.assignments[name] ~= nil then
    site.assignments[name] = nil
    save()
  end
end

-- Turns a cell into { origin = {x,y,z}, params = {...} } -- origin is
-- where to goto before starting the job; params is ready to hand
-- straight to dofile("/lib/job.lua").request("mine_vertical", params)
-- (the caller still needs to merge in its own chestPos -- see
-- M.chest() -- since that's shared across every cell, not per-cell).
function M.jobFor(cell)
  loadState()
  -- Cell boundaries are floats (an area split into `capacity` pieces
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

  -- Clamped to a minimum of 0, not 1: M.set() already refuses any cell
  -- small enough for this to matter in practice (see MIN_CELL_SIZE), so
  -- this is a defense-in-depth floor, not the primary guard -- and 0 is
  -- the *safe* floor. dom-main/mining/vertical.lua's digColumn() handles
  -- length=0 (an immediate "blocked" leg, no horizontal movement at all)
  -- and width=0 (one pass at the origin, then the width cap stops it)
  -- both without ever stepping outside the cell; clamping to 1 instead,
  -- like this used to, is exactly what could push a too-small cell's job
  -- a full block past its own edge.
  local length = math.max(0, (innerMaxX - originX) - LENGTH_MARGIN)
  local width = math.max(0, math.floor((innerMaxZ - originZ) / COLUMN_STEP))
  return {
    origin = { x = originX, y = site.y, z = originZ },
    params = {
      widthFacing = "south",
      lengthFacing = "east",
      length = length,
      columnStep = COLUMN_STEP,
      width = width,
    },
  }
end

_G.__WORKSITE_MODULE = M
return M

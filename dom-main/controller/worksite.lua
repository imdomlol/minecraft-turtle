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
-- order works). y: height to start mining passes from. chestX/Y/Z:
-- where a full turtle should go to unload. capacity: how many cells to
-- divide the site into.
function M.set(minX, minZ, maxX, maxZ, y, chestX, chestY, chestZ, capacity)
  local loX, hiX = math.min(minX, maxX), math.max(minX, maxX)
  local loZ, hiZ = math.min(minZ, maxZ), math.max(minZ, maxZ)
  site = {
    minX = loX, maxX = hiX, minZ = loZ, maxZ = hiZ, y = y,
    chest = { x = chestX, y = chestY, z = chestZ },
    capacity = capacity,
    cells = buildCells(loX, hiX, loZ, hiZ, capacity),
    assignments = {}, -- turtle name -> cell index (0-based)
  }
  save()
  return site
end

function M.get()
  loadState()
  return site
end

function M.chest()
  loadState()
  return site and site.chest or nil
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

  local length = math.max(1, (innerMaxX - originX) - LENGTH_MARGIN)
  local width = math.max(1, math.floor((innerMaxZ - originZ) / COLUMN_STEP))
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

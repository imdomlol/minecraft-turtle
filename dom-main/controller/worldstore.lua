--[[----------------------------------------------------------------------
  dom-main/controller/worldstore.lua -- the controller's source of truth
  for "what block is at (x, y, z)", fed by dom-main/controller/
  block_sync.lua pulling batches from every turtle's lib/worldmap.lua.

  Chunked the way Minecraft itself is (16x16x16 regions): each observed
  cell lives in a small per-chunk table, persisted to its own file under
  /state/world/, so recording one more block only ever costs writing the
  one chunk it landed in -- never a single ever-growing whole-world file
  the way lib/nav.lua's rewrite-the-whole-file-every-save pattern would
  if applied here directly. Chunks are loaded from disk lazily, on first
  query/record, and cached in memory afterward.

  Block names are paletted: a small global name<->integer table, since
  the vast majority of observed cells repeat a handful of names
  ("minecraft:stone", "minecraft:deepslate", ...) and storing the
  integer instead of the string in every single chunk cell is what
  actually keeps this scalable at fleet-wide volume.

  Nothing here is written to disk automatically -- M.record()/
  M.recordBatch() only mark things dirty in memory; M.flush() (called
  periodically by block_sync.lua, not after every single batch) is what
  actually persists dirty chunks and the palette, if either changed.
------------------------------------------------------------------------]]

if _G.__WORLDSTORE_MODULE then return _G.__WORLDSTORE_MODULE end

local WORLD_DIR     = "/state/world"
local PALETTE_PATH  = WORLD_DIR .. "/palette.state"
local CHUNK_SIZE    = 16

local M = {}

local paletteByName = {}   -- block name -> small integer id
local paletteById   = {}   -- small integer id -> block name
local paletteLoaded = false
local paletteDirty  = false
local nextPaletteId = 1

local chunks = {}          -- "cx_cy_cz" -> { cells = {["dx,dy,dz"] = id}, dirty = bool }

local function ensureDir()
  if not fs.exists(WORLD_DIR) then fs.makeDir(WORLD_DIR) end
end

local function loadPalette()
  if not fs.exists(PALETTE_PATH) then return end
  local f = fs.open(PALETTE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if not ok or type(decoded) ~= "table" then return end
  -- JSON object keys are always strings, even though these started out
  -- as integer ids -- convert back on the way in.
  for idText, name in pairs(decoded) do
    local id = tonumber(idText)
    if id then
      paletteById[id] = name
      paletteByName[name] = id
      if id >= nextPaletteId then nextPaletteId = id + 1 end
    end
  end
end

local function ensurePaletteLoaded()
  if paletteLoaded then return end
  paletteLoaded = true
  loadPalette()
end

local function paletteIdFor(name)
  ensurePaletteLoaded()
  local id = paletteByName[name]
  if id then return id end
  id = nextPaletteId
  nextPaletteId = nextPaletteId + 1
  paletteByName[name] = id
  paletteById[id] = name
  paletteDirty = true
  return id
end

local function paletteNameFor(id)
  ensurePaletteLoaded()
  return paletteById[id]
end

-- Lua's math.floor rounds toward negative infinity, which is exactly
-- what chunk bucketing needs for negative world coordinates to match
-- Minecraft's own chunk indexing (e.g. x=-1 belongs to chunk -1, not 0).
local function chunkCoord(v)
  return math.floor(v / CHUNK_SIZE)
end

local function chunkKey(cx, cy, cz)
  return cx .. "_" .. cy .. "_" .. cz
end

local function localKey(x, y, z, cx, cy, cz)
  return (x - cx * CHUNK_SIZE) .. "," .. (y - cy * CHUNK_SIZE) .. "," .. (z - cz * CHUNK_SIZE)
end

-- Returns the chunk table for (cx, cy, cz), loading it from disk on
-- first access if it exists, or creating a fresh empty one if `create`
-- is true and it doesn't. Returns nil if it doesn't exist and `create`
-- is false (a query against never-observed territory).
local function getChunk(cx, cy, cz, create)
  local key = chunkKey(cx, cy, cz)
  local chunk = chunks[key]
  if chunk then return chunk end

  local path = WORLD_DIR .. "/" .. key .. ".chunk"
  if fs.exists(path) then
    local f = fs.open(path, "r")
    local text = f.readAll()
    f.close()
    local ok, decoded = pcall(textutils.unserializeJSON, text)
    if ok and type(decoded) == "table" then
      chunk = { cells = decoded, dirty = false }
      chunks[key] = chunk
      return chunk
    end
  end

  if not create then return nil end
  chunk = { cells = {}, dirty = false }
  chunks[key] = chunk
  return chunk
end

function M.record(x, y, z, name)
  local id = paletteIdFor(name)
  local cx, cy, cz = chunkCoord(x), chunkCoord(y), chunkCoord(z)
  local chunk = getChunk(cx, cy, cz, true)
  chunk.cells[localKey(x, y, z, cx, cy, cz)] = id
  chunk.dirty = true
end

-- entries is the { "x,y,z" -> blockName } shape lib/worldmap.lua's
-- M.drain() (and so dom-main/controller/roster.lua's M.pullBlocks())
-- hands back.
function M.recordBatch(entries)
  if not entries then return end
  for key, name in pairs(entries) do
    local xs, ys, zs = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    if xs then
      M.record(tonumber(xs), tonumber(ys), tonumber(zs), name)
    end
  end
end

-- Raw block names (not palette ids -- there's no shared-across-requests
-- disk budget to justify the compression on this side channel) waiting
-- to be shipped to the relay's /blocks endpoint by lib/remote.lua's
-- stream loop, for an operator's external map viewer/database to follow
-- live instead of only via a one-shot turtlectl.py worldexport. Merged
-- by key rather than queued as a list of batches: two updates to the
-- same coordinate before the next successful push only need to ship the
-- latest one.
local pendingStream = {}
local MAX_PENDING_STREAM = 50000 -- distinct coordinates; see M.queueForStream

function M.queueForStream(entries)
  if not entries then return end
  local count = M.pendingStreamCount()
  for key, name in pairs(entries) do
    if pendingStream[key] ~= nil then
      pendingStream[key] = name
    elseif count < MAX_PENDING_STREAM then
      pendingStream[key] = name
      count = count + 1
    end
    -- else: the relay's been unreachable long enough to fill the cap --
    -- drop the update rather than grow unbounded. Nothing lost from the
    -- source of truth (M.record() above already has it); a viewer that
    -- was watching live just needs a fresh worldexport once reconnected.
  end
end

function M.pendingStreamCount()
  local n = 0
  for _ in pairs(pendingStream) do n = n + 1 end
  return n
end

-- A snapshot of every currently-pending entry, to POST to the relay. A
-- copy, not the live table -- M.queueForStream() can run again (another
-- coroutine, e.g. dom-main/controller/block_sync.lua's pull loop) while
-- an http.post() built from this snapshot is in flight, and
-- M.dropSentStream() needs to compare against what was actually sent,
-- not whatever pendingStream has mutated into by the time it returns.
function M.pendingStream()
  local snapshot = {}
  for key, name in pairs(pendingStream) do
    snapshot[key] = name
  end
  return snapshot
end

-- Clears exactly the entries in `sent` (as returned by a prior
-- M.pendingStream() call) that still hold the same value -- mirrors
-- lib/exec.lua's dropSentLog() prefix-compare, so an entry that changed
-- again while the post was in flight is correctly left pending instead
-- of being silently dropped.
function M.dropSentStream(sent)
  for key, name in pairs(sent) do
    if pendingStream[key] == name then
      pendingStream[key] = nil
    end
  end
end

-- The block at (x, y, z), or nil if it's never been observed by any
-- turtle whose batch has reached this controller.
function M.query(x, y, z)
  local cx, cy, cz = chunkCoord(x), chunkCoord(y), chunkCoord(z)
  local chunk = getChunk(cx, cy, cz, false)
  if not chunk then return nil end
  local id = chunk.cells[localKey(x, y, z, cx, cy, cz)]
  if not id then return nil end
  return paletteNameFor(id)
end

-- Persists every dirty chunk (and the palette, if it changed) to disk.
-- Meant to be called periodically by dom-main/controller/block_sync.lua,
-- not after every single M.record()/M.recordBatch() -- that would be
-- the exact whole-file-per-write cost this module exists to avoid,
-- just spread across many small files instead of one big one.
function M.flush()
  ensureDir()

  if paletteDirty then
    local f = fs.open(PALETTE_PATH, "w")
    f.write(textutils.serializeJSON(paletteById))
    f.close()
    paletteDirty = false
  end

  for key, chunk in pairs(chunks) do
    if chunk.dirty then
      local f = fs.open(WORLD_DIR .. "/" .. key .. ".chunk", "w")
      f.write(textutils.serializeJSON(chunk.cells))
      f.close()
      chunk.dirty = false
    end
  end
end

-- The whole known world, as one JSON string: { chunkSize = 16, palette =
-- {id -> name}, chunks = {"cx_cy_cz" -> {"dx,dy,dz" -> id}} } -- for an
-- operator pulling the map out to an external viewer (turtlectl.py
-- worldexport), not used by anything on the controller itself. Reads
-- every chunk that's either already cached in memory (possibly still
-- dirty/unflushed) or sitting on disk from an earlier session, in that
-- preference order, so a chunk created this session but not yet
-- M.flush()'d is still included.
function M.exportAll()
  ensurePaletteLoaded()

  local exported = {}
  for key, chunk in pairs(chunks) do
    exported[key] = chunk.cells
  end
  if fs.exists(WORLD_DIR) then
    for _, file in ipairs(fs.list(WORLD_DIR)) do
      local key = file:match("^(.+)%.chunk$")
      if key and exported[key] == nil then
        local cx, cy, cz = key:match("^(-?%d+)_(-?%d+)_(-?%d+)$")
        if cx then
          local chunk = getChunk(tonumber(cx), tonumber(cy), tonumber(cz), false)
          if chunk then exported[key] = chunk.cells end
        end
      end
    end
  end

  return textutils.serializeJSON({ chunkSize = CHUNK_SIZE, palette = paletteById, chunks = exported })
end

_G.__WORLDSTORE_MODULE = M
return M

--[[----------------------------------------------------------------------
  lib/worldmap.lua -- buffers every block this turtle ever inspects, so
  the fleet controller (dom-main/controller/worldstore.lua) can pull a
  batch and become the source of truth for "what block is at (x, y, z)"
  across the whole dimension.

  M.install() monkey-patches the three global turtle.inspect*()
  functions, rather than this needing to be threaded through every call
  site that inspects a block -- lib/pathfind.lua's stepForward,
  dom-main/mining/vertical.lua's digForward/digDown/digUp and vein
  scanning, lib/chestfinder.lua's scanHere, and lib/nav.lua's own
  inspectFront/Up/Down all call turtle.inspect()/inspectUp()/inspectDown()
  directly. Wrapping the three global functions once, here, means every
  one of those keeps working completely unchanged and starts feeding the
  world map automatically -- the same "wrap once, everything downstream
  benefits" shape lib/exec.lua's wrapTerm()/term.redirect() already uses
  for console log capture.

  Buffered as a dictionary keyed by "x,y,z", not a list: re-inspecting
  the same cell (turning to peek the same wall twice, say) overwrites in
  place instead of queuing a duplicate, so the buffer's size reflects
  unique cells touched, not inspect() calls made. Bounded (like
  lib/exec.lua's MAX_PENDING_LOG) with oldest-first eviction if the
  controller genuinely never gets around to pulling from this turtle --
  fresh information about wherever it's digging right now is worth more
  than stale information about somewhere it was an hour ago, which has
  often changed again by now anyway (dug further, or by another turtle).

  Sends raw block names, not palette ids -- only the controller knows the
  fleet-wide palette (assigned dynamically as new names are ever seen
  across every turtle), so translating here would mean syncing that
  palette back out to every turtle for no real benefit.
------------------------------------------------------------------------]]

if _G.__WORLDMAP_MODULE then return _G.__WORLDMAP_MODULE end

local nav = dofile("/lib/nav.lua")

local MAX_PENDING_BLOCKS = 4000

local M = {}

local pending = {}   -- "x,y,z" -> block name
local order = {}      -- keys currently in `pending`, oldest first
local installed = false

-- Mirrors lib/nav.lua's own (private) heading->delta table -- duplicated
-- rather than exported, the same way lib/chestfinder.lua already
-- duplicates this exact table locally instead of reaching into nav.lua
-- for it.
local DELTA = {
  [0] = { x = 0,  z = -1 }, [1] = { x = 1,  z = 0 },
  [2] = { x = 0,  z = 1 },  [3] = { x = -1, z = 0 },
}

local function record(x, y, z, name)
  local key = x .. "," .. y .. "," .. z
  if pending[key] == nil then
    order[#order + 1] = key
    if #order > MAX_PENDING_BLOCKS then
      local dropped = table.remove(order, 1)
      pending[dropped] = nil
    end
  end
  pending[key] = name
end

-- Idempotent (guarded both by the _G cache above and this flag, since a
-- fresh dofile() of an already-installed module still returns the same
-- cached M, but M.install() itself could in principle be called more
-- than once against it) -- calling it twice must never wrap the wrapper.
function M.install()
  if installed then return end
  installed = true

  local realInspect = turtle.inspect
  local realInspectUp = turtle.inspectUp
  local realInspectDown = turtle.inspectDown

  turtle.inspect = function()
    local found, data = realInspect()
    if found then
      local pos = nav.getPosition()
      local d = DELTA[pos.heading]
      record(pos.x + d.x, pos.y, pos.z + d.z, data.name)
    end
    return found, data
  end

  turtle.inspectUp = function()
    local found, data = realInspectUp()
    if found then
      local pos = nav.getPosition()
      record(pos.x, pos.y + 1, pos.z, data.name)
    end
    return found, data
  end

  turtle.inspectDown = function()
    local found, data = realInspectDown()
    if found then
      local pos = nav.getPosition()
      record(pos.x, pos.y - 1, pos.z, data.name)
    end
    return found, data
  end
end

-- Returns up to maxEntries pending observations (oldest first) and
-- removes exactly those from the buffer -- like lib/exec.lua's
-- dropSentLog(), more can accumulate between this being called and the
-- reply actually reaching the controller, so only what's handed back
-- here is cleared. Defaults to draining everything.
function M.drain(maxEntries)
  local n = math.min(maxEntries or #order, #order)
  local entries = {}
  for _ = 1, n do
    local key = table.remove(order, 1)
    entries[key] = pending[key]
    pending[key] = nil
  end
  return entries
end

-- How much is currently buffered -- not currently reported to the
-- controller (staleness is tracked there purely by time since last
-- pull, see dom-main/controller/roster.lua's M.leastRecentlyPulled()),
-- just exposed for tests and possible future use.
function M.pendingCount()
  return #order
end

_G.__WORLDMAP_MODULE = M
return M

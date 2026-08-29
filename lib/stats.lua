--[[----------------------------------------------------------------------
  lib/stats.lua -- in-memory-only counters for THIS turtle's current
  boot session: total resources actually deposited (by item name), and
  how many times it's tried each deposit path -- ender-chest placements,
  community/surface-chest visits, and a combined "started a deposit
  cycle at all" count.

  Deliberately never persisted to /state and deliberately reset to zero
  on every boot -- these are meant to answer "what has this turtle done
  since it last started up", not a lifetime total. Counted at the point
  of actual DEPOSIT (a measured before/after inventory delta -- see
  dom-main/mining/vertical.lua's own snapshotCargoByName()/
  recordDroppedDelta()), not at the point of digging: something still
  sitting uncollected in inventory isn't meaningfully "collected" yet in
  a reportable sense, and every mined item is guaranteed to pass through
  a deposit exactly once regardless of which of the many dig code paths
  originally picked it up.

  Cached on _G like every other lib/*.lua singleton sharing state across
  dofile() calls within one boot.
------------------------------------------------------------------------]]

if _G.__STATS_MODULE then return _G.__STATS_MODULE end

local M = {}

local resources = {}       -- item name -> total count ever deposited this session
local enderChestPlacements = 0
local communityChestVisits = 0
local depositCycles = 0

-- items: array of { name, count } -- see dom-main/mining/vertical.lua's
-- recordDroppedDelta() for how this gets computed.
function M.recordResources(items)
  for _, item in ipairs(items) do
    resources[item.name] = (resources[item.name] or 0) + item.count
  end
end

-- Once per dom-main/mining/vertical.lua's unloadIfFull() actually
-- starting a deposit attempt (inventory confirmed full, tidy enabled) --
-- regardless of which path(s) it goes on to try.
function M.recordDepositCycle()
  depositCycles = depositCycles + 1
end

-- Once per successful lib/homelink.lua M.place() call.
function M.recordEnderChestPlacement()
  enderChestPlacements = enderChestPlacements + 1
end

-- Once per community/surface chest actually used in a chestfinder
-- fallback cycle (dom-main/mining/vertical.lua's own chestsUsed count).
function M.recordCommunityChestVisit()
  communityChestVisits = communityChestVisits + 1
end

-- This session's full counters, for lib/fleet.lua's "get_stats"/"stats"
-- message pair (dom-main/controller/roster.lua's M.pullStats()) and the
-- turtlectl.py `stats`/`fleetstats` shortcuts.
function M.report()
  return {
    resources = resources,
    enderChestPlacements = enderChestPlacements,
    communityChestVisits = communityChestVisits,
    depositCycles = depositCycles,
  }
end

_G.__STATS_MODULE = M
return M

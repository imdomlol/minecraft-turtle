--[[----------------------------------------------------------------------
  dom-main/controller/block_sync.lua -- pulls buffered block observations
  from up to PULL_BATCH_SIZE turtles at once, concurrently, and feeds
  them into dom-main/controller/worldstore.lua.

  Every tick, picks whichever turtles have gone longest since their last
  pull (roster.lua's M.leastRecentlyPulledBatch()) -- naturally
  round-robins the whole roster over time, prioritizing whoever's most
  likely to have accumulated the most unreported data, without turtles
  needing to report their own buffer size at all. Used to pull from
  exactly one turtle per tick; confirmed too slow to keep any one
  turtle's data reasonably fresh once the roster reaches into the
  hundreds (at PULL_INTERVAL=2s, one-at-a-time would take 2 x fleet size
  seconds to cycle through everyone once -- a 300-turtle fleet would go
  10 minutes between pulls from any given turtle). Pulling a batch
  concurrently via parallel.waitForAll keeps that cycle time bounded by
  PULL_BATCH_SIZE instead of total fleet size.
------------------------------------------------------------------------]]

local roster = dofile("/dom-main/controller/roster.lua")
local worldstore = dofile("/dom-main/controller/worldstore.lua")

-- table.unpack (Lua 5.2+/CC:Tweaked) vs the global unpack (Lua 5.1).
local unpack = table.unpack or unpack

local PULL_INTERVAL        = 2   -- seconds between pull batches
local PULL_BATCH_SIZE      = 8   -- turtles pulled concurrently per batch
local MAX_ENTRIES_PER_PULL = 200 -- caps one rednet reply's size; leftovers stay pending for next time
local PULL_TIMEOUT         = 10  -- seconds to wait for one turtle's reply
local FLUSH_INTERVAL       = 10  -- seconds between worldstore.flush() calls

local M = {}

local function pullOne(name)
  local entries = roster.pullBlocks(name, MAX_ENTRIES_PER_PULL, PULL_TIMEOUT)
  if entries then
    worldstore.recordBatch(entries)
    worldstore.queueForStream(entries)
  end
  -- Marked as pulled whether or not it succeeded -- a persistently
  -- unreachable turtle (out of range, or just idle and quiet) would
  -- otherwise permanently look like "longest since last pull" and
  -- monopolize every future batch, starving every other turtle's data
  -- out of ever being collected.
  roster.markBlockPull(name, os.epoch("utc"))
end

function M.run()
  local lastFlush = os.clock()

  while true do
    sleep(PULL_INTERVAL)

    local names = roster.leastRecentlyPulledBatch(PULL_BATCH_SIZE)
    if #names > 0 then
      local batchTasks = {}
      for i, name in ipairs(names) do
        batchTasks[i] = function() pullOne(name) end
      end
      parallel.waitForAll(unpack(batchTasks))
    end

    if os.clock() - lastFlush >= FLUSH_INTERVAL then
      worldstore.flush()
      lastFlush = os.clock()
    end
  end
end

return M

--[[----------------------------------------------------------------------
  dom-main/controller/block_sync.lua -- pulls buffered block observations
  from turtles, one at a time, and feeds them into
  dom-main/controller/worldstore.lua.

  Every tick, picks whichever turtle has gone longest since its last
  pull (roster.lua's M.leastRecentlyPulled()) -- naturally round-robins
  the whole roster over time, prioritizing whoever's most likely to have
  accumulated the most unreported data, without turtles needing to
  report their own buffer size at all. One turtle at a time keeps this
  simple and self-throttling by construction: rednet never has more than
  one pull_blocks request in flight, whatever the roster size. Worth
  revisiting (e.g. pulling from a handful of turtles at once via
  parallel.waitForAll) once real in-game timing shows whether a 50-turtle
  roster cycles fast enough this way.
------------------------------------------------------------------------]]

local roster = dofile("/dom-main/controller/roster.lua")
local worldstore = dofile("/dom-main/controller/worldstore.lua")

local PULL_INTERVAL        = 2   -- seconds between pulls
local MAX_ENTRIES_PER_PULL = 200 -- caps one rednet reply's size; leftovers stay pending for next time
local PULL_TIMEOUT         = 10  -- seconds to wait for one turtle's reply
local FLUSH_INTERVAL       = 10  -- seconds between worldstore.flush() calls

local M = {}

function M.run()
  local lastFlush = os.clock()

  while true do
    sleep(PULL_INTERVAL)

    local name = roster.leastRecentlyPulled()
    if name then
      local entries = roster.pullBlocks(name, MAX_ENTRIES_PER_PULL, PULL_TIMEOUT)
      if entries then
        worldstore.recordBatch(entries)
        worldstore.queueForStream(entries)
      end
      -- Marked as pulled whether or not it succeeded -- a persistently
      -- unreachable turtle (out of range, or just idle and quiet) would
      -- otherwise permanently look like "longest since last pull" and
      -- monopolize every future tick, starving every other turtle's
      -- data out of ever being collected.
      roster.markBlockPull(name, os.epoch("utc"))
    end

    if os.clock() - lastFlush >= FLUSH_INTERVAL then
      worldstore.flush()
      lastFlush = os.clock()
    end
  end
end

return M

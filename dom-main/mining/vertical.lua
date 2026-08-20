--[[----------------------------------------------------------------------
  dom-main/mining/vertical.lua -- vertical switchback strip miner.

  Digs straight down in a zigzag staircase rather than a horizontal
  shaft, leaning on the fact that a turtle is 1 block wide/tall and can
  fly: descend `descend` blocks, dig forward `legLength` blocks, turn
  180, repeat -- since a descend always happens right before a leg and
  legs alternate direction every time, this traces a switchback pattern
  (leg N and leg N+2 sit on the same horizontal footprint, one level
  apart), covering a `legLength`*2-wide vertical slice as it goes.

  When a column bottoms out (can't dig down any further -- bedrock, the
  normal end of a column) or a leg is blocked immediately (a side wall,
  not the bottom), it retraces its own dig log back up to that column's
  top, shifts to a new column (x -= columnDX every time; z +=
  columnDZ, alternating sign each time), and starts again -- forever,
  until told to stop.

  Meant to run as a lib/job.lua job (see main.lua), not called directly:
  a run long enough to be worth calling "forever" would otherwise block
  the remote console from ever reaching it again. Start/stop it with:
    dofile("/lib/job.lua").request("mine_vertical", { legLength = 10 })
    dofile("/lib/job.lua").stop()
  shouldStop() (passed in by lib/job.lua) is only checked once per column
  iteration (between full down+forward+turn cycles), not between
  individual blocks -- so expect up to roughly a `descend + legLength`
  block actions' worth of latency before a stop actually takes effect.

  The return trip up a column deliberately does NOT use pathfind.goto():
  a column is a narrow, arbitrarily-shaped zigzag through solid rock, and
  pathfind's greedy distance-based stepper has no way to rediscover that
  exact shape -- it would just get stuck trying to shortcut through rock
  that was never dug. Instead, digColumn() records exactly what it did
  (down/forward step counts, in order) and returnToColumnStart() replays
  that log in reverse. Travel *between* columns, over already-surveyed
  ground, does use pathfind.goto() -- that's a much safer place to trust
  its greedy search (and, deliberately, allows it to dig through anything
  minor in the way, so a stray surface block can't stall an unattended
  run -- set allowDig=false in this file if you'd rather it stop and wait).
------------------------------------------------------------------------]]

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")
local home = dofile("/lib/home.lua")

local M = {}

local DEFAULTS = {
  legLength = 10,  -- blocks dug per forward/backward leg
  descend   = 2,   -- blocks descended before each leg
  minFuel   = 500, -- abort before starting a new column if fuel can't be brought above this
  columnDX  = -1,  -- x shift applied to each new column, relative to the previous one
  columnDZ  = 1,   -- magnitude of z shift each new column; sign alternates every column
}

-- Bounds dig retries -- see dom-main/mining/strip.lua for why this can't
-- be unbounded (CraftOS's "too long without yielding" watchdog).
local MAX_DIG_ATTEMPTS = 8

local function digForward()
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detect() then return nav.forward() end
    if not turtle.dig() then turtle.attack() end
  end
  return false, "obstructed after " .. MAX_DIG_ATTEMPTS .. " dig attempts"
end

local function digDown()
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detectDown() then return nav.down() end
    if not turtle.digDown() then turtle.attackDown() end
  end
  return false, "obstructed after " .. MAX_DIG_ATTEMPTS .. " dig attempts"
end

-- The turtle is 1 block wide -- unlike strip.lua's 2-tall shaft, a leg
-- only needs to clear the single cell it's moving into.
local function tunnelForward(n)
  for i = 1, n do
    if not digForward() then return i - 1 end
  end
  return n
end

local function tunnelDown(n)
  for i = 1, n do
    if not digDown() then return i - 1 end
  end
  return n
end

-- Digs one switchback column. Returns legs (a list of { down = n } / {
-- forward = n } entries, in the exact order things happened) and
-- interrupted (true if shouldStop() cut it short rather than hitting
-- bedrock or a blocked leg).
local function digColumn(legLength, descend, shouldStop)
  local legs = {}

  while true do
    if shouldStop and shouldStop() then
      return legs, true
    end

    local dSteps = tunnelDown(descend)
    legs[#legs + 1] = { down = dSteps }
    if dSteps < descend then return legs, false end -- bedrock / world bottom

    local fSteps = tunnelForward(legLength)
    legs[#legs + 1] = { forward = fSteps }
    if fSteps == 0 then return legs, false end -- side wall, not the bottom -- still stop here

    nav.turnRight(); nav.turnRight()
  end
end

-- Replays `legs` in reverse: nav.up() for every down entry, and for every
-- *nonzero* forward entry, turn 180 then nav.back() -- retracing the
-- corridor without re-digging it, since it's already clear. Skipping the
-- turn for a zero-length forward entry (the "blocked leg" case) matters:
-- the real dig loop above only turns 180 after a *successful* leg, so a
-- zero-length one never turned either, and mirroring that keeps every
-- later (chronologically earlier) leg's retrace facing the right way.
local function returnToColumnStart(legs)
  for i = #legs, 1, -1 do
    local leg = legs[i]
    if leg.down then
      for _ = 1, leg.down do nav.up() end
    elseif leg.forward and leg.forward > 0 then
      nav.turnRight(); nav.turnRight()
      for _ = 1, leg.forward do nav.back() end
    end
  end
end

-- Job entry point (see lib/job.lua): params is { legLength, descend,
-- minFuel, columnDX, columnDZ }, all optional (see DEFAULTS). Marks home
-- (lib/home.lua) if nothing's marked yet, so the very first column's top
-- is remembered even across a mid-run reboot -- each subsequent column's
-- own top is just tracked locally, since home.lua only remembers one
-- position and every column needs its own.
function M.run(params, shouldStop)
  params = params or {}
  local legLength = params.legLength or DEFAULTS.legLength
  local descend   = params.descend or DEFAULTS.descend
  local minFuel   = params.minFuel or DEFAULTS.minFuel
  local columnDX  = params.columnDX or DEFAULTS.columnDX
  local columnDZ  = params.columnDZ or DEFAULTS.columnDZ

  if not home.get() then home.mark() end

  local columnStart = nav.getPosition()
  local dzSign = 1
  local columnIndex = 0

  while not (shouldStop and shouldStop()) do
    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and fuel < minFuel then
      turtle.refuel()
      fuel = turtle.getFuelLevel()
      if fuel ~= "unlimited" and fuel < minFuel then
        print(("vertical: stopping -- fuel %s below minimum %d"):format(tostring(fuel), minFuel))
        return false, "insufficient fuel"
      end
    end

    columnIndex = columnIndex + 1
    print(("vertical: column %d starting at (%d, %d, %d)")
      :format(columnIndex, columnStart.x, columnStart.y, columnStart.z))

    local legs, interrupted = digColumn(legLength, descend, shouldStop)
    print(("vertical: column %d done -- %d legs, retracing to column start"):format(columnIndex, #legs))
    returnToColumnStart(legs)

    if interrupted then
      print("vertical: interrupted, stopped at column " .. columnIndex .. "'s start")
      return true, { columns = columnIndex, position = nav.getPosition() }
    end

    dzSign = -dzSign
    local nextX = columnStart.x + columnDX
    local nextZ = columnStart.z + (columnDZ * dzSign)
    print(("vertical: moving to column %d at (%d, %d, %d)"):format(columnIndex + 1, nextX, columnStart.y, nextZ))

    local reached, info = pathfind.goto(nextX, columnStart.y, nextZ, { tolerance = 0, allowDig = true })
    if not reached then
      print("vertical: could not reach next column -- " .. tostring(info.reason))
      return false, "could not reach next column: " .. tostring(info.reason)
    end

    columnStart = nav.getPosition()
  end

  print("vertical: interrupted before starting a new column")
  return true, { columns = columnIndex, position = nav.getPosition() }
end

return M

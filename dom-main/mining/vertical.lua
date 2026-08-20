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
  not the bottom), it gets back under the column's own start (x, z) --
  digging through anything in the way -- and digs straight up to that
  start's y, rather than retracing the zigzag turn by turn: most of that
  vertical column is already opened up by the zigzag's own legs crossing
  through it, a straight climb is far simpler, and for a deep column it's
  faster too. It then shifts to a new column -- z += columnDZ every time;
  the column's *starting height* (y) shifts by columnDY, alternating sign
  each time, while x stays fixed -- and starts again, forever, until told
  to stop. The marching axis (z) is deliberately perpendicular to the leg
  axis (x, the direction digColumn's own forward/back legs run): marching
  along x too would just walk new columns down the same line the legs
  already dug, instead of spreading coverage into a fresh plane.
  Staggering each column's start height rather than starting every column
  at the same y means adjacent columns' horizontal legs also land at
  different depths instead of perfectly overlapping.

  Meant to run as a lib/job.lua job (see main.lua), not called directly:
  a run long enough to be worth calling "forever" would otherwise block
  the remote console from ever reaching it again. Start/stop it with:
    dofile("/lib/job.lua").request("mine_vertical", { legLength = 10 })
    dofile("/lib/job.lua").stop()
  shouldStop() (passed in by lib/job.lua) is only checked once per column
  iteration (between full down+forward+turn cycles), not between
  individual blocks -- so expect up to roughly a `descend + legLength`
  block actions' worth of latency before a stop actually takes effect.
------------------------------------------------------------------------]]

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")
local home = dofile("/lib/home.lua")

local M = {}

local DEFAULTS = {
  legLength = 10,  -- blocks dug per forward/backward leg
  descend   = 3,   -- blocks descended before each leg
  minFuel   = 500, -- abort before starting a new column if fuel can't be brought above this
  columnDZ  = 1,   -- z shift applied to each new column, relative to the previous one
  columnDY  = 1,   -- magnitude of the start-height shift each new column; sign alternates every column
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

local function digUp()
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detectUp() then return nav.up() end
    if not turtle.digUp() then turtle.attackUp() end
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

local function tunnelUp(n)
  for i = 1, n do
    if not digUp() then return i - 1 end
  end
  return n
end

-- Digs one switchback column. Returns legCount (how many forward legs
-- were attempted) and reason: "bedrock" (can't dig down any further --
-- the normal end of a column), "blocked" (a leg was obstructed
-- immediately -- a side wall, not the bottom), or "interrupted"
-- (shouldStop() cut it short).
local function digColumn(legLength, descend, shouldStop)
  local legCount = 0

  while true do
    if shouldStop and shouldStop() then
      return legCount, "interrupted"
    end

    local dSteps = tunnelDown(descend)
    if dSteps < descend then return legCount, "bedrock" end

    local fSteps = tunnelForward(legLength)
    legCount = legCount + 1
    if fSteps == 0 then return legCount, "blocked" end

    nav.turnRight(); nav.turnRight()
  end
end

-- Gets back under columnStart's (x, z) at the current depth -- digging
-- through anything in the way, since most of it is already opened up by
-- the column's own legs -- then digs straight up to columnStart's y.
local function returnToColumnStart(columnStart)
  local pos = nav.getPosition()
  local reached, info = pathfind.goto(columnStart.x, pos.y, columnStart.z, { tolerance = 0, allowDig = true })
  if not reached then
    return false, "could not get under column start: " .. tostring(info.reason)
  end

  local needed = columnStart.y - nav.getPosition().y
  local climbed = tunnelUp(needed)
  if climbed < needed then
    return false, "stuck climbing back to column start"
  end
  return true
end

-- Job entry point (see lib/job.lua): params is { legLength, descend,
-- minFuel, columnDX, columnDY }, all optional (see DEFAULTS). Marks home
-- (lib/home.lua) if nothing's marked yet, so the very first column's top
-- is remembered even across a mid-run reboot -- each subsequent column's
-- own top is just tracked locally, since home.lua only remembers one
-- position and every column needs its own.
function M.run(params, shouldStop)
  params = params or {}
  local legLength = params.legLength or DEFAULTS.legLength
  local descend   = params.descend or DEFAULTS.descend
  local minFuel   = params.minFuel or DEFAULTS.minFuel
  local columnDZ  = params.columnDZ or DEFAULTS.columnDZ
  local columnDY  = params.columnDY or DEFAULTS.columnDY

  if not home.get() then home.mark() end

  local columnStart = nav.getPosition()
  local dySign = 1
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

    local legCount, reason = digColumn(legLength, descend, shouldStop)
    print(("vertical: column %d done -- %d legs (%s), climbing back to column start")
      :format(columnIndex, legCount, reason))

    local backOk, backErr = returnToColumnStart(columnStart)
    if not backOk then
      print("vertical: could not return to column start -- " .. tostring(backErr))
      return false, "could not return to column start: " .. tostring(backErr)
    end

    if reason == "interrupted" then
      print("vertical: interrupted, stopped at column " .. columnIndex .. "'s start")
      return true, { columns = columnIndex, position = nav.getPosition() }
    end

    dySign = -dySign
    local nextZ = columnStart.z + columnDZ
    local nextY = columnStart.y + (columnDY * dySign)
    print(("vertical: moving to column %d at (%d, %d, %d)"):format(columnIndex + 1, columnStart.x, nextY, nextZ))

    local reached, info = pathfind.goto(columnStart.x, nextY, nextZ, { tolerance = 0, allowDig = true })
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

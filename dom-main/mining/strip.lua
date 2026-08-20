--[[----------------------------------------------------------------------
  dom-main/mining/strip.lua -- branch-mine strip miner.

  Digs a 2-tall main shaft forward; at regular intervals along it, digs a
  branch out to each side before continuing. Doesn't chase ore veins --
  it just clears everything inside the tunnels it digs, same as any
  classic strip miner. Vein-following would need a per-modpack list of
  ore block names this script has no way to know, so that's left as a
  future enhancement rather than guessed at here.

  Deployed as /strip.lua on the turtle (see manifest.txt):
    dofile("/strip.lua").run({ length = 32 })

  Builds on lib/nav.lua (position tracking) and lib/pathfind.lua (getting
  back to the start). As with those, route any new movement through
  nav.* rather than calling turtle.forward()/etc directly, or the
  tracked position -- and this script's ability to find its way home --
  drifts out of sync.
------------------------------------------------------------------------]]

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")

local M = {}

local DEFAULTS = {
  length         = 32,  -- how far the main shaft goes
  branchInterval = 2,   -- blocks between branches along the main shaft
  branchLength   = 5,   -- how far each side branch extends
  minFuel        = 200, -- abort before starting if fuel can't be brought above this
  returnHome     = true, -- pathfind back to the start position when done
}

-- Bounds dig retries: enough to clear falling gravel/sand refilling the
-- space, but a genuinely undiggable block (bedrock, a claim, wrong tool
-- equipped) still gives up instead of spinning forever -- unbounded retry
-- here would eventually hit CraftOS's "too long without yielding" watchdog
-- and take the whole turtle down mid-run.
local MAX_DIG_ATTEMPTS = 8
local function digForward()
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detect() then return nav.forward() end
    if not turtle.dig() then turtle.attack() end
  end
  if not turtle.detect() then return nav.forward() end
  return false, "obstructed after " .. MAX_DIG_ATTEMPTS .. " dig attempts"
end

local function digUpDown()
  if turtle.detectUp() then turtle.digUp() end
  if turtle.detectDown() then turtle.digDown() end
end

-- Advances up to `n` blocks, clearing a 2-tall tunnel (feet + head) as it
-- goes. Returns ok, stepsCompleted, err -- stepsCompleted lets callers
-- that stop early (out of fuel, etc.) still know exactly how far they got.
local function tunnel(n)
  for i = 1, n do
    digUpDown()
    local ok, err = digForward()
    if not ok then
      digUpDown() -- still clear the cell we're stuck in
      return false, i - 1, err
    end
  end
  digUpDown()
  return true, n
end

-- Digs a branch out to one side and walks back along it. `turnOut` is
-- nav.turnLeft or nav.turnRight; the return trip retraces the now-clear
-- branch with nav.back() instead of turning around, since there's
-- nothing left to dig on the way back.
local function digBranch(length, turnOut)
  local turnBack = (turnOut == nav.turnLeft) and nav.turnRight or nav.turnLeft

  turnOut()
  local ok, steps, err = tunnel(length)
  if not ok then
    print("strip: branch stopped early -- " .. tostring(err))
  end
  for _ = 1, steps do nav.back() end
  turnBack()
end

-- Runs a full strip-mine pass. opts:
--   length          main shaft length (default 32)
--   branchInterval  blocks between side branches (default 2)
--   branchLength    how far each branch extends (default 5)
--   minFuel         abort if fuel can't be brought above this (default 200)
--   returnHome      pathfind back to the start when done (default true)
-- Returns ok, info where info = { traveled, position }.
function M.run(opts)
  opts = opts or {}
  local length         = opts.length or DEFAULTS.length
  local branchInterval = opts.branchInterval or DEFAULTS.branchInterval
  local branchLength   = opts.branchLength or DEFAULTS.branchLength
  local minFuel        = opts.minFuel or DEFAULTS.minFuel
  local returnHome = opts.returnHome
  if returnHome == nil then returnHome = DEFAULTS.returnHome end

  local fuel = turtle.getFuelLevel()
  if fuel ~= "unlimited" and fuel < minFuel then
    turtle.refuel()
    fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and fuel < minFuel then
      print(("strip: aborting -- fuel %s below minimum %d, and refuel() didn't help")
        :format(tostring(fuel), minFuel))
      return false, "insufficient fuel"
    end
  end

  local start = nav.getPosition()
  print(("strip: starting -- length=%d branchInterval=%d branchLength=%d")
    :format(length, branchInterval, branchLength))

  local traveled = 0
  while traveled < length do
    local ok, steps, err = tunnel(1)
    traveled = traveled + steps
    if not ok then
      print("strip: main shaft stopped early -- " .. tostring(err))
      break
    end

    if traveled % branchInterval == 0 then
      print(("strip: branching at %d/%d"):format(traveled, length))
      digBranch(branchLength, nav.turnLeft)
      digBranch(branchLength, nav.turnRight)
    end
  end

  print(("strip: mined %d/%d blocks of main shaft"):format(traveled, length))

  if returnHome then
    print("strip: returning to start")
    pathfind.goto(start.x, start.y, start.z, { tolerance = 0, allowDig = false })
  end

  return true, { traveled = traveled, position = nav.getPosition() }
end

return M

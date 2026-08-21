--[[----------------------------------------------------------------------
  lib/pathfind.lua -- moves the turtle toward a target (x, y, z).

  There's no map to plan a real route against -- a turtle only ever sees
  the block immediately in front/above/below it (lib/nav.lua's inspect
  functions). So this is a greedy stepper, not A*: every step it picks
  whichever axis (x, z, or y) has the largest remaining distance and
  tries to move that way, falling back to the other axes if that move
  fails. Optionally digs/attacks through whatever's blocking it. Bounded
  by a step cap (a multiple of the starting distance) so a genuinely
  boxed-in turtle gives up instead of looping forever.

  Depends on lib/nav.lua for position tracking, so the same rule applies:
  reaching the target only works if nothing else moves this turtle
  outside of pathfind/nav during the trip.
------------------------------------------------------------------------]]

if _G.__PATHFIND_MODULE then return _G.__PATHFIND_MODULE end

local nav = dofile("/lib/nav.lua")

local M = {}

local function dist(dx, dy, dz)
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- "Movement obstructed" covers both blocks and entities in CC:Tweaked, so
-- try both dig and attack -- whichever one actually applies just no-ops.
local function stepForward(allowDig)
  local ok, err = nav.forward()
  if ok then return true end
  if allowDig then
    turtle.dig()
    turtle.attack()
    ok, err = nav.forward()
    if ok then return true end
  end
  return false, err
end

local function stepUp(allowDig)
  local ok, err = nav.up()
  if ok then return true end
  if allowDig then
    turtle.digUp()
    turtle.attackUp()
    ok, err = nav.up()
    if ok then return true end
  end
  return false, err
end

local function stepDown(allowDig)
  local ok, err = nav.down()
  if ok then return true end
  if allowDig then
    turtle.digDown()
    turtle.attackDown()
    ok, err = nav.down()
    if ok then return true end
  end
  return false, err
end

local HEADING_FOR_DX = { [1] = 1, [-1] = 3 } -- +x -> east, -x -> west
local HEADING_FOR_DZ = { [1] = 2, [-1] = 0 } -- +z -> south, -z -> north

-- Tries every direction that would make progress this step, biggest
-- remaining-distance axis first, falling through to the others if the
-- preferred one fails. Returns true and which axis moved, or false and
-- the most recent error if nothing worked.
local function tryOneStep(target, allowDig)
  local pos = nav.getPosition()
  local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z

  local candidates = {}
  if dx ~= 0 then
    candidates[#candidates + 1] = { axis = "x", amount = math.abs(dx), fn = function()
      nav.face(HEADING_FOR_DX[dx > 0 and 1 or -1])
      return stepForward(allowDig)
    end }
  end
  if dz ~= 0 then
    candidates[#candidates + 1] = { axis = "z", amount = math.abs(dz), fn = function()
      nav.face(HEADING_FOR_DZ[dz > 0 and 1 or -1])
      return stepForward(allowDig)
    end }
  end
  if dy > 0 then
    candidates[#candidates + 1] = { axis = "y", amount = dy, fn = function() return stepUp(allowDig) end }
  elseif dy < 0 then
    candidates[#candidates + 1] = { axis = "y", amount = -dy, fn = function() return stepDown(allowDig) end }
  end

  table.sort(candidates, function(a, b) return a.amount > b.amount end)

  local lastErr
  for _, c in ipairs(candidates) do
    local ok, err = c.fn()
    if ok then return true, c.axis end
    lastErr = err
  end
  return false, nil, lastErr
end

-- Moves toward (x, y, z) until within `opts.tolerance` blocks of it
-- (default 0, i.e. exact) or it gives up. opts.allowDig (default false)
-- controls whether it digs/attacks through obstacles or just routes
-- around them via the other axes. opts.shouldStop, if given, is checked
-- before every single step (the finest granularity anything in this repo
-- uses -- unlike e.g. dom-main/mining/vertical.lua's own per-column
-- check, a stuck or merely slow multi-hundred-block trip can otherwise
-- block the console for its entire duration with no way to call it off).
--
-- Returns ok, info where info = { reason, distance, position }. reason
-- is "arrived", "stuck: <error>" (every axis failed with nothing left to
-- try), "interrupted" (shouldStop() returned true), or "gave up: too
-- many steps" (safety cap hit).
function M.goto(x, y, z, opts)
  opts = opts or {}
  local tolerance = opts.tolerance or 0
  local allowDig = opts.allowDig or false
  local shouldStop = opts.shouldStop
  local target = { x = x, y = y, z = z }

  local pos = nav.getPosition()
  local startDist = dist(target.x - pos.x, target.y - pos.y, target.z - pos.z)
  local maxSteps = math.max(20, math.floor(startDist * 4))

  print(("pathfind: heading to (%d, %d, %d), tolerance=%d, allowDig=%s")
    :format(x, y, z, tolerance, tostring(allowDig)))

  for _ = 1, maxSteps do
    if shouldStop and shouldStop() then
      pos = nav.getPosition()
      local d = dist(target.x - pos.x, target.y - pos.y, target.z - pos.z)
      print(("pathfind: interrupted, %.1f blocks from target"):format(d))
      return false, { reason = "interrupted", distance = d, position = pos }
    end

    pos = nav.getPosition()
    local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
    local d = dist(dx, dy, dz)
    if d <= tolerance then
      print(("pathfind: arrived at (%d, %d, %d), %.1f blocks from target"):format(pos.x, pos.y, pos.z, d))
      return true, { reason = "arrived", distance = d, position = pos }
    end

    local moved, _, err = tryOneStep(target, allowDig)
    if not moved then
      print("pathfind: stuck -- " .. tostring(err))
      return false, { reason = "stuck: " .. tostring(err), distance = d, position = nav.getPosition() }
    end
  end

  pos = nav.getPosition()
  local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
  local d = dist(dx, dy, dz)
  print(("pathfind: gave up after %d steps, %.1f blocks from target"):format(maxSteps, d))
  return false, { reason = "gave up: too many steps", distance = d, position = pos }
end

_G.__PATHFIND_MODULE = M
return M

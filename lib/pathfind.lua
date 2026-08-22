--[[----------------------------------------------------------------------
  lib/pathfind.lua -- moves the turtle toward a target (x, y, z).

  There's no map to plan a real route against -- a turtle only ever sees
  the block immediately in front/above/below it (lib/nav.lua's inspect
  functions). So this is a greedy stepper, not A*: every step it picks
  whichever axis (x, z, or y) has the largest remaining distance and
  tries to move that way, falling back to the other axes if that move
  fails. Optionally digs/attacks through whatever's blocking it -- except
  liquids (lib/nav.lua's isLiquid()), which it never digs, since a turtle
  can already move straight through one. If every axis that would make
  progress toward the target is blocked, it falls back further still to
  whatever's left -- including backtracking -- since a turtle boxed in on
  every useful side (bedrock is undiggable regardless of allowDig) can
  often still find a way around by momentarily moving away from the
  target, same as a person would. Bounded by a step cap (a multiple of
  the starting distance) so a genuinely dead-ended turtle gives up
  instead of looping forever.

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

-- Fisher-Yates shuffle, so the escape fallback below doesn't always try
-- the exact same direction first every time it's stuck -- see its own
-- comment for why a fixed order can loop forever.
local function shuffled(list)
  local copy = {}
  for i, v in ipairs(list) do copy[i] = v end
  for i = #copy, 2, -1 do
    local j = math.random(i)
    copy[i], copy[j] = copy[j], copy[i]
  end
  return copy
end

-- "Movement obstructed" covers both blocks and entities in CC:Tweaked, so
-- try both dig and attack -- whichever one actually applies just no-ops.
-- Liquids (see nav.isLiquid()) never get dug -- there's nothing to break,
-- and a turtle can already move straight through one -- so this skips
-- straight to retrying the move instead of wasting a dig attempt on it.
local function stepForward(allowDig)
  local ok, err = nav.forward()
  if ok then return true end
  if allowDig then
    local found, data = turtle.inspect()
    if not (found and nav.isLiquid(data.name)) then
      turtle.dig()
      turtle.attack()
    end
    ok, err = nav.forward()
    if ok then return true end
  end
  return false, err
end

local function stepUp(allowDig)
  local ok, err = nav.up()
  if ok then return true end
  if allowDig then
    local found, data = turtle.inspectUp()
    if not (found and nav.isLiquid(data.name)) then
      turtle.digUp()
      turtle.attackUp()
    end
    ok, err = nav.up()
    if ok then return true end
  end
  return false, err
end

local function stepDown(allowDig)
  local ok, err = nav.down()
  if ok then return true end
  if allowDig then
    local found, data = turtle.inspectDown()
    if not (found and nav.isLiquid(data.name)) then
      turtle.digDown()
      turtle.attackDown()
    end
    ok, err = nav.down()
    if ok then return true end
  end
  return false, err
end

local HEADING_FOR_DX = { [1] = 1, [-1] = 3 } -- +x -> east, -x -> west
local HEADING_FOR_DZ = { [1] = 2, [-1] = 0 } -- +z -> south, -z -> north

local function moveX(sign, allowDig)
  nav.face(HEADING_FOR_DX[sign])
  return stepForward(allowDig)
end

local function moveZ(sign, allowDig)
  nav.face(HEADING_FOR_DZ[sign])
  return stepForward(allowDig)
end

local function moveY(sign, allowDig)
  if sign > 0 then return stepUp(allowDig) end
  return stepDown(allowDig)
end

-- Tries every direction that would make progress this step, biggest
-- remaining-distance axis first, falling through to the others if the
-- preferred one fails -- then, if *all* of those are blocked, falls back
-- to trying whatever's left: the opposite way along any axis just tried,
-- plus both ways on any axis that didn't need trying at all (already
-- aligned with the target on it). A turtle boxed in by bedrock on every
-- side that would make direct progress can still often find a way around
-- by backtracking or sidestepping first, the same as a person would --
-- even though that step alone moves further from the target, tryOneStep
-- runs fresh again next step, so the normal toward-target logic just
-- resumes correcting course from wherever it lands. The escape options
-- are tried in random order (see shuffled() above) rather than a fixed
-- one: a fixed order (e.g. always backtracking straight away from the
-- target first) can oscillate forever between the same two cells when
-- that first option keeps succeeding -- it undoes itself, re-encounters
-- the exact same blocker, and "escapes" the exact same way again, next
-- step after next step, without ever trying the sidesteps that would
-- actually get around the obstacle. Randomizing means a repeat run of
-- the same losing pair is exponentially unlikely rather than guaranteed.
-- Returns true and
-- which axis moved ("x"/"z"/"y" toward the target, or "escape" for a
-- fallback move), or false and the most recent error if nothing at all
-- worked.
local function tryOneStep(target, allowDig)
  local pos = nav.getPosition()
  local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z

  local toward = {}
  if dx ~= 0 then
    toward[#toward + 1] = { axis = "x", amount = math.abs(dx), fn = function() return moveX(dx > 0 and 1 or -1, allowDig) end }
  end
  if dz ~= 0 then
    toward[#toward + 1] = { axis = "z", amount = math.abs(dz), fn = function() return moveZ(dz > 0 and 1 or -1, allowDig) end }
  end
  if dy ~= 0 then
    toward[#toward + 1] = { axis = "y", amount = math.abs(dy), fn = function() return moveY(dy > 0 and 1 or -1, allowDig) end }
  end

  table.sort(toward, function(a, b) return a.amount > b.amount end)

  local lastErr
  for _, c in ipairs(toward) do
    local ok, err = c.fn()
    if ok then return true, c.axis end
    lastErr = err
  end

  local escape = {}
  if dx ~= 0 then
    escape[#escape + 1] = function() return moveX(dx > 0 and -1 or 1, allowDig) end
  else
    escape[#escape + 1] = function() return moveX(1, allowDig) end
    escape[#escape + 1] = function() return moveX(-1, allowDig) end
  end
  if dz ~= 0 then
    escape[#escape + 1] = function() return moveZ(dz > 0 and -1 or 1, allowDig) end
  else
    escape[#escape + 1] = function() return moveZ(1, allowDig) end
    escape[#escape + 1] = function() return moveZ(-1, allowDig) end
  end
  if dy ~= 0 then
    escape[#escape + 1] = function() return moveY(dy > 0 and -1 or 1, allowDig) end
  else
    escape[#escape + 1] = function() return moveY(1, allowDig) end
    escape[#escape + 1] = function() return moveY(-1, allowDig) end
  end

  for _, fn in ipairs(shuffled(escape)) do
    local ok, err = fn()
    if ok then return true, "escape" end
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
-- is "arrived", "stuck: <error>" (every direction failed, including the
-- escape fallback -- genuinely boxed in on all sides), "interrupted"
-- (shouldStop() returned true), or "gave up: too many steps" (safety cap
-- hit, e.g. repeatedly backtracking without a real way through).
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

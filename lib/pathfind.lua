--[[----------------------------------------------------------------------
  lib/pathfind.lua -- moves the turtle toward a target (x, y, z).

  There's no map to plan a real route against -- a turtle only ever sees
  the block immediately in front/above/below it (lib/nav.lua's inspect
  functions). So this is a greedy stepper, not A*: every step it picks
  whichever axis (x, z, or y) has the largest remaining distance and
  tries to move that way, falling back to the other axes if that move
  fails. Optionally digs/attacks through whatever's blocking it -- except
  liquids (lib/nav.lua's isLiquid()), which it never digs, since a turtle
  can already move straight through one, and, unless opts.allowDig is
  specifically "all", chests or ComputerCraft blocks (lib/nav.lua's
  isChest()/isComputerCraftBlock()) either, which it routes around instead
  -- see digMode() below. If every axis that would make
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

-- Whether to skip dig()/attack() and go straight to retrying the move
-- instead: true for liquids (nothing to break, and a turtle can already
-- move straight through one) always, and for chests or ComputerCraft
-- blocks (another turtle, computer, modem, monitor, etc.) specifically
-- when allowDig is "safe" rather than "all" -- see M.goto's opts.allowDig
-- doc for why "safe" exists and is the default whenever digging is on at
-- all.
local function shouldSkipDig(found, data, allowDig)
  if not found then return false end
  if nav.isLiquid(data.name) then return true end
  return allowDig == "safe" and (nav.isChest(data.name) or nav.isComputerCraftBlock(data.name))
end

-- "Movement obstructed" covers both blocks and entities in CC:Tweaked, so
-- try both dig and attack -- whichever one actually applies just no-ops.
local function stepForward(allowDig)
  local ok, err = nav.forward()
  if ok then return true end
  if allowDig then
    local found, data = turtle.inspect()
    if not shouldSkipDig(found, data, allowDig) then
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
    if not shouldSkipDig(found, data, allowDig) then
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
    if not shouldSkipDig(found, data, allowDig) then
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
--
-- `justLeft` (the position tryOneStep moved away from on the PREVIOUS
-- call, or nil on the first) guards against a second, subtler
-- oscillation randomizing the escape order alone doesn't fix: a toward
-- move can succeed trivially by walking right back onto the cell an
-- escape move just retreated from (that cell is open -- the turtle was
-- just standing on it), even though the *real* obstacle is still one
-- cell further on. That toward move isn't wrong on its own, but taking
-- it immediately means the turtle never gets anywhere ELSE from the
-- retreated-to cell (e.g. a ceiling opening up one block further back
-- that only becomes reachable by staying put a step longer to try other
-- axes) -- it just walks straight back into the same wall, forcing
-- another retreat, forcing the same walk-back, forever. Any candidate
-- (toward or escape) whose destination is exactly `justLeft` is
-- deferred behind every other candidate in its own list instead of
-- skipped outright -- undoing the previous step is sometimes genuinely
-- the only option (a true one-cell-wide dead end), so it stays
-- available as a last resort, just never taken over a candidate that
-- would actually go somewhere new. Returns true and which axis moved
-- ("x"/"z"/"y" toward the target, or "escape" for a fallback move), or
-- false and the most recent error if nothing at all worked.
local function tryOneStep(target, allowDig, justLeft)
  local pos = nav.getPosition()
  local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z

  local function isJustLeft(nx, ny, nz)
    return justLeft ~= nil and justLeft.x == nx and justLeft.y == ny and justLeft.z == nz
  end

  local toward = {}
  if dx ~= 0 then
    local sign = dx > 0 and 1 or -1
    toward[#toward + 1] = { axis = "x", amount = math.abs(dx), nx = pos.x + sign, ny = pos.y, nz = pos.z,
      fn = function() return moveX(sign, allowDig) end }
  end
  if dz ~= 0 then
    local sign = dz > 0 and 1 or -1
    toward[#toward + 1] = { axis = "z", amount = math.abs(dz), nx = pos.x, ny = pos.y, nz = pos.z + sign,
      fn = function() return moveZ(sign, allowDig) end }
  end
  if dy ~= 0 then
    local sign = dy > 0 and 1 or -1
    toward[#toward + 1] = { axis = "y", amount = math.abs(dy), nx = pos.x, ny = pos.y + sign, nz = pos.z,
      fn = function() return moveY(sign, allowDig) end }
  end

  table.sort(toward, function(a, b) return a.amount > b.amount end)

  local escape = {}
  if dx ~= 0 then
    local sign = dx > 0 and -1 or 1
    escape[#escape + 1] = { axis = "escape", nx = pos.x + sign, ny = pos.y, nz = pos.z,
      fn = function() return moveX(sign, allowDig) end }
  else
    escape[#escape + 1] = { axis = "escape", nx = pos.x + 1, ny = pos.y, nz = pos.z, fn = function() return moveX(1, allowDig) end }
    escape[#escape + 1] = { axis = "escape", nx = pos.x - 1, ny = pos.y, nz = pos.z, fn = function() return moveX(-1, allowDig) end }
  end
  if dz ~= 0 then
    local sign = dz > 0 and -1 or 1
    escape[#escape + 1] = { axis = "escape", nx = pos.x, ny = pos.y, nz = pos.z + sign,
      fn = function() return moveZ(sign, allowDig) end }
  else
    escape[#escape + 1] = { axis = "escape", nx = pos.x, ny = pos.y, nz = pos.z + 1, fn = function() return moveZ(1, allowDig) end }
    escape[#escape + 1] = { axis = "escape", nx = pos.x, ny = pos.y, nz = pos.z - 1, fn = function() return moveZ(-1, allowDig) end }
  end
  if dy ~= 0 then
    local sign = dy > 0 and -1 or 1
    escape[#escape + 1] = { axis = "escape", nx = pos.x, ny = pos.y + sign, nz = pos.z,
      fn = function() return moveY(sign, allowDig) end }
  else
    escape[#escape + 1] = { axis = "escape", nx = pos.x, ny = pos.y + 1, nz = pos.z, fn = function() return moveY(1, allowDig) end }
    escape[#escape + 1] = { axis = "escape", nx = pos.x, ny = pos.y - 1, nz = pos.z, fn = function() return moveY(-1, allowDig) end }
  end

  local lastErr

  -- Tries every candidate in `list`, in order, except ones landing back
  -- on justLeft -- those are deferred to a second pass instead of
  -- skipped outright, so undoing the previous step stays available as a
  -- last resort within this same list.
  local function attempt(list)
    local deferred = {}
    for _, c in ipairs(list) do
      if isJustLeft(c.nx, c.ny, c.nz) then
        deferred[#deferred + 1] = c
      else
        local ok, err = c.fn()
        if ok then return true, c.axis end
        lastErr = err
      end
    end
    for _, c in ipairs(deferred) do
      local ok, err = c.fn()
      if ok then return true, c.axis end
      lastErr = err
    end
    return false
  end

  local ok, axis = attempt(toward)
  if ok then return true, axis end

  ok, axis = attempt(shuffled(escape))
  if ok then return true, axis end

  return false, nil, lastErr
end

-- Normalizes opts.allowDig into exactly one of: false (never dig), "safe"
-- (dig/attack through obstacles, but route around a chest or ComputerCraft
-- block instead of destroying it -- the default the moment digging is on
-- at all, since a dig-through job has no way to tell a player's storage
-- chest (or another turtle/computer) apart from any other obstacle
-- otherwise), or "all" (dig through anything, chests and ComputerCraft
-- blocks included -- an explicit opt-in for when that's really what's
-- wanted). Bare `true` (from before "safe"/"all" existed) is treated as
-- "safe", so old callers passing a boolean keep working, just
-- chest/ComputerCraft-protected now.
local function digMode(allowDig)
  if allowDig == "all" then return "all" end
  if allowDig then return "safe" end
  return false
end

-- Moves toward (x, y, z) until within `opts.tolerance` blocks of it
-- (default 0, i.e. exact) or it gives up. opts.allowDig (default false)
-- is false, "safe", or "all" -- see digMode() above -- controlling
-- whether it digs/attacks through obstacles at all, and if so, whether a
-- chest or ComputerCraft block is fair game or routed around like an
-- undiggable block.
-- opts.shouldStop, if given, is checked
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
  local allowDig = digMode(opts.allowDig)
  local shouldStop = opts.shouldStop
  local target = { x = x, y = y, z = z }

  local pos = nav.getPosition()
  local startDist = dist(target.x - pos.x, target.y - pos.y, target.z - pos.z)
  local maxSteps = math.max(20, math.floor(startDist * 4))

  -- [dist=%.1f] is a machine-parseable tag, not just for a human
  -- reading it live -- `turtlectl.py console --silent` uses it to drop
  -- a short hop (e.g. dom-main/mining/vertical.lua's mineVein calling
  -- M.goto once per block of a vein, each only a step or two) while
  -- still keeping a genuinely long trip. Kept on both this line and the
  -- "arrived" one below so either can be classified on its own, without
  -- the console needing to correlate a heading/arrived pair itself.
  print(("pathfind: heading to (%d, %d, %d), tolerance=%d, allowDig=%s [dist=%.1f]")
    :format(x, y, z, tolerance, tostring(allowDig), startDist))

  -- The position the previous step moved away from, passed to
  -- tryOneStep so it can deprioritize (not forbid -- see its own
  -- comment) immediately undoing that step. nil for the first step,
  -- since there's nothing to avoid undoing yet.
  local justLeft = nil

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
      print(("pathfind: arrived at (%d, %d, %d), %.1f blocks from target [dist=%.1f]"):format(pos.x, pos.y, pos.z, d, startDist))
      return true, { reason = "arrived", distance = d, position = pos }
    end

    local moved, _, err = tryOneStep(target, allowDig, justLeft)
    if not moved then
      print("pathfind: stuck -- " .. tostring(err))
      return false, { reason = "stuck: " .. tostring(err), distance = d, position = nav.getPosition() }
    end
    justLeft = pos
  end

  pos = nav.getPosition()
  local dx, dy, dz = target.x - pos.x, target.y - pos.y, target.z - pos.z
  local d = dist(dx, dy, dz)
  print(("pathfind: gave up after %d steps, %.1f blocks from target"):format(maxSteps, d))
  return false, { reason = "gave up: too many steps", distance = d, position = pos }
end

_G.__PATHFIND_MODULE = M
return M

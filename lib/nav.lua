--[[----------------------------------------------------------------------
  lib/nav.lua -- tracks this turtle's position/heading and reports what's
  immediately around it (front/up/down blocks). Meant to be dofile()'d by
  other scripts as a shared information-gathering tool.

  Position is GPS-anchored if a GPS network is reachable the first time
  it's used, otherwise it's relative to wherever the turtle was when
  tracking began (0,0,0). Either way, staying accurate depends on all
  movement going through nav.forward/back/up/down/turnLeft/turnRight
  instead of the raw turtle.* functions -- calling turtle.forward()
  directly desyncs the tracked position.

  forward/back/up/down all check (and try to recover, see lib/fuel.lua)
  fuel before attempting the move, rather than just calling turtle.*()
  and taking whatever error comes back -- CC:Tweaked reports "Movement
  obstructed" for an out-of-fuel turtle too if anything else also
  happens to be in the way at that moment, which would otherwise mask a
  permanent fuel shortage behind what looks like a routine, temporary
  obstruction.

  State persists to /state/nav.state, which survives startup.lua's wipe.

  dofile() (unlike require()) always re-executes a file and hands back a
  fresh table, so anything else that also dofile()s this -- lib/pathfind.lua
  included -- would otherwise get its own independent copy of `state`,
  invisible to a caller's own `nav` handle. A caller that moves via its own
  nav.forward()/etc, then hands off to pathfind.goto() (which dofiles this
  file again internally), would see its own nav.getPosition() go stale the
  moment pathfind starts moving the turtle. Guard against that by caching
  the built module on _G so every dofile() of this file in the same running
  session returns the exact same instance.
------------------------------------------------------------------------]]

if _G.__NAV_MODULE then return _G.__NAV_MODULE end

local fuel = dofile("/lib/fuel.lua")

local STATE_PATH  = "/state/nav.state"
local GPS_TIMEOUT = 2 -- seconds

local HEADINGS = { "north", "east", "south", "west" }
local HEADING_BY_NAME = { north = 0, east = 1, south = 2, west = 3 }
local DELTA = {
  [0] = { x = 0,  z = -1 }, -- north
  [1] = { x = 1,  z = 0 },  -- east
  [2] = { x = 0,  z = 1 },  -- south
  [3] = { x = -1, z = 0 },  -- west
}

local M = {}
local state -- lazily loaded/initialized, see init()

local function save()
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(state))
  f.close()
end

local function loadState()
  if not fs.exists(STATE_PATH) then return nil end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

local function init()
  if state then return end
  state = loadState()
  if state then return end

  state = { x = 0, y = 0, z = 0, heading = 0, source = "relative" }
  local x, y, z = gps.locate(GPS_TIMEOUT)
  if x then
    state.x, state.y, state.z = x, y, z
    state.source = "gps"
  end
  save()
end

-- Overrides the tracked position/heading -- e.g. after reading real
-- coordinates off the F3 debug screen when no GPS network is set up.
-- `facing` may be a heading number (0-3) or a compass name ("west", etc).
function M.setPosition(x, y, z, facing)
  local heading
  if type(facing) == "string" then
    heading = HEADING_BY_NAME[facing:lower()]
    if not heading then error("unknown facing: " .. tostring(facing), 2) end
  elseif type(facing) == "number" then
    heading = facing % 4
  else
    error("facing must be a heading number (0-3) or a compass name", 2)
  end

  state = { x = x, y = y, z = z, heading = heading, source = "manual" }
  save()
end

-- init() only ever calls gps.locate() the very first time a turtle's
-- /state/nav.state doesn't exist yet -- once ANY position is persisted
-- (including a manual one from M.setPosition(), which is how this
-- whole fleet's positions have been set so far), init() loads it
-- straight from disk and never tries GPS again on its own. This is the
-- explicit opt-in for upgrading an already-tracked turtle onto a real
-- GPS network once one exists (dom-main/controller/gpshost.lua, or any
-- dedicated anchor computers) -- e.g. via a fleet-wide operator command
-- -- without needing to delete its state and gamble on GPS succeeding
-- before it moves again. Heading is left untouched either way (GPS has
-- no way to sense facing -- see M.getPosition()'s own comment).
-- Returns true, position on success (state updated, persisted), or
-- false, reason on failure (state left completely untouched -- whatever
-- was tracked before, GPS-fixed or not, stays exactly as it was).
function M.reacquireGPS()
  init()
  local x, y, z = gps.locate(GPS_TIMEOUT)
  if not x then
    return false, "no GPS fix (no anchor network reachable, or fewer than 4 in range)"
  end
  state.x, state.y, state.z = x, y, z
  state.source = "gps"
  save()
  return true, { x = x, y = y, z = z }
end

-- Position/heading only, no block inspection. Heading is always dead-
-- reckoned -- nothing (GPS included) senses facing direction.
function M.getPosition()
  init()
  return {
    x = state.x, y = state.y, z = state.z,
    heading = state.heading,
    facing = HEADINGS[state.heading + 1],
    gpsFixed = state.source ~= "relative",
    source = state.source,
  }
end

local function describeInspect(found, data)
  if not found then return { present = false } end
  -- data.tags is omitted deliberately: on a heavily modded server it can
  -- be hundreds of entries per block, which is noise for anything trying
  -- to make a decision off "what block is this" (name/state cover that).
  return { present = true, name = data.name, state = data.state }
end

function M.inspectFront() return describeInspect(turtle.inspect()) end
function M.inspectUp() return describeInspect(turtle.inspectUp()) end
function M.inspectDown() return describeInspect(turtle.inspectDown()) end

-- Water and lava aren't solid -- a turtle can move straight through
-- either one (and takes no damage from lava) without digging first.
-- Digging one does nothing useful anyway (there's no block to break),
-- so anything that dig-then-moves should check this first and skip
-- straight to moving if it's true, rather than wasting a dig attempt.
function M.isLiquid(name)
  if not name then return false end
  return name:find("water") ~= nil or name:find("lava") ~= nil
end

-- Is a block name a chest (any variant -- trapped, modded, etc). Used by
-- lib/pathfind.lua's "safe" dig mode to route around a chest instead of
-- destroying it, since a dig-through job (mining, a --dig goto) has no
-- way to tell a player's storage chest apart from any other obstacle
-- otherwise.
function M.isChest(name)
  if not name then return false end
  return name:lower():find("chest", 1, true) ~= nil
end

-- Is a block name a ComputerCraft block -- another turtle, computer,
-- modem, monitor, disk drive, etc. Namespace prefix rather than a
-- substring like isChest(), since these are always CC:Tweaked's own
-- registry ID (mod id stayed "computercraft" even after the CC:Tweaked
-- rename) and never a modded reskin -- unlike a chest, there's no
-- legitimate reason to ever dig through one, so lib/pathfind.lua and
-- dom-main/mining/vertical.lua route around it exactly like a chest.
function M.isComputerCraftBlock(name)
  if not name then return false end
  return name:lower():find("^computercraft:") ~= nil
end

-- Spins through all 4 compass headings -- exactly 4 turnRight()s, so it
-- always ends up back at the heading it started with -- inspecting front
-- at each one, plus up/down: the full 6-block "shell" around the turtle,
-- not just whichever way it happens to be facing. Used by here()/report()
-- when opts.full is set.
local function surroundings()
  init()
  local around = {}
  for _ = 1, 4 do
    around[HEADINGS[state.heading + 1]] = M.inspectFront()
    M.turnRight()
  end
  around.up = M.inspectUp()
  around.down = M.inspectDown()
  return around
end

-- Main information-gathering entry point: where the turtle is and what's
-- immediately around it, as a plain table for other scripts to consume.
-- opts.full (default false) additionally spins the turtle to survey all
-- 6 neighboring blocks (north/east/south/west/up/down) instead of just
-- front/up/down -- see surroundings() above.
--
-- front/up/down are always their own fresh inspect() calls, even when
-- opts.full also inspects those same directions via around -- reusing
-- the same table object in two places here (info.front = info.around.x,
-- say) would make front and around.x the *same* table, and CC:Tweaked's
-- textutils.serialize() (used by lib/remote.lua to format command
-- results) refuses to serialize a table that references the same
-- sub-table from more than one place ("Cannot serialize table with
-- repeated entries"). A few extra inspect() calls are cheap; that error
-- reaching an operator mid-command is not worth avoiding them for.
function M.here(opts)
  init()
  local info = {
    x = state.x, y = state.y, z = state.z,
    heading = state.heading,
    facing = HEADINGS[state.heading + 1],
    gpsFixed = state.source ~= "relative",
    source = state.source,
    front = M.inspectFront(),
    up = M.inspectUp(),
    down = M.inspectDown(),
  }
  if opts and opts.full then
    info.around = surroundings()
  end
  return info
end

local function describeBlock(b)
  if not b.present then return "air/none" end
  return b.name
end

-- Prints a human-readable snapshot and returns the same table as here(),
-- so it's equally useful typed interactively (incl. over the remote
-- console) or called from a script. opts.full, same as here() above.
function M.report(opts)
  local info = M.here(opts)
  local tag = ""
  if info.source == "relative" then tag = "  [relative, no GPS fix]"
  elseif info.source == "manual" then tag = "  [manually calibrated]"
  end
  print(("pos: (%d, %d, %d)  facing: %s%s"):format(info.x, info.y, info.z, info.facing, tag))
  if opts and opts.full then
    for _, dir in ipairs({ "north", "east", "south", "west", "up", "down" }) do
      print(("%-6s %s"):format(dir .. ":", describeBlock(info.around[dir])))
    end
  else
    print("front: " .. describeBlock(info.front))
    print("up:    " .. describeBlock(info.up))
    print("down:  " .. describeBlock(info.down))
  end
  return info
end

-- Checked at the top of every movement wrapper below, before the actual
-- turtle.*() call: CC:Tweaked's own "Movement obstructed" check runs
-- BEFORE its fuel check, so a turtle that's genuinely just out of fuel
-- can report "obstructed" instead if anything else also happens to be
-- in the way at that exact moment -- masking the real, permanent reason
-- it can't move. Checking (and trying to recover) fuel first, ourselves,
-- means a fuel shortage is always identified as exactly that, never
-- mistaken for or hidden behind an obstruction. See lib/fuel.lua.
local function ensureFuel()
  if fuel.hasFuel() then return true end
  local ok, reason = fuel.ensureFuel()
  if ok then return true end
  return false, "out of fuel (" .. tostring(reason) .. ")"
end

-- Movement wrappers: keep tracked position/heading in sync. Same return
-- values as the underlying turtle.* call, so they drop in as replacements.
function M.forward()
  init()
  local fuelOk, fuelErr = ensureFuel()
  if not fuelOk then return false, fuelErr end
  local ok, err = turtle.forward()
  if ok then
    local d = DELTA[state.heading]
    state.x, state.z = state.x + d.x, state.z + d.z
    save()
  end
  return ok, err
end

function M.back()
  init()
  local fuelOk, fuelErr = ensureFuel()
  if not fuelOk then return false, fuelErr end
  local ok, err = turtle.back()
  if ok then
    local d = DELTA[state.heading]
    state.x, state.z = state.x - d.x, state.z - d.z
    save()
  end
  return ok, err
end

function M.up()
  init()
  local fuelOk, fuelErr = ensureFuel()
  if not fuelOk then return false, fuelErr end
  local ok, err = turtle.up()
  if ok then
    state.y = state.y + 1
    save()
  end
  return ok, err
end

function M.down()
  init()
  local fuelOk, fuelErr = ensureFuel()
  if not fuelOk then return false, fuelErr end
  local ok, err = turtle.down()
  if ok then
    state.y = state.y - 1
    save()
  end
  return ok, err
end

function M.turnLeft()
  init()
  local ok, err = turtle.turnLeft()
  if ok then
    state.heading = (state.heading - 1) % 4
    save()
  end
  return ok, err
end

function M.turnRight()
  init()
  local ok, err = turtle.turnRight()
  if ok then
    state.heading = (state.heading + 1) % 4
    save()
  end
  return ok, err
end

-- Turns to face `facing` (a heading number 0-3, or a compass name like
-- "west") using the fewest turns -- at most one turnLeft/turnRight/180.
function M.face(facing)
  local heading
  if type(facing) == "string" then
    heading = HEADING_BY_NAME[facing:lower()]
    if not heading then error("unknown facing: " .. tostring(facing), 2) end
  elseif type(facing) == "number" then
    heading = facing % 4
  else
    error("facing must be a heading number (0-3) or a compass name", 2)
  end

  init()
  local diff = (heading - state.heading) % 4
  if diff == 1 then M.turnRight()
  elseif diff == 3 then M.turnLeft()
  elseif diff == 2 then M.turnRight(); M.turnRight()
  end
end

-- Whether to leave a block alone rather than dig through it while
-- hunting for an opening to move through -- same conservative policy as
-- lib/pathfind.lua's "safe" allowDig: never touch a liquid (nothing to
-- break, and a turtle can already move straight through one) or a chest
-- or other ComputerCraft block (another turtle, computer, modem,
-- monitor, etc.) -- this is just trying to detect which way the turtle
-- is facing, not a real trip, so it should never destroy anything an
-- operator would mind losing.
local function shouldSkipDig(found, data)
  if not found then return false end
  return M.isLiquid(data.name) or M.isChest(data.name) or M.isComputerCraftBlock(data.name)
end

-- "Movement obstructed" covers both blocks and entities in CC:Tweaked,
-- same as lib/pathfind.lua's stepForward -- try both, whichever applies
-- no-ops. Tries the plain move first so nothing gets dug for no reason
-- when the way is already clear.
local function tryForward()
  if M.forward() then return true end
  local found, data = turtle.inspect()
  if not shouldSkipDig(found, data) then
    turtle.dig()
    turtle.attack()
  end
  return M.forward()
end

-- There's no turtle.inspectBack()/digBack() in the CC:Tweaked API -- the
-- only way to see or clear whatever's directly behind the turtle is to
-- turn around, treat it as "front" for a moment, then turn back. Two
-- turnRights land back on the exact same heading either way, so this is
-- safe to do purely to attempt a dig.
local function tryBack()
  if M.back() then return true end
  M.turnRight(); M.turnRight()
  local found, data = turtle.inspect()
  if not shouldSkipDig(found, data) then
    turtle.dig()
    turtle.attack()
  end
  M.turnRight(); M.turnRight()
  return M.back()
end

local function tryUp()
  if M.up() then return true end
  local found, data = turtle.inspectUp()
  if not shouldSkipDig(found, data) then
    turtle.digUp()
    turtle.attackUp()
  end
  return M.up()
end

local function tryDown()
  if M.down() then return true end
  local found, data = turtle.inspectDown()
  if not shouldSkipDig(found, data) then
    turtle.digDown()
    turtle.attackDown()
  end
  return M.down()
end

-- Determines this turtle's REAL facing, unlike M.reacquireGPS() (which
-- only ever fixes position -- see that function's own comment for why
-- GPS has no way to sense orientation at all). The only way to learn
-- facing is to actually move and see which way the coordinates shifted:
-- take a GPS fix, try to step one block (forward, then back, at each of
-- up to 4 turns; if every horizontal direction here is blocked, try one
-- level up, then one level down, before giving up), take a second GPS
-- fix, and work out heading from the delta between them. Digs through
-- whatever's in the way (see shouldSkipDig above) rather than giving up
-- the moment the first direction is blocked -- a turtle that was just
-- placed by an operator has no guarantee of open space in front of it.
-- Always retraces its own steps afterward (even if the second GPS fix
-- fails), so this never leaves the turtle anywhere but where it
-- started. Returns true, { x, y, z, heading, facing } on success, or
-- false, reason if there's no GPS fix at all, not enough fuel to risk a
-- couple of test moves, or every direction it tried was blocked.
function M.detectHeading()
  init()
  if not gps then return false, "no gps API available" end
  if not fuel.hasFuel(4) then return false, "not enough fuel to safely detect heading" end
  local x1, y1, z1 = gps.locate(GPS_TIMEOUT)
  if not x1 then return false, "no GPS fix" end

  -- Tries every heading at the CURRENT height (forward, then back, at
  -- each of up to 4 turns), returning ("forward"|"back", turnsApplied)
  -- the moment one works, or (nil, nil) after cycling all the way back
  -- to the original facing having found nothing.
  local function tryAllHeadingsHere()
    for t = 0, 3 do
      if tryForward() then return "forward", t end
      if tryBack() then return "back", t end
      if t < 3 then M.turnRight() end
    end
    M.turnRight() -- undo the 3 turns above -- back to the original facing
    return nil, nil
  end

  local kind, turns = tryAllHeadingsHere()
  local vertical = nil -- "up"/"down" if every horizontal direction was blocked

  if not kind and tryUp() then
    vertical = "up"
    kind, turns = tryAllHeadingsHere()
    if not kind then M.down() end -- straight back down the way we just came up
  end

  if not kind and not vertical and tryDown() then
    vertical = "down"
    kind, turns = tryAllHeadingsHere()
    if not kind then M.up() end -- straight back up the way we just came down
  end

  if not kind then
    return false, "surrounded on every side (and above/below) -- could not detect heading"
  end

  local x2, y2, z2 = gps.locate(GPS_TIMEOUT)

  -- Retrace regardless of whether the second fix succeeded -- getting
  -- back to the start position/facing matters more than the fix itself.
  if kind == "forward" then M.back() else M.forward() end
  if vertical == "up" then M.down() elseif vertical == "down" then M.up() end
  for _ = 1, turns do M.turnLeft() end

  if not x2 then return false, "lost GPS fix mid-detection" end

  local dx, dz = x2 - x1, z2 - z1
  local movedHeading
  if dx == 1 and dz == 0 then movedHeading = 1
  elseif dx == -1 and dz == 0 then movedHeading = 3
  elseif dz == 1 and dx == 0 then movedHeading = 2
  elseif dz == -1 and dx == 0 then movedHeading = 0
  else
    return false, "unexpected GPS shift (" .. dx .. ", " .. dz .. ") -- could not determine heading"
  end
  if kind == "back" then movedHeading = (movedHeading + 2) % 4 end

  local heading = (movedHeading - turns) % 4
  state.x, state.y, state.z = x1, y1, z1
  state.heading = heading
  state.source = "gps"
  save()

  return true, { x = x1, y = y1, z = z1, heading = heading, facing = HEADINGS[heading + 1] }
end

_G.__NAV_MODULE = M
return M

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

  State persists to /state/nav.state, which survives startup.lua's wipe.
------------------------------------------------------------------------]]

local STATE_PATH  = "/state/nav.state"
local GPS_TIMEOUT = 2 -- seconds

local HEADINGS = { "north", "east", "south", "west" }
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

  state = { x = 0, y = 0, z = 0, heading = 0, gpsFixed = false }
  local x, y, z = gps.locate(GPS_TIMEOUT)
  if x then
    state.x, state.y, state.z = x, y, z
    state.gpsFixed = true
  end
  save()
end

-- Position/heading only, no block inspection. Heading is always dead-
-- reckoned -- nothing (GPS included) senses facing direction.
function M.getPosition()
  init()
  return {
    x = state.x, y = state.y, z = state.z,
    heading = state.heading,
    facing = HEADINGS[state.heading + 1],
    gpsFixed = state.gpsFixed,
  }
end

local function describeInspect(found, data)
  if not found then return { present = false } end
  return { present = true, name = data.name, state = data.state, tags = data.tags }
end

function M.inspectFront() return describeInspect(turtle.inspect()) end
function M.inspectUp() return describeInspect(turtle.inspectUp()) end
function M.inspectDown() return describeInspect(turtle.inspectDown()) end

-- Main information-gathering entry point: where the turtle is and what's
-- immediately around it, as a plain table for other scripts to consume.
function M.here()
  init()
  return {
    x = state.x, y = state.y, z = state.z,
    heading = state.heading,
    facing = HEADINGS[state.heading + 1],
    gpsFixed = state.gpsFixed,
    front = M.inspectFront(),
    up = M.inspectUp(),
    down = M.inspectDown(),
  }
end

local function describeBlock(b)
  if not b.present then return "air/none" end
  return b.name
end

-- Prints a human-readable snapshot and returns the same table as here(),
-- so it's equally useful typed interactively (incl. over the remote
-- console) or called from a script.
function M.report()
  local info = M.here()
  print(("pos: (%d, %d, %d)  facing: %s%s"):format(
    info.x, info.y, info.z, info.facing,
    info.gpsFixed and "" or "  [relative, no GPS fix]"
  ))
  print("front: " .. describeBlock(info.front))
  print("up:    " .. describeBlock(info.up))
  print("down:  " .. describeBlock(info.down))
  return info
end

-- Movement wrappers: keep tracked position/heading in sync. Same return
-- values as the underlying turtle.* call, so they drop in as replacements.
function M.forward()
  init()
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
  local ok, err = turtle.up()
  if ok then
    state.y = state.y + 1
    save()
  end
  return ok, err
end

function M.down()
  init()
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

return M

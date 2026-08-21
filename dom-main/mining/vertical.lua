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
  faster too. It then shifts to a new column -- stepping `columnStep`
  blocks further out in the direction given by `facing` (default north;
  see FACINGS below) every time; the column's *starting height* (y)
  shifts by columnDY, alternating sign each time -- and starts again,
  forever, until told to stop. `facing` sets the *marching* direction the
  whole operation advances in over time, not the legs' own dig direction:
  the legs always run perpendicular to it (M.run() turns to face that
  perpendicular once, up front), since marching parallel to the legs
  would just walk new columns down the same line the legs already dug,
  instead of spreading coverage into a fresh plane. Staggering each
  column's start height rather than starting every column at the same y
  means adjacent columns' horizontal legs also land at different depths
  instead of perfectly overlapping.

  Meant to run as a lib/job.lua job (see main.lua), not called directly:
  a run long enough to be worth calling "forever" would otherwise block
  the remote console from ever reaching it again. Start/stop it with:
    dofile("/lib/job.lua").request("mine_vertical", { legLength = 10 })
    dofile("/lib/job.lua").stop()
  shouldStop() (passed in by lib/job.lua) is only checked once per column
  iteration (between full down+forward+turn cycles), not between
  individual blocks -- so expect up to roughly a `descend + legLength`
  block actions' worth of latency before a stop actually takes effect.

  Checks inventory once per column boundary (same granularity as the
  shouldStop check, and for the same reason -- checking mid-leg would add
  a lot of complexity for a rare event). If full, it finds a chest (see
  lib/chestfinder.lua -- defaults to searching around lib/home.lua's
  position), drops everything in, and returns to the column it was
  working on before continuing. If no chest can be found, or the one
  found is itself too full to take everything, mining stops rather than
  quietly discarding items or looping forever hunting for space.

  Three optional boolean modes, all default true:
  - tidy: the inventory-unloading behavior described above. tidy = false
    skips the chest hunt entirely -- a full inventory just stops the job
    with a clear reason, for when no chest is set up or you'd rather
    manage unloading yourself.
  - observant: after every successful forward leg step, turns to peek at
    the block to the left and the right before turning back straight
    (four extra turns per step) and prints anything it sees. Purely a
    sensing behavior -- deliberately scoped to horizontal leg movement
    only, not descend, since that's where "left/right" means anything.
  - thorough: chases down veins of anything observant spots (ore, ancient
    debris -- see isValuable() below) instead of leaving it for a
    neighboring leg to maybe stumble into later. thorough only ever acts
    on what observant found, so it has no effect with observant = false
    -- it doesn't separately re-inspect the block a leg is about to dig
    through, since by the time a vein's spotted that way the turtle's
    already committed to consuming it as a normal part of the leg. When
    it does trigger, it flood-fills outward through connected valuable
    neighbors (see mineVein() below), bounded by MAX_VEIN_BLOCKS, then
    returns to exactly the position/heading the leg left off at.
------------------------------------------------------------------------]]

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")
local home = dofile("/lib/home.lua")
local inventory = dofile("/lib/inventory.lua")
local chestfinder = dofile("/lib/chestfinder.lua")

local M = {}

local DEFAULTS = {
  legLength  = 10,       -- blocks dug per forward/backward leg
  descend    = 3,        -- blocks descended before each leg
  minFuel    = 500,      -- abort before starting a new column if fuel can't be brought above this
  columnStep = 1,        -- blocks each new column advances, in the `facing` direction, from the previous one
  columnDY   = 1,        -- magnitude of the start-height shift each new column; sign alternates every column
  facing     = "north",  -- overall direction the mine advances in -- see FACINGS below
  tidy       = true,     -- auto-unload into a chest when full, instead of just stopping
  observant  = true,     -- peek left/right on every leg step
  thorough   = true,     -- chase veins of anything observant spots
}

-- params.<mode> or'ing against a default breaks for an explicit `false`
-- (false or true == true) -- this treats "not provided" (nil) as the only
-- case that falls back to the default.
local function optBool(v, default)
  if v == nil then return default end
  return v
end

-- Maps the marching direction (`facing`, a compass name) to which world
-- axis it advances along and which way, plus which way the legs (the
-- perpendicular axis) should face -- picked once, up front, since legs
-- alternate their own direction every leg anyway via a 180 turn, so
-- either perpendicular choice works equally well.
local FACINGS = {
  north = { axis = "z", sign = -1, legFacing = "east" },
  south = { axis = "z", sign = 1,  legFacing = "east" },
  east  = { axis = "x", sign = 1,  legFacing = "north" },
  west  = { axis = "x", sign = -1, legFacing = "north" },
}

-- Bounds dig retries -- see dom-main/mining/strip.lua for why this can't
-- be unbounded (CraftOS's "too long without yielding" watchdog).
local MAX_DIG_ATTEMPTS = 8

-- "Valuable" for `thorough`'s purposes: any ore block (vanilla and
-- modded blocks alike overwhelmingly follow the "..._ore" naming
-- convention, including deepslate variants) plus ancient debris, which
-- doesn't. Deliberately broad rather than an exact vanilla ID list, so a
-- modded server's ores get chased too without needing an update here.
local function isValuable(name)
  if not name then return false end
  return name:find("_ore$") ~= nil or name:find("ancient_debris$") ~= nil
end

-- The 6 axis-aligned neighbors of a cell. The 4 horizontal ones carry the
-- heading to turn to before inspecting that direction; up/down need no
-- turn. Mirrors lib/nav.lua's own (private) heading->delta mapping.
local NEIGHBOR_DELTAS = {
  { dx = 0,  dy = 0,  dz = -1, heading = 0 }, -- north
  { dx = 1,  dy = 0,  dz = 0,  heading = 1 }, -- east
  { dx = 0,  dy = 0,  dz = 1,  heading = 2 }, -- south
  { dx = -1, dy = 0,  dz = 0,  heading = 3 }, -- west
  { dx = 0,  dy = 1,  dz = 0 },               -- up
  { dx = 0,  dy = -1, dz = 0 },               -- down
}

-- Derived from NEIGHBOR_DELTAS above rather than duplicated, so the two
-- can't drift out of sync: heading (0-3) -> that direction's dx/dz.
local HEADING_DELTA = {}
for _, d in ipairs(NEIGHBOR_DELTAS) do
  if d.heading then HEADING_DELTA[d.heading] = d end
end

local function inspectNeighbor(delta)
  if delta.dy == 1 then return nav.inspectUp() end
  if delta.dy == -1 then return nav.inspectDown() end
  nav.face(delta.heading)
  return nav.inspectFront()
end

-- Safety cap on a single vein-chasing detour -- a huge or misidentified
-- "vein" (e.g. a whole exposed ore-heavy cave wall) shouldn't be able to
-- turn into an unbounded side quest.
local MAX_VEIN_BLOCKS = 48

-- Starting from one or more already-spotted valuable neighbors (`seeds`,
-- a list of { x, y, z } world positions, none yet mined), flood-fills
-- outward through connected valuable blocks (BFS over each mined block's
-- own 6 neighbors), digging through each via pathfind.goto()'s allowDig
-- so the move and the dig happen together. shouldStop is honored between
-- targets (stops chasing further ore, but never mid-step), since this is
-- optional extra work, same as the inter-column travel in M.run() below.
--
-- The final return to the exact position/heading the detour started
-- from is, unlike the search itself, NOT interruptible and always
-- attempted regardless of how the search ended -- like
-- returnToColumnStart() below, this is a recovery step: the caller
-- (tunnelForward, via digForward) assumes a leg step leaves the turtle
-- exactly one cell further along the leg, and a vein detour that never
-- came back would silently corrupt that assumption for everything after
-- it (the leg's own remaining steps, the 180 turn between legs, ...).
local function mineVein(seeds, shouldStop)
  local origin = nav.getPosition()
  local visited = {}
  local frontier = {}
  for _, s in ipairs(seeds) do
    frontier[#frontier + 1] = s
  end

  local mined = 0
  while #frontier > 0 and mined < MAX_VEIN_BLOCKS do
    if shouldStop and shouldStop() then break end

    local target = table.remove(frontier, 1)
    local key = target.x .. "," .. target.y .. "," .. target.z
    if not visited[key] then
      visited[key] = true
      local reached = pathfind.goto(target.x, target.y, target.z, { tolerance = 0, allowDig = true })
      if reached then
        mined = mined + 1
        for _, delta in ipairs(NEIGHBOR_DELTAS) do
          local nx, ny, nz = target.x + delta.dx, target.y + delta.dy, target.z + delta.dz
          local nkey = nx .. "," .. ny .. "," .. nz
          if not visited[nkey] then
            local seen = inspectNeighbor(delta)
            if seen.present and isValuable(seen.name) then
              frontier[#frontier + 1] = { x = nx, y = ny, z = nz }
            end
          end
        end
      end
    end
  end

  if mined > 0 then
    print(("vertical: chased a vein for %d block(s)"):format(mined))
  end

  pathfind.goto(origin.x, origin.y, origin.z, { tolerance = 0, allowDig = true })
  nav.face(origin.heading)
end

-- observant's sensing: turtle keeps facing forward (its leg heading)
-- both before and after this call. Peeks left and right, prints anything
-- notable, and -- if thorough -- returns any valuable neighbor found as
-- a mineVein() seed (world-absolute, `pos` is wherever the turtle is
-- right now). Otherwise returns an empty list.
local function scanSides(pos, thorough)
  local seeds = {}

  nav.turnLeft()
  local leftHeading = nav.getPosition().heading
  local left = nav.inspectFront()
  if left.present then print("vertical: spotted " .. left.name .. " to the left") end

  nav.turnRight(); nav.turnRight()
  local rightHeading = nav.getPosition().heading
  local right = nav.inspectFront()
  if right.present then print("vertical: spotted " .. right.name .. " to the right") end

  nav.turnLeft()

  if thorough then
    if left.present and isValuable(left.name) then
      local d = HEADING_DELTA[leftHeading]
      seeds[#seeds + 1] = { x = pos.x + d.dx, y = pos.y, z = pos.z + d.dz }
    end
    if right.present and isValuable(right.name) then
      local d = HEADING_DELTA[rightHeading]
      seeds[#seeds + 1] = { x = pos.x + d.dx, y = pos.y, z = pos.z + d.dz }
    end
  end

  return seeds
end

local function digForward(observant, thorough, shouldStop)
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detect() then
      local ok, err = nav.forward()
      if ok and observant then
        local seeds = scanSides(nav.getPosition(), thorough)
        if thorough and #seeds > 0 then
          mineVein(seeds, shouldStop)
        end
      end
      return ok, err
    end
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
local function tunnelForward(n, observant, thorough, shouldStop)
  for i = 1, n do
    if not digForward(observant, thorough, shouldStop) then return i - 1 end
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
local function digColumn(legLength, descend, observant, thorough, shouldStop)
  local legCount = 0

  while true do
    if shouldStop and shouldStop() then
      return legCount, "interrupted"
    end

    local dSteps = tunnelDown(descend)
    if dSteps < descend then return legCount, "bedrock" end

    local fSteps = tunnelForward(legLength, observant, thorough, shouldStop)
    legCount = legCount + 1
    if fSteps == 0 then return legCount, "blocked" end

    nav.turnRight(); nav.turnRight()
  end
end

-- Gets back under columnStart's (x, z) -- digging through anything in
-- the way, since most of it is already opened up by the column's own
-- legs -- then digs straight up to columnStart's y.
--
-- Real bedrock near the world floor is patchy, not a clean plane, and is
-- undiggable no matter what allowDig says -- so the direct horizontal
-- repositioning attempt (at the depth digColumn() stopped at) can fail
-- even though the same move would work a few blocks higher, above the
-- bedrock pocket. Rather than give up on the first failure, climb one
-- block and retry, repeating until it succeeds or there's nowhere higher
-- left to try (climbing all the way to columnStart.y without success
-- means something other than a shallow bedrock pocket is blocking it).
--
-- Deliberately does NOT take a shouldStop -- this runs right after
-- digColumn() stops, including when it stopped *because* a stop was
-- already requested, so passing that same shouldStop through would abort
-- this immediately and strand the turtle mid-column instead of safely
-- back at its top. This is a recovery step, not new work; it always
-- has to finish.
local function returnToColumnStart(columnStart)
  local pos = nav.getPosition()

  while true do
    local reached, info = pathfind.goto(columnStart.x, pos.y, columnStart.z, { tolerance = 0, allowDig = true })
    if reached then break end

    if pos.y >= columnStart.y then
      return false, "could not get under column start even at the top: " .. tostring(info.reason)
    end

    local climbed = tunnelUp(1)
    if climbed == 0 then
      return false, "stuck climbing to retry after: " .. tostring(info.reason)
    end
    pos = nav.getPosition()
  end

  pos = nav.getPosition()
  local needed = columnStart.y - pos.y
  local climbed = tunnelUp(needed)
  if climbed < needed then
    return false, "stuck climbing back to column start"
  end
  return true
end

-- If the inventory's full, finds a chest and empties into it, then
-- returns to columnStart. Returns true (whether or not anything actually
-- needed unloading), or false, reason if no chest could be found (or
-- tidy is off), or if the turtle couldn't get back to columnStart
-- afterward. No shouldStop here either, for the same reason as
-- returnToColumnStart above -- the trip back to columnStart is a
-- recovery step and must finish once started, not be cut short by a
-- stop request that arrived while it was full.
local function unloadIfFull(columnStart, tidy)
  if not inventory.isFull() then return true end

  if not tidy then
    return false, "inventory full (tidy disabled)"
  end

  print("vertical: inventory full, looking for a chest to unload into")
  local found, reason = chestfinder.find({})
  if not found then
    return false, "inventory full, no chest found: " .. tostring(reason)
  end

  local emptied = inventory.dropAll(found.direction)
  print(("vertical: unloaded %d slot(s) into chest at (%d, %d, %d)")
    :format(emptied, found.x, found.y, found.z))
  if inventory.isFull() then
    return false, "chest at (" .. found.x .. "," .. found.y .. "," .. found.z .. ") couldn't take everything"
  end

  local reached, info = pathfind.goto(columnStart.x, columnStart.y, columnStart.z, { tolerance = 0, allowDig = true })
  if not reached then
    return false, "could not return to column start after unloading: " .. tostring(info.reason)
  end
  return true
end

-- Job entry point (see lib/job.lua): params is { legLength, descend,
-- minFuel, columnStep, columnDY, facing, tidy, observant, thorough }, all
-- optional (see DEFAULTS). facing is a compass name ("north", "east",
-- "south", "west") -- the direction the mine advances in over time; see
-- FACINGS above. tidy/observant/thorough are the boolean modes described
-- at the top of this file. Marks home (lib/home.lua) if nothing's marked
-- yet, so the very first column's top is remembered even across a
-- mid-run reboot -- each subsequent column's own top is just tracked
-- locally, since home.lua only remembers one position and every column
-- needs its own.
function M.run(params, shouldStop)
  params = params or {}
  local legLength  = params.legLength or DEFAULTS.legLength
  local descend    = params.descend or DEFAULTS.descend
  local minFuel    = params.minFuel or DEFAULTS.minFuel
  local columnStep = params.columnStep or DEFAULTS.columnStep
  local columnDY   = params.columnDY or DEFAULTS.columnDY
  local facing     = params.facing or DEFAULTS.facing
  local tidy       = optBool(params.tidy, DEFAULTS.tidy)
  local observant  = optBool(params.observant, DEFAULTS.observant)
  local thorough   = optBool(params.thorough, DEFAULTS.thorough)

  local march = FACINGS[tostring(facing):lower()]
  if not march then
    return false, "unknown facing: " .. tostring(facing) .. " (expected north, east, south, or west)"
  end

  if not home.get() then home.mark() end
  nav.face(march.legFacing)

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

    local unloadOk, unloadErr = unloadIfFull(columnStart, tidy)
    if not unloadOk then
      print("vertical: stopping -- " .. tostring(unloadErr))
      return false, unloadErr
    end

    columnIndex = columnIndex + 1
    print(("vertical: column %d starting at (%d, %d, %d)")
      :format(columnIndex, columnStart.x, columnStart.y, columnStart.z))

    local legCount, reason = digColumn(legLength, descend, observant, thorough, shouldStop)
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
    local nextX, nextZ = columnStart.x, columnStart.z
    if march.axis == "x" then
      nextX = nextX + (march.sign * columnStep)
    else
      nextZ = nextZ + (march.sign * columnStep)
    end
    local nextY = columnStart.y + (columnDY * dySign)
    print(("vertical: moving to column %d at (%d, %d, %d)"):format(columnIndex + 1, nextX, nextY, nextZ))

    -- shouldStop here (unlike returnToColumnStart/unloadIfFull's own
    -- travel above) is safe to interrupt: this is "start of the next
    -- unit of work", not a safety step recovering from one already in
    -- progress, so it's fine for a fresh stop request to cut it short.
    local reached, info = pathfind.goto(nextX, nextY, nextZ, { tolerance = 0, allowDig = true, shouldStop = shouldStop })
    if not reached then
      if info.reason == "interrupted" then
        print("vertical: interrupted while moving to the next column")
        return true, { columns = columnIndex, position = nav.getPosition() }
      end
      print("vertical: could not reach next column -- " .. tostring(info.reason))
      return false, "could not reach next column: " .. tostring(info.reason)
    end

    columnStart = nav.getPosition()
  end

  print("vertical: interrupted before starting a new column")
  return true, { columns = columnIndex, position = nav.getPosition() }
end

return M

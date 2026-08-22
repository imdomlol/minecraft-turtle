--[[----------------------------------------------------------------------
  dom-main/mining/vertical.lua -- vertical switchback strip miner.

  Two independent directions, deliberately kept distinct since they mean
  different things and must be perpendicular to each other:
  - widthFacing: the direction the mine advances in *over time*, as it
    starts new width positions (this used to just be called `facing`).
    Compass name, default "north".
  - lengthFacing: the direction each *leg* actually digs into. Compass
    name; defaults to whichever perpendicular direction the old code
    always auto-picked (see WIDTH_FACINGS below), so an unset
    lengthFacing behaves like before. Can also be "all" -- see below.
  Marching parallel to the legs would just walk new width positions down
  the same line the legs already dug, instead of spreading into a fresh
  plane -- so widthFacing and lengthFacing must be on different axes:
  north paired with east or west is fine, north paired with south or
  north itself is rejected with a clear error.

  At each width position, digs straight down in a zigzag staircase --
  leaning on a turtle being 1 block wide/tall -- rather than a horizontal
  shaft: descend `stepDown` blocks, dig a `length`-block leg, turn 180,
  repeat, alternating direction every leg. That continues until it
  bottoms out (bedrock -- the normal end of a "pass") or a leg is
  blocked immediately (a side wall), or, if `height` is set, once that
  many blocks have been descended in this pass. It then gets back under
  the pass's own start (x, z) -- digging through anything in the way,
  since most of it is already opened up by the zigzag's own legs -- and
  climbs straight back up, rather than retracing the zigzag turn by turn.

  lengthFacing = "all" runs this twice per width position instead of
  once, in both directions along the perpendicular axis (e.g. east then
  west) -- doubling total leg coverage -- before advancing to the next
  width position, rather than alternating direction between width
  positions: both passes happen at the *same* width position back to
  back (each fully climbing back to that position's start first), so the
  only extra travel cost is paid once per width position, not per pass.

  After however many passes ran, it shifts to a new width position --
  stepping `columnStep` blocks further out along widthFacing -- the
  position's *starting height* (y) shifts by columnDY, alternating sign
  each time, so adjacent width positions' legs land at different depths
  instead of perfectly overlapping -- and starts again, until `width`
  positions have been done (default unlimited) or it's told to stop.
  columnDY only ever alternates between two fixed offsets (never drifts
  through a range), so for the best spread between adjacent width
  positions' leg depths, pick a columnDY that isn't a multiple of
  `stepDown` or exactly `stepDown / 2` -- either of those makes the two
  offsets equivalent (or identical) instead of genuinely interleaved.

  Meant to run as a lib/job.lua job (see main.lua), not called directly:
  a run long enough to be worth calling "forever" would otherwise block
  the remote console from ever reaching it again. Start/stop it with:
    dofile("/lib/job.lua").request("mine_vertical", { length = 10 })
    dofile("/lib/job.lua").stop()
  shouldStop() (passed in by lib/job.lua) is only checked once per pass
  iteration (between full down+forward+turn cycles), not between
  individual blocks -- so expect up to roughly a `length` block actions'
  worth of latency before a stop actually takes effect.

  Checks inventory after every successful forward leg step, and again
  before each pass starts (so a full inventory is caught within a single
  leg rather than potentially waiting out an entire deep pass, but a
  pass also never starts already full). If full and `tidy` (see below)
  is true, it finds a chest (see lib/chestfinder.lua -- defaults to
  searching around lib/home.lua's position), drops everything in, and
  returns to the exact position/heading it was at before continuing. If
  no chest can be found, or the one found is itself too full to take
  everything, the whole job stops -- even if this happened mid-leg, deep
  inside a pass -- rather than quietly discarding items or looping
  forever hunting for space.

  Three optional boolean modes, all default true:
  - tidy: the inventory-unloading behavior described above. tidy = false
    skips the chest hunt entirely -- a full inventory just stops the job
    with a clear reason, for when no chest is set up or you'd rather
    manage unloading yourself.
  - observant: after every successful forward leg step, AND after every
    individual block of a stepDown descent (not just once for the whole
    burst), turns to peek at the block to the left and the right before
    turning back straight (four extra turns each time) and prints
    anything it sees. Up and down get checked too on every leg step --
    but that happens regardless of observant, since it costs no extra
    turns; observant only controls the left/right peek, which does.
    observant = false also changes stepDown/columnDY's own defaults (see
    DEFAULTS above) -- with no active left/right scanning, a smaller
    stepDown (denser zigzag) and bigger columnDY stagger lean on the
    switchback's own geometry for coverage instead.
  - thorough: chases down veins of anything spotted (ore, ancient debris
    -- see isValuable() below) instead of leaving it for a neighboring
    leg to maybe stumble into later. thorough acts on whatever gets
    found *regardless of observant* -- the always-on up/down check alone
    is enough to trigger it; observant just adds more to look at. It
    doesn't separately re-inspect the block a leg is about to dig
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
local ores = dofile("/lib/ores.lua")

local M = {}

local DEFAULTS = {
  length      = 10,       -- blocks dug per forward/backward leg
  minFuel     = 500,      -- abort before starting a new pass if fuel can't be brought above this
  columnStep  = 1,        -- blocks each new width position advances, along widthFacing, from the previous one
  widthFacing = "north",  -- overall direction the mine advances in -- see WIDTH_FACINGS below
  tidy        = true,     -- auto-unload into a chest when full, instead of just stopping
  observant   = true,     -- peek left/right on every leg step and every stepDown block
  thorough    = true,     -- chase veins of anything spotted (scanUpDown always, scanLeftRight if observant)

  -- stepDown/columnDY default differently depending on observant (see
  -- M.run() below, which resolves observant first): with observant on,
  -- it's actively scanning every block already, so a bigger stepDown
  -- (fewer, larger descents) and a smaller columnDY stagger are fine.
  -- With observant off, there's no active left/right scanning at all, so
  -- a smaller stepDown (denser switchback zigzag) and a bigger columnDY
  -- stagger lean on the geometry itself for coverage instead.
  stepDownObservant   = 5,
  stepDownInattentive = 2,
  columnDYObservant   = 2,
  columnDYInattentive = 3,
}

-- params.<mode> or'ing against a default breaks for an explicit `false`
-- (false or true == true) -- this treats "not provided" (nil) as the only
-- case that falls back to the default.
local function optBool(v, default)
  if v == nil then return default end
  return v
end

-- Maps widthFacing (a compass name) to which world axis it advances
-- along and which way, plus the default lengthFacing (one perpendicular
-- direction) and the order lengthFacing = "all" tries both perpendicular
-- directions in. Legs alternate their own direction every leg anyway via
-- a 180 turn, so either perpendicular choice/order works equally well --
-- these are just fixed, deterministic picks.
local WIDTH_FACINGS = {
  north = { axis = "z", sign = -1, defaultLengthFacing = "east",  allOrder = { "east", "west" } },
  south = { axis = "z", sign = 1,  defaultLengthFacing = "east",  allOrder = { "east", "west" } },
  east  = { axis = "x", sign = 1,  defaultLengthFacing = "north", allOrder = { "north", "south" } },
  west  = { axis = "x", sign = -1, defaultLengthFacing = "north", allOrder = { "north", "south" } },
}

-- Which world axis a compass name lies on -- used to check lengthFacing
-- is perpendicular to widthFacing (see M.run() below).
local AXIS_OF = { north = "z", south = "z", east = "x", west = "x" }

-- Bounds dig retries -- see dom-main/mining/strip.lua for why this can't
-- be unbounded (CraftOS's "too long without yielding" watchdog).
local MAX_DIG_ATTEMPTS = 8

local function matchesAny(name, list)
  for _, fragment in ipairs(list) do
    if name:find(fragment, 1, true) then return true end -- plain substring, no pattern syntax
  end
  return false
end

-- "Valuable" for `thorough`'s purposes: any ore block (vanilla and
-- modded blocks alike overwhelmingly have "_ore" somewhere in the name,
-- including deepslate variants and ones with a trailing variant/suffix
-- after "_ore" itself) plus ancient debris, which doesn't follow that
-- convention at all. Deliberately broad (a plain substring match, not
-- anchored to the end of the name) rather than an exact vanilla ID list,
-- so a modded server's ores get chased too without needing an update
-- here -- a false positive (something with "_ore" in the name that
-- isn't actually ore) is an acceptable rare cost for not missing real
-- ones with a differently-placed suffix.
--
-- lib/ores.lua's EXCLUDE/INCLUDE lists let you override this without
-- touching code: EXCLUDE wins over everything (a name matching both
-- "_ore" and EXCLUDE is not valuable), INCLUDE only matters for names
-- that don't otherwise match "_ore"/"ancient_debris" at all.
local function isValuable(name)
  if not name then return false end
  if matchesAny(name, ores.EXCLUDE) then return false end
  if name:find("_ore") ~= nil or name:find("ancient_debris") ~= nil then return true end
  return matchesAny(name, ores.INCLUDE)
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
-- a list of { x, y, z, name } world positions, none yet mined), flood-
-- fills outward through connected valuable blocks (BFS over each mined
-- block's own 6 neighbors), digging through each via pathfind.goto()'s
-- allowDig so the move and the dig happen together. shouldStop is
-- honored between targets (stops chasing further ore, but never
-- mid-step), since this is optional extra work, same as the
-- inter-column travel in M.run() below.
--
-- A target pathfind.goto() can't actually reach (undiggable regardless
-- of tool -- bedrock, or a block requiring a higher-tier tool than this
-- turtle has, e.g. a modded end-game ore) has its *name* -- not just its
-- position -- added to unreachableNames, shared with scanSides() below
-- and persisting for the rest of this job run. Without that, the exact
-- same ore type gets rediscovered and re-chased from scratch by every
-- later leg step or width position that happens to graze the same
-- (often large) deposit, each attempt individually bounded but adding
-- up to a lot of wasted time against something that was never going to
-- work. One failure is enough to blacklist a name: pathfind.goto()
-- already retries a blocked step several ways (including its own escape
-- fallback) before giving up, so this isn't a one-off fluke.
--
-- The final return to the exact position/heading the detour started
-- from is, unlike the search itself, NOT interruptible and always
-- attempted regardless of how the search ended -- like
-- returnToColumnStart() below, this is a recovery step: the caller
-- (tunnelForward, via digForward) assumes a leg step leaves the turtle
-- exactly one cell further along the leg, and a vein detour that never
-- came back would silently corrupt that assumption for everything after
-- it (the leg's own remaining steps, the 180 turn between legs, ...).
local function mineVein(seeds, shouldStop, unreachableNames)
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
            if seen.present and isValuable(seen.name) and not unreachableNames[seen.name] then
              frontier[#frontier + 1] = { x = nx, y = ny, z = nz, name = seen.name }
            end
          end
        end
      elseif target.name and not unreachableNames[target.name] then
        unreachableNames[target.name] = true
        print("vertical: could not reach/dig " .. target.name .. " -- treating it as not valuable for the rest of this run")
      end
    end
  end

  if mined > 0 then
    print(("vertical: chased a vein for %d block(s)"):format(mined))
  end

  pathfind.goto(origin.x, origin.y, origin.z, { tolerance = 0, allowDig = true })
  nav.face(origin.heading)
end

-- Describes what observant's tag for a spotted block should say: blank
-- if it's not valuable, "(valuable)" if it is and thorough would chase
-- it, or "(valuable, but couldn't be mined earlier -- skipping)" if
-- it's a name already in unreachableNames (see mineVein() above).
local function valuableTag(name, unreachableNames)
  if not isValuable(name) then return "" end
  if unreachableNames[name] then return " (valuable, but couldn't be mined earlier -- skipping)" end
  return " (valuable)"
end

-- Inspects up and down -- no turning needed, so this is cheap enough to
-- run unconditionally after every leg-forward step regardless of
-- `observant` (unlike scanLeftRight below, which needs four turns).
-- Prints anything notable and -- if thorough -- returns any valuable,
-- not-already-blacklisted neighbor as a mineVein() seed (world-absolute,
-- `pos` is wherever the turtle is right now).
local function scanUpDown(pos, thorough, unreachableNames)
  local seeds = {}

  local up = nav.inspectUp()
  if up.present then
    print("vertical: spotted " .. up.name .. " above" .. valuableTag(up.name, unreachableNames))
  end
  local down = nav.inspectDown()
  if down.present then
    print("vertical: spotted " .. down.name .. " below" .. valuableTag(down.name, unreachableNames))
  end

  if thorough then
    if up.present and isValuable(up.name) and not unreachableNames[up.name] then
      seeds[#seeds + 1] = { x = pos.x, y = pos.y + 1, z = pos.z, name = up.name }
    end
    if down.present and isValuable(down.name) and not unreachableNames[down.name] then
      seeds[#seeds + 1] = { x = pos.x, y = pos.y - 1, z = pos.z, name = down.name }
    end
  end

  return seeds
end

-- observant's own sensing: turtle keeps facing the same way both before
-- and after this call. Peeks left and right (four turns), prints
-- anything notable, and -- if thorough -- returns any valuable,
-- not-already-blacklisted neighbor as a mineVein() seed (world-absolute,
-- `pos` is wherever the turtle is right now). Called both after a leg
-- step and, separately, after each individual block of a stepDown
-- descent (see digDown below) -- either way, only when observant is on,
-- since unlike scanUpDown this genuinely costs extra turns.
local function scanLeftRight(pos, thorough, unreachableNames)
  local seeds = {}

  nav.turnLeft()
  local leftHeading = nav.getPosition().heading
  local left = nav.inspectFront()
  if left.present then
    print("vertical: spotted " .. left.name .. " to the left" .. valuableTag(left.name, unreachableNames))
  end

  nav.turnRight(); nav.turnRight()
  local rightHeading = nav.getPosition().heading
  local right = nav.inspectFront()
  if right.present then
    print("vertical: spotted " .. right.name .. " to the right" .. valuableTag(right.name, unreachableNames))
  end

  nav.turnLeft()

  if thorough then
    if left.present and isValuable(left.name) and not unreachableNames[left.name] then
      local d = HEADING_DELTA[leftHeading]
      seeds[#seeds + 1] = { x = pos.x + d.dx, y = pos.y, z = pos.z + d.dz, name = left.name }
    end
    if right.present and isValuable(right.name) and not unreachableNames[right.name] then
      local d = HEADING_DELTA[rightHeading]
      seeds[#seeds + 1] = { x = pos.x + d.dx, y = pos.y, z = pos.z + d.dz, name = right.name }
    end
  end

  return seeds
end

-- Liquids (see lib/nav.lua's isLiquid()) never get dug -- there's
-- nothing to break, and a turtle can already move straight through one
-- -- so this skips straight to moving instead of wasting a dig attempt.
local function isLiquidAhead(found, data)
  return found and nav.isLiquid(data.name)
end

-- If the inventory's full, finds a chest and empties into it, then
-- returns to the exact position/heading this was called from -- NOT
-- necessarily a pass's own start; this is also called after every leg
-- step (see digForward below), not just once per pass, so a full
-- inventory gets caught within a single leg instead of potentially
-- waiting out an entire deep pass. Returns true (whether or not
-- anything actually needed unloading), or false, reason if no chest
-- could be found (or tidy is off), or if the turtle couldn't get back to
-- where it was. No shouldStop here either, for the same reason as
-- returnToColumnStart/mineVein's own return-to-origin above -- the trip
-- back is a recovery step and must finish once started, not be cut short
-- by a stop request that arrived while it was full.
local function unloadIfFull(tidy)
  if not inventory.isFull() then return true end

  if not tidy then
    return false, "inventory full (tidy disabled)"
  end

  local origin = nav.getPosition()
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

  local reached, info = pathfind.goto(origin.x, origin.y, origin.z, { tolerance = 0, allowDig = true })
  if not reached then
    return false, "could not return to (" .. origin.x .. "," .. origin.y .. "," .. origin.z
      .. ") after unloading: " .. tostring(info.reason)
  end
  nav.face(origin.heading)
  return true
end

-- Third return value (`fatal`), when present, means "stop the whole job
-- immediately, regardless of ok" -- currently only set when unloadIfFull
-- fails mid-leg (no chest found, or one that couldn't take everything).
-- The move itself already happened by that point (ok is still true), so
-- the step still counts -- but there's no point digging any further with
-- nowhere to put what comes up, and this needs to reach all the way back
-- to M.run() to stop cleanly with a clear reason, the same as the old
-- once-per-pass-boundary check already did.
-- thorough acts on whatever gets found here regardless of observant --
-- scanUpDown always runs (it's free, no turning), and scanLeftRight only
-- runs when observant is on (it costs four turns) -- but either way, any
-- valuable block either of them finds gets chased if thorough is on.
-- observant on its own is just "also look left/right too"; it doesn't
-- gate whether thorough is allowed to act.
local function digForward(observant, thorough, tidy, unreachableNames, shouldStop)
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detect() or isLiquidAhead(turtle.inspect()) then
      local ok, err = nav.forward()
      if ok then
        local unloadOk, unloadErr = unloadIfFull(tidy)
        if not unloadOk then
          return true, nil, unloadErr
        end

        local pos = nav.getPosition()
        local seeds = scanUpDown(pos, thorough, unreachableNames)
        if observant then
          local sideSeeds = scanLeftRight(pos, thorough, unreachableNames)
          for _, s in ipairs(sideSeeds) do seeds[#seeds + 1] = s end
        end
        if thorough and #seeds > 0 then
          mineVein(seeds, shouldStop, unreachableNames)
        end
      end
      return ok, err
    end
    if not turtle.dig() then turtle.attack() end
  end
  return false, "obstructed after " .. MAX_DIG_ATTEMPTS .. " dig attempts"
end

-- Same thorough-independent-of-observant principle as digForward above,
-- applied to a single block of a stepDown descent: when observant is on,
-- peeks left/right at THIS depth too (see tunnelDown below, which calls
-- this once per block descended, not once for the whole stepDown burst)
-- -- catching ore that's only exposed partway down, not just at a
-- pass's leg-boundary depths.
local function digDown(observant, thorough, unreachableNames, shouldStop)
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detectDown() or isLiquidAhead(turtle.inspectDown()) then
      local ok, err = nav.down()
      if ok and observant then
        local seeds = scanLeftRight(nav.getPosition(), thorough, unreachableNames)
        if thorough and #seeds > 0 then
          mineVein(seeds, shouldStop, unreachableNames)
        end
      end
      return ok, err
    end
    if not turtle.digDown() then turtle.attackDown() end
  end
  return false, "obstructed after " .. MAX_DIG_ATTEMPTS .. " dig attempts"
end

local function digUp()
  for _ = 1, MAX_DIG_ATTEMPTS do
    if not turtle.detectUp() or isLiquidAhead(turtle.inspectUp()) then return nav.up() end
    if not turtle.digUp() then turtle.attackUp() end
  end
  return false, "obstructed after " .. MAX_DIG_ATTEMPTS .. " dig attempts"
end

-- The turtle is 1 block wide -- unlike strip.lua's 2-tall shaft, a leg
-- only needs to clear the single cell it's moving into.
local function tunnelForward(n, observant, thorough, tidy, unreachableNames, shouldStop)
  for i = 1, n do
    local ok, _, fatal = digForward(observant, thorough, tidy, unreachableNames, shouldStop)
    if fatal then return i, fatal end
    if not ok then return i - 1 end
  end
  return n
end

local function tunnelDown(n, observant, thorough, unreachableNames, shouldStop)
  for i = 1, n do
    if not digDown(observant, thorough, unreachableNames, shouldStop) then return i - 1 end
  end
  return n
end

local function tunnelUp(n)
  for i = 1, n do
    if not digUp() then return i - 1 end
  end
  return n
end

-- Digs one switchback pass (a single zigzag descent at one width
-- position, in one length-facing direction). `stepDown` is how many
-- blocks it descends per leg step. `height` (optional) caps how many
-- blocks this pass descends in total before stopping on its own, even
-- if bedrock is still further down -- nil means no cap (dig to bedrock,
-- the old unconditional behavior). Returns legCount (how many forward
-- legs were attempted), reason: "bedrock" (can't dig down any further --
-- the normal unbounded end of a pass), "height limit" (hit the `height`
-- cap exactly, on a clean leg boundary), "blocked" (a leg was obstructed
-- immediately -- a side wall, not the bottom), "interrupted"
-- (shouldStop() cut it short), or "fatal" (a mid-leg unloadIfFull()
-- failed -- see digForward/tunnelForward above; the whole job needs to
-- stop, not just this pass) -- and a third value carrying the fatal
-- error string, only present when reason == "fatal".
local function digColumn(length, stepDown, height, observant, thorough, tidy, unreachableNames, shouldStop)
  local legCount = 0
  local depth = 0

  while true do
    if shouldStop and shouldStop() then
      return legCount, "interrupted"
    end

    local step = stepDown
    if height then
      local remaining = height - depth
      if remaining <= 0 then return legCount, "height limit" end
      step = math.min(stepDown, remaining)
    end

    local dSteps = tunnelDown(step, observant, thorough, unreachableNames, shouldStop)
    depth = depth + dSteps
    if dSteps < step then return legCount, "bedrock" end

    local fSteps, fatal = tunnelForward(length, observant, thorough, tidy, unreachableNames, shouldStop)
    legCount = legCount + 1
    if fatal then return legCount, "fatal", fatal end
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

-- Job entry point (see lib/job.lua): params is { length, stepDown,
-- height, minFuel, columnStep, columnDY, widthFacing, lengthFacing,
-- width, tidy, observant, thorough }, all optional (see DEFAULTS).
-- widthFacing/lengthFacing are compass names ("north", "east", "south",
-- "west"); lengthFacing also accepts "all". height caps blocks descended
-- per pass (nil = dig to bedrock). width caps how many width positions
-- to do (nil = unlimited). tidy/observant/thorough are the boolean modes
-- described at the top of this file. Marks home (lib/home.lua) if
-- nothing's marked yet, so the very first width position's top is
-- remembered even across a mid-run reboot -- each subsequent position's
-- own top is just tracked locally, since home.lua only remembers one
-- position and every width position needs its own.
function M.run(params, shouldStop)
  params = params or {}
  local length      = params.length or DEFAULTS.length
  local height      = params.height -- nil = no cap, dig to bedrock
  local minFuel     = params.minFuel or DEFAULTS.minFuel
  local columnStep  = params.columnStep or DEFAULTS.columnStep
  local widthFacing = params.widthFacing or DEFAULTS.widthFacing
  local widthCap    = params.width -- nil = unlimited
  local tidy        = optBool(params.tidy, DEFAULTS.tidy)
  local observant   = optBool(params.observant, DEFAULTS.observant)
  local thorough    = optBool(params.thorough, DEFAULTS.thorough)

  -- stepDown/columnDY's own defaults depend on observant (see DEFAULTS
  -- above) -- only applies when neither is given explicitly; an explicit
  -- value always wins regardless of observant.
  local stepDown = params.stepDown
    or (observant and DEFAULTS.stepDownObservant or DEFAULTS.stepDownInattentive)
  local columnDY = params.columnDY
    or (observant and DEFAULTS.columnDYObservant or DEFAULTS.columnDYInattentive)

  local width = WIDTH_FACINGS[tostring(widthFacing):lower()]
  if not width then
    return false, "unknown widthFacing: " .. tostring(widthFacing) .. " (expected north, east, south, or west)"
  end

  -- Resolve lengthFacing into an ordered list of 1 (a specific
  -- direction) or 2 ("all") starting directions each width position
  -- runs a full pass in.
  local lengthDirections
  if params.lengthFacing == nil then
    lengthDirections = { width.defaultLengthFacing }
  elseif tostring(params.lengthFacing):lower() == "all" then
    lengthDirections = width.allOrder
  else
    local lf = tostring(params.lengthFacing):lower()
    if not AXIS_OF[lf] then
      return false, "unknown lengthFacing: " .. tostring(params.lengthFacing)
        .. ' (expected north, east, south, west, or "all")'
    end
    if AXIS_OF[lf] == width.axis then
      return false, "lengthFacing (" .. lf .. ") must be perpendicular to widthFacing ("
        .. tostring(widthFacing):lower() .. "), not on the same axis"
    end
    lengthDirections = { lf }
  end

  if not home.get() then home.mark() end

  local columnStart = nav.getPosition()
  local dySign = 1
  local widthIndex = 0
  -- Block names thorough has learned it can't actually mine (undiggable
  -- regardless of tool tier), so it stops re-chasing the same ore type
  -- from scratch every time a later leg step or width position grazes
  -- the same deposit again -- see mineVein() above. Persists for this
  -- whole run; starts fresh next time the job starts.
  local unreachableNames = {}

  while not (shouldStop and shouldStop()) do
    widthIndex = widthIndex + 1
    local interrupted = false

    for _, dir in ipairs(lengthDirections) do
      local fuel = turtle.getFuelLevel()
      if fuel ~= "unlimited" and fuel < minFuel then
        turtle.refuel()
        fuel = turtle.getFuelLevel()
        if fuel ~= "unlimited" and fuel < minFuel then
          print(("vertical: stopping -- fuel %s below minimum %d"):format(tostring(fuel), minFuel))
          return false, "insufficient fuel"
        end
      end

      local unloadOk, unloadErr = unloadIfFull(tidy)
      if not unloadOk then
        print("vertical: stopping -- " .. tostring(unloadErr))
        return false, unloadErr
      end

      nav.face(dir)
      print(("vertical: width %d, pass facing %s starting at (%d, %d, %d)")
        :format(widthIndex, dir, columnStart.x, columnStart.y, columnStart.z))

      local legCount, reason, fatal = digColumn(length, stepDown, height, observant, thorough, tidy, unreachableNames, shouldStop)
      print(("vertical: width %d pass done -- %d legs (%s), climbing back to start")
        :format(widthIndex, legCount, reason))

      local backOk, backErr = returnToColumnStart(columnStart)
      if not backOk then
        print("vertical: could not return to width position's start -- " .. tostring(backErr))
        return false, "could not return to width position's start: " .. tostring(backErr)
      end

      if reason == "fatal" then
        print("vertical: stopping -- " .. tostring(fatal))
        return false, fatal
      end

      if reason == "interrupted" then
        interrupted = true
        break
      end
    end

    if interrupted then
      print("vertical: interrupted, stopped at width position " .. widthIndex .. "'s start")
      return true, { width = widthIndex, position = nav.getPosition() }
    end

    if widthCap and widthIndex >= widthCap then
      print("vertical: reached width limit (" .. widthCap .. "), stopping")
      return true, { width = widthIndex, position = nav.getPosition() }
    end

    dySign = -dySign
    local nextX, nextZ = columnStart.x, columnStart.z
    if width.axis == "x" then
      nextX = nextX + (width.sign * columnStep)
    else
      nextZ = nextZ + (width.sign * columnStep)
    end
    local nextY = columnStart.y + (columnDY * dySign)
    print(("vertical: moving to width position %d at (%d, %d, %d)"):format(widthIndex + 1, nextX, nextY, nextZ))

    -- shouldStop here (unlike returnToColumnStart/unloadIfFull's own
    -- travel above) is safe to interrupt: this is "start of the next
    -- unit of work", not a safety step recovering from one already in
    -- progress, so it's fine for a fresh stop request to cut it short.
    local reached, info = pathfind.goto(nextX, nextY, nextZ, { tolerance = 0, allowDig = true, shouldStop = shouldStop })
    if not reached then
      if info.reason == "interrupted" then
        print("vertical: interrupted while moving to the next width position")
        return true, { width = widthIndex, position = nav.getPosition() }
      end
      print("vertical: could not reach next width position -- " .. tostring(info.reason))
      return false, "could not reach next width position: " .. tostring(info.reason)
    end

    columnStart = nav.getPosition()
  end

  print("vertical: interrupted before starting a new width position")
  return true, { width = widthIndex, position = nav.getPosition() }
end

return M

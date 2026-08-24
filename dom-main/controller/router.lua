--[[----------------------------------------------------------------------
  dom-main/controller/router.lua -- computes a long-distance route between
  two points using this controller's compiled world map (worldstore.lua),
  something no single turtle has any way to do on its own (it only ever
  sees the one block immediately in front/above/below it -- see
  lib/pathfind.lua's own header comment).

  M.findRoute(fromPos, toPos) runs a bounded A* over the 6-directional
  movement grid (matching how a turtle actually moves -- see
  dom-main/mining/vertical.lua's own NEIGHBOR_DELTAS for the same shape)
  and returns a SIMPLIFIED waypoint list: one point per straight-line run,
  not one per cell, since lib/pathfind.lua's own greedy stepper is
  perfectly capable of walking (and reacting to whatever's actually
  there, digging through it if needed) a straight hop between two nearby
  waypoints on its own -- see lib/routing.lua, the turtle-side module
  that requests a route and walks it this way.

  Honest limitation: worldstore.lua only ever records a cell a turtle has
  actually SEEN SOMETHING SOLID in (lib/worldmap.lua's M.install() only
  hooks the found=true case) -- open air a turtle has flown straight
  through is never recorded as "confirmed open", it just stays
  indistinguishable from "never observed at all". So this can't (yet)
  prefer routes that hug previously-traveled, confirmed-safe territory
  the way a more complete map would -- what it CAN do today is route
  AROUND whatever solid terrain the fleet has collectively already
  observed, which is still real value a single turtle's local view can
  never have. Recording confirmed-open cells too would be a natural
  follow-up, not a rewrite of this file.

  Cost model per step, using lib/nav.lua's own pure (no `turtle` API
  needed, safe to call from a controller -- same reasoning as
  lib/fuel.lua's M.travelCost()) name classifiers:
    - a chest or ComputerCraft block -- never routed through, exactly
      like lib/pathfind.lua's own "safe" dig mode refuses to destroy one
      automatically.
    - a known liquid, or a cell never observed at all -- cost 1 (no
      digging expected).
    - any other known (solid) block -- cost DIG_COST, more expensive but
      still routable if it's genuinely the best option, reflecting real
      dig time instead of treating "the map has seen a block here" as an
      absolute wall.

  Bounded two ways, so a query never risks CraftOS's "too long without
  yielding" watchdog or an unbounded search over a huge, mostly-unknown
  world: a search-space bounding box around the straight line between
  the two points (padded, not a tight tube), and a hard cap on how many
  nodes get expanded, yielding (sleep(0)) periodically during a long
  search. Giving up either way returns nil, reason -- lib/routing.lua
  falls back to a direct lib/pathfind.lua trip when that happens, so a
  routing failure is never worse than not having asked for a route at all.

  M.findRoute() itself is a pure, synchronous computation -- everything
  about NOT letting one turtle's route request hog this whole computer
  lives in M.enqueue()/M.run() below instead. A rednet message handler
  (dom-main/controller/roster.lua's M.handleMessage()) runs directly
  inside dom-main/controller/fleet_listener.lua's single receive loop --
  calling M.findRoute() there directly would mean a slow search blocks
  that SAME loop from receiving anything else (a different turtle's
  heartbeat, an operator's proxied command reply, another route
  request) for as long as the search runs, periodic yields or not,
  since CraftOS's cooperative scheduler only ever runs one coroutine at
  a time. M.enqueue() (called from there instead) just appends and
  returns immediately; M.run() -- its own top-level coroutine, alongside
  fleet_listener.run/blockSync.run/scheduler.run/remote.run in
  dom-main/controller/controller_main.lua -- drains that queue one
  request at a time. A second turtle's request while one is already
  being computed simply waits its turn in the queue, exactly as it
  should; it never contends for the same slice of controller time as
  fleet_listener's own receive loop.
------------------------------------------------------------------------]]

if _G.__ROUTER_MODULE then return _G.__ROUTER_MODULE end

local nav = dofile("/lib/nav.lua") -- ONLY its pure isLiquid/isChest/isComputerCraftBlock helpers -- never position/movement, which need the turtle API this controller doesn't have
local worldstore = dofile("/dom-main/controller/worldstore.lua")
local PROTOCOL = dofile("/lib/fleet.lua").PROTOCOL

local M = {}

local DIG_COST               = 4    -- vs cost 1 for open/unknown -- see this file's own header comment
local MAX_EXPANDED_NODES     = 3000
local YIELD_EVERY_N_EXPANDED = 100
local MIN_BOUNDING_PADDING   = 16
local QUEUE_POLL_INTERVAL    = 0.5  -- seconds between checks when the queue is empty

local NEIGHBOR_DELTAS = {
  { dx = 1,  dy = 0,  dz = 0  }, { dx = -1, dy = 0,  dz = 0  },
  { dx = 0,  dy = 0,  dz = 1  }, { dx = 0,  dy = 0,  dz = -1 },
  { dx = 0,  dy = 1,  dz = 0  }, { dx = 0,  dy = -1, dz = 0  },
}

local function key(x, y, z)
  return x .. "," .. y .. "," .. z
end

local function heuristic(x, y, z, gx, gy, gz)
  return math.abs(gx - x) + math.abs(gy - y) + math.abs(gz - z)
end

-- Array-based binary min-heap, keyed by each entry's own `.f` field --
-- Lua has no built-in priority queue, and a linear "find the smallest"
-- scan every pop would turn MAX_EXPANDED_NODES into a quadratic-time
-- search instead of the roughly n*log(n) A* is supposed to cost.
local function heapPush(heap, item)
  heap[#heap + 1] = item
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent].f <= heap[i].f then break end
    heap[parent], heap[i] = heap[i], heap[parent]
    i = parent
  end
end

local function heapPop(heap)
  local top = heap[1]
  local last = table.remove(heap)
  if #heap > 0 then
    heap[1] = last
    local i = 1
    while true do
      local l, r, smallest = i * 2, i * 2 + 1, i
      if l <= #heap and heap[l].f < heap[smallest].f then smallest = l end
      if r <= #heap and heap[r].f < heap[smallest].f then smallest = r end
      if smallest == i then break end
      heap[i], heap[smallest] = heap[smallest], heap[i]
      i = smallest
    end
  end
  return top
end

-- Cost of moving INTO (x, y, z) -- nil (blocked) for a chest/ComputerCraft
-- block, otherwise 1 (open or never-observed) or DIG_COST (any other
-- known block) -- see this file's own header comment.
local function stepCost(x, y, z)
  local name = worldstore.query(x, y, z)
  if name == nil then return 1 end
  if nav.isChest(name) or nav.isComputerCraftBlock(name) then return nil end
  if nav.isLiquid(name) then return 1 end
  return DIG_COST
end

-- Collapses a cell-by-cell path (start EXCLUDED, goal included) into one
-- waypoint per straight-line run -- lib/pathfind.lua's own greedy stepper
-- covers everything in between two waypoints on its own, so there's no
-- reason to ship (or have the turtle separately request-and-arrive-at)
-- every single intermediate cell.
local function simplify(path)
  local waypoints = {}
  local dirX, dirY, dirZ = nil, nil, nil
  for i = 2, #path do
    local dx, dy, dz = path[i].x - path[i - 1].x, path[i].y - path[i - 1].y, path[i].z - path[i - 1].z
    if dx ~= dirX or dy ~= dirY or dz ~= dirZ then
      if dirX ~= nil then waypoints[#waypoints + 1] = path[i - 1] end
      dirX, dirY, dirZ = dx, dy, dz
    end
  end
  waypoints[#waypoints + 1] = path[#path]
  return waypoints
end

-- Bounded A* from fromPos to toPos ({x, y, z} each), stopping once
-- within `tolerance` blocks of toPos rather than requiring the exact
-- cell -- matching lib/pathfind.lua's own opts.tolerance, and necessary
-- here for the same reason it's necessary there: the great majority of
-- long trips in this codebase target a chest or another turtle, both
-- solid/hard-blocked cells (M.findRoute() itself refuses to route INTO
-- one -- see stepCost() above) that are only ever approached, never
-- entered, with tolerance=1. On an integer grid, Manhattan distance <= 1
-- means exactly "at the target or one of its 6 orthogonal neighbors" --
-- the same set lib/pathfind.lua's Euclidean tolerance check resolves to
-- for an integer target, so the two stay consistent with each other.
-- Returns a simplified waypoint list (see simplify() above; {} if
-- fromPos is already within tolerance of toPos) on success, or nil,
-- reason ("search exhausted (N nodes)" or "no route found within the
-- search area") on failure.
function M.findRoute(fromPos, toPos, tolerance)
  tolerance = tolerance or 0
  local sx, sy, sz = fromPos.x, fromPos.y, fromPos.z
  local gx, gy, gz = toPos.x, toPos.y, toPos.z
  if heuristic(sx, sy, sz, gx, gy, gz) <= tolerance then return {} end

  local manhattan = heuristic(sx, sy, sz, gx, gy, gz)
  local pad = math.max(MIN_BOUNDING_PADDING, math.floor(manhattan / 2))
  local minX, maxX = math.min(sx, gx) - pad, math.max(sx, gx) + pad
  local minY, maxY = math.min(sy, gy) - pad, math.max(sy, gy) + pad
  local minZ, maxZ = math.min(sz, gz) - pad, math.max(sz, gz) + pad

  -- visited[key] = { x, y, z, g, parentKey } -- both the running best cost
  -- to reach a cell AND (once popped) confirmation it's been finalized.
  local visited = { [key(sx, sy, sz)] = { x = sx, y = sy, z = sz, g = 0, parentKey = nil } }
  local closed = {}
  local heap = {}
  heapPush(heap, { x = sx, y = sy, z = sz, g = 0, f = heuristic(sx, sy, sz, gx, gy, gz) })

  local expanded = 0
  while #heap > 0 do
    local current = heapPop(heap)
    local ck = key(current.x, current.y, current.z)
    if not closed[ck] then
      closed[ck] = true
      expanded = expanded + 1
      if expanded > MAX_EXPANDED_NODES then
        return nil, "search exhausted (" .. MAX_EXPANDED_NODES .. " nodes)"
      end
      if expanded % YIELD_EVERY_N_EXPANDED == 0 then sleep(0) end

      if heuristic(current.x, current.y, current.z, gx, gy, gz) <= tolerance then
        local path = {}
        local k = ck
        while visited[k].parentKey ~= nil do
          local v = visited[k]
          path[#path + 1] = { x = v.x, y = v.y, z = v.z }
          k = v.parentKey
        end
        -- path is goal..start (excluding start) -- reverse to start..goal.
        local ordered = {}
        for i = #path, 1, -1 do ordered[#ordered + 1] = path[i] end
        return simplify(ordered)
      end

      for _, d in ipairs(NEIGHBOR_DELTAS) do
        local nx, ny, nz = current.x + d.dx, current.y + d.dy, current.z + d.dz
        if nx >= minX and nx <= maxX and ny >= minY and ny <= maxY and nz >= minZ and nz <= maxZ then
          local nk = key(nx, ny, nz)
          if not closed[nk] then
            local cost = stepCost(nx, ny, nz)
            if cost then
              local g = current.g + cost
              local existing = visited[nk]
              if not existing or g < existing.g then
                visited[nk] = { x = nx, y = ny, z = nz, g = g, parentKey = ck }
                heapPush(heap, { x = nx, y = ny, z = nz, g = g, f = g + heuristic(nx, ny, nz, gx, gy, gz) })
              end
            end
          end
        end
      end
    end
  end

  return nil, "no route found within the search area"
end

-- FIFO of { senderId, requestId, from, to, tolerance } -- see this
-- file's own header comment for why requests are queued and drained by
-- M.run()'s own coroutine instead of computed inline wherever a
-- route_request message is received.
local queue = {}

-- Called from dom-main/controller/roster.lua's M.handleMessage() --
-- must stay fast/non-blocking, since that runs directly inside
-- dom-main/controller/fleet_listener.lua's receive loop.
function M.enqueue(senderId, requestId, fromPos, toPos, tolerance)
  queue[#queue + 1] = { senderId = senderId, requestId = requestId, from = fromPos, to = toPos, tolerance = tolerance }
end

-- Exposed for tests -- how many route requests are waiting their turn.
function M.queueLength()
  return #queue
end

-- Pops and answers exactly one queued request, if there is one -- pulled
-- out of M.run()'s own loop below so a test can drive it directly
-- without needing to run (or fake stepping through) an infinite loop.
-- Returns true if a request was processed, false if the queue was empty.
function M.processOne()
  if #queue == 0 then return false end
  local req = table.remove(queue, 1)
  local waypoints, reason = M.findRoute(req.from, req.to, req.tolerance)
  rednet.send(req.senderId,
    { type = "route", request_id = req.requestId, waypoints = waypoints, reason = reason }, PROTOCOL)
  return true
end

-- Blocks forever, computing and replying to one queued route request at
-- a time. Meant to run as its own top-level coroutine (see
-- dom-main/controller/controller_main.lua's parallel.waitForAny) -- kept
-- entirely separate from fleet_listener.lua's own receive loop so a slow
-- search never delays receiving/handling anything else this controller
-- needs to do.
function M.run()
  while true do
    if not M.processOne() then
      sleep(QUEUE_POLL_INTERVAL)
    end
  end
end

_G.__ROUTER_MODULE = M
return M

--[[----------------------------------------------------------------------
  lib/routing.lua -- drop-in wrapper around lib/pathfind.lua's M.goto for
  a LONG trip: asks the fleet controller for a route computed against its
  compiled world map (dom-main/controller/router.lua) first, walks the
  waypoints it comes back with (each hop still via lib/pathfind.lua's own
  greedy stepper, which reacts to whatever's actually there -- the
  controller's map can be stale), and falls back to a plain, direct
  lib/pathfind.lua trip whenever there's no controller, no route, or a
  waypoint hop itself fails partway through.

  A short trip tries lib/pathfind.lua first and only asks the controller
  for a route if that local attempt fails. A long trip asks the
  controller first -- see LONG_TRIP_THRESHOLD. This is deliberately its
  own file, not an addition to lib/pathfind.lua itself: pathfind.lua
  stays a purely local, controller-agnostic stepper (useful even on a
  turtle with no controller at all), and "ask for a long-distance route"
  is a separate, reusable capability any future feature can pull in
  without depending on pathfind.lua's internals.

  Same call shape and return value as lib/pathfind.lua's M.goto(x, y, z,
  opts) -- opts.longTripThreshold overrides LONG_TRIP_THRESHOLD,
  opts.routeTimeout overrides ROUTE_TIMEOUT, everything else (tolerance,
  allowDig, shouldStop) passes straight through to whichever
  lib/pathfind.lua call actually ends up doing the walking.
------------------------------------------------------------------------]]

if _G.__ROUTING_MODULE then return _G.__ROUTING_MODULE end

local nav = dofile("/lib/nav.lua")
local pathfind = dofile("/lib/pathfind.lua")
local fleet = dofile("/lib/fleet.lua")

local M = {}

local LONG_TRIP_THRESHOLD = 10  -- blocks (Manhattan) -- below this, just call lib/pathfind.lua directly
local ROUTE_TIMEOUT        = 15 -- seconds to wait for the controller's reply before falling back

local function manhattan(a, b)
  return math.abs(b.x - a.x) + math.abs(b.y - a.y) + math.abs(b.z - a.z)
end

local function nextRequestId()
  return os.getComputerID() .. "-" .. os.epoch("utc") .. "-" .. tostring(math.random(1, 1000000))
end

-- Sends a route_request and waits (bounded) for the matching reply,
-- ignoring anything else seen along the way -- rednet.receive() wakes
-- every coroutine parked on this protocol (see this codebase's other
-- request/reply pairs, e.g. dom-main/controller/roster.lua's M.proxy()),
-- so lib/fleet.lua's own listenLoop independently receives and correctly
-- handles anything that isn't our reply; this loop just needs to not
-- mistake one of those for it. Returns waypoints (possibly {}), or nil,
-- reason (including "no controller"/"timeout") if none came back.
local function requestRoute(controllerId, fromPos, toPos, tolerance, timeoutSeconds)
  if not rednet or not controllerId then return nil, "no controller" end

  local requestId = nextRequestId()
  rednet.send(controllerId, {
    type = "route_request", request_id = requestId, from = fromPos, to = toPos, tolerance = tolerance,
  }, fleet.PROTOCOL)

  local deadline = os.clock() + timeoutSeconds
  while true do
    local remaining = deadline - os.clock()
    if remaining <= 0 then return nil, "timeout waiting for a route" end
    local senderId, message = rednet.receive(fleet.PROTOCOL, remaining)
    if senderId == controllerId and type(message) == "table"
        and message.type == "route" and message.request_id == requestId then
      if message.waypoints then return message.waypoints end
      return nil, message.reason or "controller found no route"
    end
    -- Not our reply -- loop again with whatever time's left; lib/fleet.lua's
    -- own listenLoop sees this same message independently and handles it.
  end
end

local function followControllerRoute(from, target, opts)
  local controllerId = fleet.getControllerId()
  local waypoints, reason = requestRoute(controllerId, from, target, opts.tolerance or 0, opts.routeTimeout or ROUTE_TIMEOUT)
  if not waypoints then return nil, reason end
  if #waypoints == 0 then
    return pathfind.goto(target.x, target.y, target.z, opts)
  end

  print(("routing: got a %d-waypoint route, walking it"):format(#waypoints))
  local ok, info
  for i, wp in ipairs(waypoints) do
    ok, info = pathfind.goto(wp.x, wp.y, wp.z, {
      tolerance = 0, allowDig = opts.allowDig, shouldStop = opts.shouldStop,
    })
    if not ok then
      if info.reason == "interrupted" then return ok, info end
      print("routing: waypoint " .. i .. "/" .. #waypoints .. " failed (" .. tostring(info.reason)
        .. ") -- falling back to a direct trip for the rest")
      return pathfind.goto(target.x, target.y, target.z, opts)
    end
  end

  -- The route's own last waypoint already lands within opts.tolerance of
  -- the real target (dom-main/controller/router.lua's own goal check
  -- uses the same tolerance) -- one final direct call closes any gap
  -- pathfind.lua's own tolerance handling still needs to account for,
  -- and is a no-op (immediate "arrived") in the normal case.
  return pathfind.goto(target.x, target.y, target.z, opts)
end

-- Same signature/return shape as lib/pathfind.lua's M.goto.
function M.goto(x, y, z, opts)
  opts = opts or {}
  local target = { x = x, y = y, z = z }
  local from = nav.getPosition()

  if manhattan(from, target) < (opts.longTripThreshold or LONG_TRIP_THRESHOLD) then
    local ok, info = pathfind.goto(x, y, z, opts)
    if ok or (info and info.reason == "interrupted") then return ok, info end

    print("routing: local pathfind failed (" .. tostring(info and info.reason)
      .. ") -- trying controller route")
    local routeOk, routeInfo = followControllerRoute(nav.getPosition(), target, opts)
    if routeOk ~= nil then return routeOk, routeInfo end
    print("routing: no controller route available (" .. tostring(routeInfo)
      .. ") -- keeping local pathfind failure")
    return ok, info
  end

  local routeOk, routeInfo = followControllerRoute(from, target, opts)
  if routeOk ~= nil then return routeOk, routeInfo end

  -- No controller or no route: never worse than before, just take the
  -- direct local trip.
  print("routing: no controller route available (" .. tostring(routeInfo)
    .. ") -- using direct pathfind")
  return pathfind.goto(x, y, z, opts)
end

_G.__ROUTING_MODULE = M
return M

--[[----------------------------------------------------------------------
  dom-main/controller/controller_main.lua -- controller entry point,
  dispatched to by main.lua on any device with no `turtle` API (i.e. a
  plain Computer, not an actual turtle).

  Runs lib/remote.lua exactly as a turtle used to -- this controller is
  now the only thing in its dimension polling server/relay.py -- alongside
  dom-main/controller/fleet_listener.lua, which listens for the turtles
  in this dimension over rednet and lets an operator's relay-issued
  commands reach them (see dom-main/controller/roster.lua's M.proxy()),
  dom-main/controller/block_sync.lua, which pulls buffered block
  observations from turtles into dom-main/controller/worldstore.lua,
  dom-main/controller/scheduler.lua, the autopilot that keeps turtles
  working (or gets them back to it) whenever dom-main/controller/mode.lua
  allows, dom-main/controller/router.lua, which computes long-
  distance A* routes for turtles that ask (dom-main/controller/roster.lua
  just enqueues a request -- router.run() is its own coroutine
  specifically so a slow search never delays fleet_listener.lua's
  receive loop from handling anything else), and
  dom-main/controller/gpshost.lua, which lets this controller double as
  one of the (at least 4, non-coplanar) real-world anchor points
  CC:Tweaked's own gps.locate() needs, once configured via
  server/turtlectl.py's `gpshost` shortcut.
------------------------------------------------------------------------]]

local remote = dofile("/lib/remote.lua")
local fleetListener = dofile("/dom-main/controller/fleet_listener.lua")
local blockSync = dofile("/dom-main/controller/block_sync.lua")
local scheduler = dofile("/dom-main/controller/scheduler.lua")
local router = dofile("/dom-main/controller/router.lua")
local gpshost = dofile("/dom-main/controller/gpshost.lua")

parallel.waitForAny(remote.run, fleetListener.run, blockSync.run, scheduler.run, router.run, gpshost.run)

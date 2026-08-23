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
  observations from turtles into dom-main/controller/worldstore.lua, and
  dom-main/controller/scheduler.lua, the autopilot that keeps turtles
  working (or gets them back to it) whenever dom-main/controller/mode.lua
  allows.
------------------------------------------------------------------------]]

local remote = dofile("/lib/remote.lua")
local fleetListener = dofile("/dom-main/controller/fleet_listener.lua")
local blockSync = dofile("/dom-main/controller/block_sync.lua")
local scheduler = dofile("/dom-main/controller/scheduler.lua")

parallel.waitForAny(remote.run, fleetListener.run, blockSync.run, scheduler.run)

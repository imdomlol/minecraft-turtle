--[[----------------------------------------------------------------------
  dom-main/controller/controller_main.lua -- controller entry point,
  dispatched to by main.lua on any device with no `turtle` API (i.e. a
  plain Computer, not an actual turtle).

  Runs lib/remote.lua exactly as a turtle used to -- this controller is
  now the only thing in its dimension polling server/relay.py -- alongside
  dom-main/controller/fleet_listener.lua, which listens for the turtles
  in this dimension over rednet and lets an operator's relay-issued
  commands reach them (see dom-main/controller/roster.lua's M.proxy()).

  The autopilot scheduler (dom-main/controller/scheduler.lua) is a later
  addition -- not wired in yet.
------------------------------------------------------------------------]]

local remote = dofile("/lib/remote.lua")
local fleetListener = dofile("/dom-main/controller/fleet_listener.lua")

parallel.waitForAny(remote.run, fleetListener.run)

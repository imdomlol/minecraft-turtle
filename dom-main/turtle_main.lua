--[[----------------------------------------------------------------------
  dom-main/turtle_main.lua -- turtle entry point, dispatched to by main.lua
  after every OTA update (only when this device has a `turtle` API, i.e.
  it's an actual turtle and not a controller computer -- see main.lua).

  Starts the fleet listener (lib/fleet.lua) alongside the background job
  runner (lib/job.lua) so this turtle can run a long "day job" (mining,
  etc.) while still answering its controller -- a job started via a
  blocking exec command would otherwise starve the listener of ever
  hearing a "stop" command. Every known job needs registering here before
  job.run() starts, so the controller can request it later by name.
------------------------------------------------------------------------]]

local fleet = dofile("/lib/fleet.lua")
local job = dofile("/lib/job.lua")

job.register("mine_vertical", dofile("/dom-main/mining/vertical.lua").run)

parallel.waitForAny(fleet.run, job.run)

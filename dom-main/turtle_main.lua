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

  Also handles a job left mid-run by an unplanned interruption (crash,
  chunk unload, power loss) -- see lib/job.lua's M.checkpoint()/
  M.loadCheckpoint() and dom-main/mining/vertical.lua's own resume
  handling. Checkpoints are deliberately NOT auto-resumed here: only the
  controller knows whether autopilot is enabled and whether the saved
  work still belongs to the active worksite. A turtle booting by itself
  should come up idle and wait for controller policy.
------------------------------------------------------------------------]]

local fleet = dofile("/lib/fleet.lua")
local job = dofile("/lib/job.lua")
local homelink = dofile("/lib/homelink.lua")

job.register("mine_vertical", dofile("/dom-main/mining/vertical.lua").run)

local recoveredHomeLink, homeLinkInfo = homelink.recover()
if recoveredHomeLink then
  print("homelink: " .. tostring(homeLinkInfo))
else
  print("homelink: unavailable (" .. tostring(homeLinkInfo) .. ") -- worksite storage fallback remains available")
end

local saved = job.loadCheckpoint()
if saved and job.hasJob(saved.name) then
  print("job: found " .. saved.name .. " checkpoint -- waiting for controller validation before resuming")
elseif saved then
  print("job: found a checkpoint for unknown job \"" .. tostring(saved.name) .. "\" -- discarding it")
  job.clearCheckpoint()
end

parallel.waitForAny(fleet.run, job.run)

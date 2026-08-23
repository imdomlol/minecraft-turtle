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

  Also resumes a job left mid-run by an unplanned interruption (crash,
  chunk unload, power loss) -- see lib/job.lua's M.checkpoint()/
  M.loadCheckpoint() and dom-main/mining/vertical.lua's own resume
  handling. A checkpoint only ever survives to here when the previous run
  never reached the point where job.lua clears it, so finding one means
  exactly that: this boot follows something that didn't shut down
  cleanly.
------------------------------------------------------------------------]]

local fleet = dofile("/lib/fleet.lua")
local job = dofile("/lib/job.lua")

job.register("mine_vertical", dofile("/dom-main/mining/vertical.lua").run)

local saved = job.loadCheckpoint()
if saved and job.hasJob(saved.name) then
  print("job: resuming " .. saved.name .. " from a checkpoint (previous run didn't exit cleanly)")
  saved.params.__resume = saved.checkpoint
  job.request(saved.name, saved.params)
elseif saved then
  print("job: found a checkpoint for unknown job \"" .. tostring(saved.name) .. "\" -- discarding it")
  job.clearCheckpoint()
end

parallel.waitForAny(fleet.run, job.run)

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
local nav = dofile("/lib/nav.lua")
local vertical = dofile("/dom-main/mining/vertical.lua")

job.register("mine_vertical", vertical.run)

job.register("goto_then_mine", function(params, shouldStop)
  params = params or {}
  local routing = dofile("/lib/routing.lua")
  local reached, info = routing.goto(params.x, params.y, params.z, {
    tolerance = params.tolerance or 0,
    allowDig = params.allowDig,
    shouldStop = shouldStop,
  })
  if not reached then
    return false, "could not reach assigned cell: " .. tostring(info and info.reason)
  end
  if shouldStop() then
    return true, "interrupted before mining"
  end
  job.request("mine_vertical", params.jobParams or {})
  return true, "arrived; queued mine_vertical"
end)

-- Requested by dom-main/controller/scheduler.lua's M.checkHomeLink()
-- when this turtle's own /state/homelink.state has been stuck "placed"
-- too long -- same cooperative job.request() interrupt goto/stop
-- already use, so this can never race whatever job (mining, most
-- likely) happens to be running when it arrives. Just runs
-- lib/homelink.lua's own M.recover(), then goes idle -- the very next
-- tick's ordinary M.assignWork() picks the turtle back up like any
-- other idle one.
job.register("recover_home_link", function(params, shouldStop)
  return homelink.recover()
end)

-- lib/nav.lua's own init() only ever calls gps.locate() the very first
-- time this turtle has no persisted /state/nav.state at all -- once any
-- position exists (even a manual setpos), it trusts that on every later
-- boot rather than re-checking GPS. That's normally fine, but a turtle
-- that got physically broken and replaced elsewhere keeps its old
-- position on disk with nothing to invalidate it, so it boots up
-- confidently wrong until someone remembers to `gpsfix` it by hand.
-- Reacquiring here means every boot self-corrects against the real GPS
-- network whenever one's reachable; on failure (no anchors in range)
-- M.reacquireGPS() leaves whatever position was already tracked
-- untouched, so this is never worse than not calling it at all.
local gpsOk, gpsResult = nav.reacquireGPS()
if gpsOk then
  print("nav: GPS fix on boot -- (" .. gpsResult.x .. ", " .. gpsResult.y .. ", " .. gpsResult.z .. ")")
else
  print("nav: no GPS fix on boot (" .. tostring(gpsResult) .. ") -- keeping last known position")
end

-- GPS only ever fixes position, never facing (see nav.lua's own
-- comments on both functions for why) -- a turtle physically broken and
-- replaced facing some new direction would otherwise boot up confident
-- and wrong about which way it's pointed. Only worth attempting when
-- the GPS fix above actually succeeded -- without a live GPS network
-- there's nothing to measure a test move against anyway.
if gpsOk then
  local headingOk, headingResult = nav.detectHeading()
  if headingOk then
    print("nav: heading confirmed on boot -- facing " .. headingResult.facing)
  else
    print("nav: could not confirm heading on boot (" .. tostring(headingResult) .. ") -- keeping last known facing")
  end
end

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

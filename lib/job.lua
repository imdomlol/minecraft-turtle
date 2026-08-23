--[[----------------------------------------------------------------------
  lib/job.lua -- background job runner, so a long-running task (mining,
  etc.) can be redirected from the remote console *while it's running*.

  Without this, a remote command blocks the poll loop until it returns
  (see lib/remote.lua's execute()) -- a mining job meant to run forever
  would permanently starve the console of any further commands, including
  the one telling it to stop. The fix: jobs run in their own loop
  (M.run(), started once from main.lua alongside remote.run()); remote
  commands only ever call M.request(), which just records what should run
  next and returns immediately. A running job is responsible for calling
  the `shouldStop` function it's given between steps and returning
  promptly if it's true -- see dom-main/mining/vertical.lua for the
  pattern.

  Like lib/nav.lua, this caches itself on _G: main.lua's dofile() (which
  starts M.run()) and a remote command's dofile() (which calls
  M.request()) must resolve to the exact same instance, or requests would
  vanish into a copy nothing is watching.

  M.checkpoint(data) lets a running job persist incremental progress to
  /state/job.state, so dom-main/turtle_main.lua can auto-resume it after
  an unplanned interruption (crash, chunk unload, power loss) instead of
  just coming back up idle. M.run()'s loop clears that file right after
  every job function returns, for *any* reason -- natural completion, an
  operator's stop, a version-triggered stop (lib/updater.lua), or a
  crash pcall caught -- UNLESS the job function's third return value is
  truthy ("keepCheckpoint"), a deliberate, opt-in exception for a
  graceful stop that's still worth resuming from exactly where it left
  off (see dom-main/mining/vertical.lua's "insufficient fuel" path, the
  only current user of this). Every other stop reason leaves that third
  value nil/false, so "only resume genuinely unplanned interruptions (or
  the few explicitly-marked resumable stops)" still holds -- an ordinary
  crash pcall catch also leaves it nil/false, since pcall only ever
  returns two values on failure.
------------------------------------------------------------------------]]

if _G.__JOB_MODULE then return _G.__JOB_MODULE end

local CHECKPOINT_PATH = "/state/job.state"

local M = {}

local jobs = {}                              -- name -> function(params, shouldStop)
local current = { name = "idle", params = {} }
local pending = nil                          -- next job to switch to, consumed by run()

-- Registers a job function under `name`, so M.request(name, params) can
-- start it later. Call this once at boot (from main.lua) for every job
-- script this turtle should know about, before M.run() starts.
function M.register(name, fn)
  jobs[name] = fn
end

-- Requests a switch to job `name` (params passed through to it). Returns
-- immediately -- the actual switch happens on the running job's next
-- shouldStop() check, or right away if idle. "idle" is always valid even
-- without registering it.
function M.request(name, params)
  if name ~= "idle" and not jobs[name] then
    error("unknown job: " .. tostring(name), 2)
  end
  pending = { name = name, params = params or {} }
end

function M.stop()
  M.request("idle")
end

-- Resumes `name` from its last checkpoint if one exists and actually
-- belongs to it, otherwise starts fresh with fallbackParams. Lets a
-- caller say "continue where this turtle left off if possible" without
-- needing to know whether a checkpoint exists at all -- used by
-- dom-main/controller/scheduler.lua when reassigning an idle turtle to
-- its own (sticky) worksite cell, so a turtle that stopped for a
-- resumable reason (see M.checkpoint()'s header comment -- currently
-- just dom-main/mining/vertical.lua's "insufficient fuel" path) picks up
-- exactly where it was instead of walking all the way back to the
-- cell's origin and re-digging from scratch. Returns true if it resumed,
-- false if it started fresh with fallbackParams instead.
function M.resumeOrRequest(name, fallbackParams)
  local saved = M.loadCheckpoint()
  if saved and saved.name == name and M.hasJob(name) then
    local params = saved.params or {}
    params.__resume = saved.checkpoint
    M.request(name, params)
    return true
  end
  M.request(name, fallbackParams)
  return false
end

-- True if `name` is a registered job (or "idle", always valid) -- lets
-- boot-time resume logic check before calling M.request(), which
-- otherwise error()s on an unrecognized name (e.g. one an OTA update
-- removed or renamed since the checkpoint was written).
function M.hasJob(name)
  return name == "idle" or jobs[name] ~= nil
end

-- Persists incremental progress for the *currently running* job --
-- meant to be called by a job function itself (see
-- dom-main/mining/vertical.lua for the pattern), not from outside.
-- `data` is whatever shape that job wants back on resume.
function M.checkpoint(data)
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(CHECKPOINT_PATH, "w")
  f.write(textutils.serializeJSON({ name = current.name, params = current.params, checkpoint = data }))
  f.close()
end

-- Returns { name, params, checkpoint } from the last checkpoint written
-- before an unplanned interruption, or nil if there isn't one (the
-- normal case -- see M.run()'s M.clearCheckpoint() below).
function M.loadCheckpoint()
  if not fs.exists(CHECKPOINT_PATH) then return nil end
  local f = fs.open(CHECKPOINT_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

function M.clearCheckpoint()
  if fs.exists(CHECKPOINT_PATH) then fs.delete(CHECKPOINT_PATH) end
end

-- What's running now, and what's queued to replace it (if anything) --
-- e.g. for a status command over the remote console.
function M.status()
  return {
    current = current.name,
    params = current.params,
    pending = pending and pending.name or nil,
  }
end

local function shouldStop()
  return pending ~= nil
end

-- Built-in "goto" job: lets an ad-hoc trip run in the background like any
-- other job, instead of blocking the remote console for its whole
-- duration the way running dofile("/lib/pathfind.lua").goto(...) as a
-- plain command does -- that starves the poll loop of answering
-- anything else, even a quick nav.report(), until the trip finishes.
-- Params: x, y, z, tolerance (default 0), allowDig (default false; false,
-- "safe", or "all" -- see lib/pathfind.lua's digMode()).
-- shouldStop is passed straight through to pathfind.goto(), which checks
-- it before every single step -- so dofile("/lib/job.lua").stop() (or
-- switching to a different job) now interrupts a "goto" job almost
-- immediately, not just between steps of some coarser outer loop.
M.register("goto", function(params, shouldStop)
  local pathfind = dofile("/lib/pathfind.lua")
  return pathfind.goto(params.x, params.y, params.z, {
    tolerance = params.tolerance,
    allowDig = params.allowDig,
    shouldStop = shouldStop,
  })
end)

-- Blocks forever, running whatever job is current and switching when
-- M.request() is called. Meant to run alongside remote.run() via
-- parallel.waitForAny in main.lua.
function M.run()
  while true do
    if pending then
      current, pending = pending, nil
      print("job: switching to " .. current.name)
    end

    if current.name == "idle" then
      sleep(1)
    else
      local fn = jobs[current.name]
      local ok, err, keepCheckpoint = pcall(fn, current.params, shouldStop)
      if not ok then
        print("job: " .. current.name .. " crashed -- " .. tostring(err))
      end
      if not keepCheckpoint then
        M.clearCheckpoint()
      end
      if not pending then
        current = { name = "idle", params = {} }
      end
    end
  end
end

_G.__JOB_MODULE = M
return M

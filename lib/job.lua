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
------------------------------------------------------------------------]]

if _G.__JOB_MODULE then return _G.__JOB_MODULE end

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
      local ok, err = pcall(fn, current.params, shouldStop)
      if not ok then
        print("job: " .. current.name .. " crashed -- " .. tostring(err))
      end
      if not pending then
        current = { name = "idle", params = {} }
      end
    end
  end
end

_G.__JOB_MODULE = M
return M

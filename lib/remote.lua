--[[----------------------------------------------------------------------
  lib/remote.lua -- polls the relay server for commands and runs them.

  Config lives in /state/remote.cfg (JSON: {url, token}), written once by
  remote-setup.lua. /state survives startup.lua's OTA wipe, so the config
  isn't lost on every boot/update even though this file is redeployed from
  a public repo (the token never lives in git).

  Only the HTTP plumbing lives here -- "run this command and capture its
  output, mirroring everything printed into a streamable log buffer" is
  transport-agnostic and lives in lib/exec.lua, shared with lib/fleet.lua
  (the rednet transport a turtle uses to talk to its controller instead
  of a turtle talking to this relay directly).
------------------------------------------------------------------------]]

local exec = dofile("/lib/exec.lua")
local tasks = dofile("/lib/tasks.lua")

local CONFIG_PATH   = "/state/remote.cfg"
local POLL_INTERVAL = 3    -- seconds between polls when idle
local ERROR_BACKOFF = 10   -- seconds to wait after a network/HTTP error
local LOG_PUSH_INTERVAL = 1.5 -- seconds between live-console flushes
local BLOCK_PUSH_INTERVAL = 2 -- seconds between live worldstore.lua pushes

local M = {}

-- Tolerates a URL typed without a scheme (e.g. "example.com" instead of
-- "https://example.com") and a trailing slash, both easy to fat-finger
-- at the remote-setup prompt and otherwise a confusing http.post failure.
function M.normalizeUrl(url)
  if not url:match("^https?://") then
    url = "https://" .. url
  end
  return (url:gsub("/+$", ""))
end

function M.loadConfig()
  if not fs.exists(CONFIG_PATH) then return nil end
  local f = fs.open(CONFIG_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, cfg = pcall(textutils.unserializeJSON, text)
  if not ok or type(cfg) ~= "table" or not cfg.url or not cfg.token then
    return nil
  end
  cfg.url = M.normalizeUrl(cfg.url)
  return cfg
end

function M.saveConfig(cfg)
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(CONFIG_PATH, "w")
  f.write(textutils.serializeJSON(cfg))
  f.close()
end

local function headers(cfg)
  return {
    ["Authorization"] = "Bearer " .. cfg.token,
    ["Content-Type"]  = "application/json",
  }
end

-- Confirmed live: once commands started running as concurrent tasks (see
-- pollLoop below), overlapping http.post() calls crashed with "attempt
-- to use a closed file" -- CC:Tweaked's http API doesn't appear to
-- tolerate more than one truly-in-flight request from the same computer
-- safely. Serializing just the actual network call (not command
-- execution -- see pollLoop's own comment for why that distinction is
-- the whole point) sidesteps it: every post() call queues here, one at a
-- time, while whatever's slow about a command itself (lib/exec.lua's
-- exec.run(), which is what tonight's fleet-wide-dispatch stall was
-- actually about) still runs fully concurrently.
local httpLocked = false
local function acquireHttpLock()
  while httpLocked do
    os.pullEvent("remote_http_unlock")
  end
  httpLocked = true
end
local function releaseHttpLock()
  httpLocked = false
  os.queueEvent("remote_http_unlock")
end

-- Returns decoded response, or nil + reason.
local function post(cfg, path, body)
  acquireHttpLock()
  local ok, result, err = pcall(function()
    local handle, herr = http.post(cfg.url .. path, textutils.serializeJSON(body), headers(cfg))
    if not handle then return nil, tostring(herr) end
    local code = handle.getResponseCode()
    local respBody = handle.readAll()
    handle.close()
    if code ~= 200 then return nil, "HTTP " .. tostring(code) end
    local decodeOk, decoded = pcall(textutils.unserializeJSON, respBody)
    if not decodeOk then return nil, "bad response json" end
    return decoded
  end)
  releaseHttpLock()
  if not ok then error(result, 0) end
  return result, err
end

-- Polls for the next queued command and hands it to `startExecTask` as
-- its own concurrent task, rather than running it inline -- confirmed
-- live: a single slow command (e.g. a fleet-wide dispatch that itself
-- waits on dozens/hundreds of unreachable turtles) used to block this
-- loop from ever polling again until it finished, so every OTHER queued
-- operator command -- even a plain status query -- sat frozen behind it
-- for however long that one took. Polling now never waits on a
-- command's own execution, so an unrelated command queued moments later
-- runs immediately instead of queueing behind it. Same shape as
-- lib/fleet.lua's listenLoop/startExecTask -- see lib/tasks.lua's own
-- header for why the scheduler itself is shared between the two.
local function pollLoop(cfg, id, startExecTask)
  local lastErr = nil

  while true do
    local resp, err = post(cfg, "/poll", { id = id, label = os.getComputerLabel() })

    if err then
      if err ~= lastErr then
        print("remote: poll failed: " .. err)
        lastErr = err
      end
    elseif lastErr then
      print("remote: poll recovered.")
      lastErr = nil
    end

    if resp and resp.command then
      startExecTask(resp)
      -- loop again immediately in case more commands are queued
    else
      sleep(err and ERROR_BACKOFF or POLL_INTERVAL)
    end
  end
end

-- Ships exec's pendingLog to the relay every LOG_PUSH_INTERVAL seconds,
-- for `turtlectl.py console <id>` to tail. Best-effort: a failed push
-- just retries next tick with whatever's accumulated since (capped, see
-- lib/exec.lua's appendLog), rather than blocking or erroring the whole
-- console loop.
local function streamLoop(cfg, id)
  while true do
    sleep(LOG_PUSH_INTERVAL)
    local chunk = exec.pendingLog()
    if chunk ~= "" then
      local _, err = post(cfg, "/log", { id = id, text = chunk })
      if not err then exec.dropSentLog(chunk) end
    end
  end
end

-- Ships dom-main/controller/worldstore.lua's pending live-stream entries
-- to the relay's /blocks endpoint every BLOCK_PUSH_INTERVAL seconds, for
-- turtlectl.py worldwatch to tail. Only ever called from M.run(), which
-- only the controller ever invokes (see controller_main.lua) -- a turtle
-- has no dom-main/controller/*.lua on disk to dofile() here.
local function blockStreamLoop(cfg, id)
  local worldstore = dofile("/dom-main/controller/worldstore.lua")
  while true do
    sleep(BLOCK_PUSH_INTERVAL)
    local pending = worldstore.pendingStream()
    if next(pending) ~= nil then
      local _, err = post(cfg, "/blocks", { id = id, entries = pending })
      if not err then worldstore.dropSentStream(pending) end
    end
  end
end

-- Blocks forever, polling for and running commands while also streaming
-- everything printed to the screen to the relay's live console feed.
-- Meant to be run alongside other turtle work via parallel.waitForAny.
function M.run()
  if not http then
    print("remote: http api disabled, cannot reach relay.")
    return
  end

  local cfg = M.loadConfig()
  if not cfg then
    print("remote: not configured. run remote-setup.lua once.")
    return
  end

  print("remote: connecting to " .. cfg.url)
  -- A champion name (lib/identity.lua), not the raw computer ID -- IDs
  -- are only unique within one world, and two devices on two different
  -- servers sharing this relay colliding on the same ID would silently
  -- interleave their commands/results/logs into the same slot.
  local id = dofile("/lib/identity.lua").get(cfg)
  print("remote: identity is " .. id)

  term.redirect(exec.wrapTerm(term.current()))

  local sched = tasks.new()
  local function startExecTask(resp)
    sched.addTask(function()
      local ok, output = exec.run(resp.command)
      post(cfg, "/result", {
        id = id, cmd_id = resp.cmd_id, command = resp.command, ok = ok, output = output,
      })
    end, function(err)
      post(cfg, "/result", {
        id = id, cmd_id = resp.cmd_id, command = resp.command,
        ok = false, output = "error: " .. tostring(err),
      })
    end)
  end

  sched.addTask(function() pollLoop(cfg, id, startExecTask) end)
  sched.addTask(function() streamLoop(cfg, id) end)
  sched.addTask(function() blockStreamLoop(cfg, id) end)
  sched.run()
end

return M

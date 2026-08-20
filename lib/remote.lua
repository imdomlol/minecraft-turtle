--[[----------------------------------------------------------------------
  lib/remote.lua -- polls the relay server for commands and runs them.

  Config lives in /state/remote.cfg (JSON: {url, token}), written once by
  remote-setup.lua. /state survives startup.lua's OTA wipe, so the config
  isn't lost on every boot/update even though this file is redeployed from
  a public repo (the token never lives in git).
------------------------------------------------------------------------]]

local CONFIG_PATH   = "/state/remote.cfg"
local POLL_INTERVAL = 3    -- seconds between polls when idle
local ERROR_BACKOFF = 10   -- seconds to wait after a network/HTTP error
local LOG_PUSH_INTERVAL = 1.5 -- seconds between live-console flushes
local MAX_PENDING_LOG   = 8000 -- chars; oldest dropped first if the relay is unreachable

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

-- Returns decoded response, or nil + reason.
local function post(cfg, path, body)
  local handle, err = http.post(cfg.url .. path, textutils.serializeJSON(body), headers(cfg))
  if not handle then return nil, tostring(err) end
  local code = handle.getResponseCode()
  local respBody = handle.readAll()
  handle.close()
  if code ~= 200 then return nil, "HTTP " .. tostring(code) end
  local ok, decoded = pcall(textutils.unserializeJSON, respBody)
  if not ok then return nil, "bad response json" end
  return decoded
end

-- Everything ever printed to this turtle's screen -- boot messages, remote
-- command output, whatever a future "day job" script prints -- accumulates
-- here so streamLoop() can ship it to the relay for `turtlectl.py console`.
-- Kept as a plain string rather than a growing table: appends are rare
-- enough (one per screen write) that this isn't a hot path.
local pendingLog = ""

local function appendLog(text)
  pendingLog = pendingLog .. text
  if #pendingLog > MAX_PENDING_LOG then
    pendingLog = pendingLog:sub(-MAX_PENDING_LOG)
  end
end

-- Removes exactly the prefix that was just sent, not everything pending --
-- more may have been appended (e.g. by execute()) while the POST was in
-- flight, since http.post yields to other coroutines under parallel.
local function dropSentLog(sent)
  if pendingLog:sub(1, #sent) == sent then
    pendingLog = pendingLog:sub(#sent + 1)
  end
end

-- Wraps a real term so everything written through it still reaches the
-- real screen, but is also mirrored into pendingLog. Mirrors newCaptureTerm's
-- write/setCursorPos->newline logic; everything else just passes through.
local function newTeeTerm(real)
  local cursorY = select(2, real.getCursorPos())
  local t = {}
  function t.write(text)
    real.write(text)
    appendLog(tostring(text))
  end
  function t.blit(text, fg, bg)
    real.blit(text, fg, bg)
    appendLog(tostring(text))
  end
  function t.setCursorPos(x, y)
    if y ~= cursorY then appendLog("\n") end
    cursorY = y
    real.setCursorPos(x, y)
  end
  function t.scroll(n)
    real.scroll(n)
    appendLog("\n")
  end
  local passthrough = {
    "getCursorPos", "getSize", "clear", "clearLine", "setCursorBlink",
    "isColor", "isColour", "getTextColor", "getTextColour",
    "setTextColor", "setTextColour", "getBackgroundColor", "getBackgroundColour",
    "setBackgroundColor", "setBackgroundColour",
    "getPaletteColor", "getPaletteColour", "setPaletteColor", "setPaletteColour",
  }
  for _, name in ipairs(passthrough) do
    if real[name] then
      t[name] = function(...) return real[name](...) end
    end
  end
  return t
end

-- A minimal term-API implementation that records what was written (for
-- execute() to assemble the final result string) *and* mirrors it into
-- pendingLog, so a long-running command's output streams to the live
-- console as it happens rather than appearing all at once when it
-- finally returns -- this term is swapped in for the whole duration of
-- the command, so without this mirroring, appendLog never sees any of it
-- until execute() explicitly adds the assembled result afterward.
local function newCaptureTerm()
  local buf = {}
  local cursorY = 1
  local t = {}
  function t.write(text) buf[#buf + 1] = tostring(text); appendLog(tostring(text)) end
  function t.blit(text) buf[#buf + 1] = tostring(text); appendLog(tostring(text)) end
  function t.setCursorPos(x, y)
    if y ~= cursorY then buf[#buf + 1] = "\n"; appendLog("\n") end
    cursorY = y
  end
  function t.scroll() buf[#buf + 1] = "\n"; appendLog("\n") end
  function t.getCursorPos() return 1, cursorY end
  function t.getSize() return 51, 19 end
  function t.clear() end
  function t.clearLine() end
  function t.setCursorBlink() end
  function t.isColor() return false end
  t.isColour = t.isColor
  function t.getTextColor() return colors.white end
  t.getTextColour = t.getTextColor
  function t.setTextColor() end
  t.setTextColour = t.setTextColor
  function t.getBackgroundColor() return colors.black end
  t.getBackgroundColour = t.getBackgroundColor
  function t.setBackgroundColor() end
  t.setBackgroundColour = t.setBackgroundColor
  return t, buf
end

-- Runs `command` as Lua, capturing anything it prints. Returns ok, output.
-- Tries an implicit "return" first, same as CraftOS's own `lua` shell
-- program, so a bare call like "turtle.getFuelLevel()" reports its
-- return value instead of silently discarding it as a statement. Falls
-- back to the raw parse for genuine statements ("for i=1,3 do ... end")
-- that don't compile with "return" in front.
-- Many turtle API calls return more than one value on failure, e.g.
-- turtle.forward() -> false, "Out of fuel". A plain `local ok, result =
-- pcall(fn)` would silently drop that second value, so capture all of
-- them via varargs instead.
local function packAll(...)
  return select("#", ...), { ... }
end

local function execute(command)
  local fn = load("return " .. command, "=remote")
  local loadErr
  if not fn then
    fn, loadErr = load(command, "=remote")
  end
  if not fn then
    local msg = "compile error: " .. tostring(loadErr)
    appendLog("> " .. command .. "\n" .. msg .. "\n")
    return false, msg
  end

  -- Logged before running, not after: a long-running command (a job's
  -- pathfind trip, say) would otherwise leave the live console dark for
  -- its entire duration with no indication anything was even received.
  appendLog("> " .. command .. "\n")

  local capture, buf = newCaptureTerm()
  local realTerm = term.redirect(capture)
  local n, results = packAll(pcall(fn))
  term.redirect(realTerm)

  local ok = results[1]
  local output = table.concat(buf):gsub("^%s+", ""):gsub("%s+$", "")

  -- The error/return-value suffix below is computed from pcall's results
  -- after the fact -- it was never turtle.print()'d through the capture
  -- term, so (unlike the rest of `output`) it needs its own explicit
  -- appendLog to actually reach the live console.
  local suffix
  if not ok then
    suffix = "error: " .. tostring(results[2])
    output = (output ~= "" and (output .. "\n" .. suffix) or suffix)
  elseif n > 1 then
    local parts = {}
    for i = 2, n do
      local v = results[i]
      parts[#parts + 1] = type(v) == "table" and textutils.serialize(v) or tostring(v)
    end
    suffix = "= " .. table.concat(parts, ", ")
    output = (output ~= "" and (output .. "\n") or "") .. suffix
  end
  if suffix then appendLog(suffix .. "\n") end

  return ok, output
end

local function pollLoop(cfg, id)
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
      local ok, output = execute(resp.command)
      post(cfg, "/result", {
        id = id,
        cmd_id = resp.cmd_id,
        command = resp.command,
        ok = ok,
        output = output,
      })
      -- loop again immediately in case more commands are queued
    else
      sleep(err and ERROR_BACKOFF or POLL_INTERVAL)
    end
  end
end

-- Ships pendingLog to the relay every LOG_PUSH_INTERVAL seconds, for
-- `turtlectl.py console <id>` to tail. Best-effort: a failed push just
-- retries next tick with whatever's accumulated since (capped, see
-- appendLog), rather than blocking or erroring the whole console loop.
local function streamLoop(cfg, id)
  while true do
    sleep(LOG_PUSH_INTERVAL)
    if pendingLog ~= "" then
      local chunk = pendingLog
      local _, err = post(cfg, "/log", { id = id, text = chunk })
      if not err then dropSentLog(chunk) end
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
  local id = tostring(os.getComputerID())

  term.redirect(newTeeTerm(term.current()))

  parallel.waitForAny(
    function() pollLoop(cfg, id) end,
    function() streamLoop(cfg, id) end
  )
end

return M

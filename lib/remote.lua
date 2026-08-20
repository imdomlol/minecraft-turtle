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

-- A minimal term-API implementation that just records what was written,
-- so print()/write() from an executed command can be captured as plain
-- text without touching the turtle's real screen.
local function newCaptureTerm()
  local buf = {}
  local cursorY = 1
  local t = {}
  function t.write(text) buf[#buf + 1] = tostring(text) end
  function t.blit(text) buf[#buf + 1] = tostring(text) end
  function t.setCursorPos(x, y)
    if y ~= cursorY then buf[#buf + 1] = "\n" end
    cursorY = y
  end
  function t.scroll() buf[#buf + 1] = "\n" end
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
  if not fn then return false, "compile error: " .. tostring(loadErr) end

  local capture, buf = newCaptureTerm()
  local realTerm = term.redirect(capture)
  local n, results = packAll(pcall(fn))
  term.redirect(realTerm)

  local ok = results[1]
  local output = table.concat(buf):gsub("^%s+", ""):gsub("%s+$", "")

  if not ok then
    local msg = "error: " .. tostring(results[2])
    return false, (output ~= "" and (output .. "\n" .. msg) or msg)
  end
  if n > 1 then
    local parts = {}
    for i = 2, n do
      parts[#parts + 1] = tostring(results[i])
    end
    output = (output ~= "" and (output .. "\n") or "") .. "= " .. table.concat(parts, ", ")
  end
  return true, output
end

-- Blocks forever, polling for and running commands. Meant to be run
-- alongside other turtle work via parallel.waitForAny.
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

return M

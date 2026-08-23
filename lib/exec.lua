--[[----------------------------------------------------------------------
  lib/exec.lua -- runs a Lua command string and captures its output,
  independent of how that command string arrived or where its result is
  going. Extracted out of lib/remote.lua so lib/fleet.lua (rednet
  transport) doesn't have to duplicate ~150 lines of identical
  execute()/tee-term/pending-log plumbing -- the two transports differ
  only in *how* a command shows up and *how* a result/log line gets sent
  onward, not in what "run this and capture the output" means.

  Callers own the poll/receive loop and the actual send; this module owns
  everything in between: M.run(command) executes it, M.wrapTerm(real)
  installs a passthrough terminal that mirrors everything printed into a
  pending-log buffer, and M.pendingLog()/M.dropSentLog() let a streaming
  loop ship that buffer onward at its own pace without losing anything
  appended mid-send (see dropSentLog's own comment).

  Cached on _G like lib/nav.lua/lib/job.lua: whichever transport dofile()s
  this first creates the one pendingLog buffer everything else shares for
  the lifetime of the running turtle/controller.
------------------------------------------------------------------------]]

if _G.__EXEC_MODULE then return _G.__EXEC_MODULE end

local M = {}

local MAX_PENDING_LOG = 8000 -- chars; oldest dropped first if nothing ships it out in time

-- Everything ever printed to this device's screen -- boot messages,
-- command output, whatever a "day job" script prints -- accumulates here
-- so a transport's own streaming loop can ship it onward (relay /log,
-- rednet log messages, whatever) for a live console to tail.
local pendingLog = ""

local function appendLog(text)
  pendingLog = pendingLog .. text
  if #pendingLog > MAX_PENDING_LOG then
    pendingLog = pendingLog:sub(-MAX_PENDING_LOG)
  end
end

function M.pendingLog()
  return pendingLog
end

-- Feeds externally-sourced text into the same pendingLog buffer a local
-- M.run() call would -- used by the controller to fold each turtle's own
-- rednet-streamed log lines into its own relay /log feed, so
-- `turtlectl.py console <controller>` shows the whole fleet's activity
-- through the one relay connection instead of needing one per turtle.
function M.append(text)
  appendLog(text)
end

-- Removes exactly the prefix that was just sent, not everything pending --
-- more may have been appended (e.g. by M.run()) while the send was in
-- flight, since a transport's send typically yields to other coroutines
-- under parallel.
function M.dropSentLog(sent)
  if pendingLog:sub(1, #sent) == sent then
    pendingLog = pendingLog:sub(#sent + 1)
  end
end

-- Wraps a real term so everything written through it still reaches the
-- real screen, but is also mirrored into pendingLog. Mirrors
-- newCaptureTerm's write/setCursorPos->newline logic below; everything
-- else just passes through.
function M.wrapTerm(real)
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
-- M.run() to assemble the final result string) *and* mirrors it into
-- pendingLog, so a long-running command's output streams to the live
-- console as it happens rather than appearing all at once when it
-- finally returns -- this term is swapped in for the whole duration of
-- the command, so without this mirroring, appendLog never sees any of it
-- until M.run() explicitly adds the assembled result afterward.
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

function M.run(command)
  local fn = load("return " .. command, "=exec")
  local loadErr
  if not fn then
    fn, loadErr = load(command, "=exec")
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

_G.__EXEC_MODULE = M
return M

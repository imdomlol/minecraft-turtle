--[[----------------------------------------------------------------------
  lib/home.lua -- remember a "home" position and get back to it.

  Separate from lib/nav.lua's own tracked position (which is just "where
  the turtle currently is") and from lib/pathfind.lua (which is just
  "move to any given point") -- this is the specific, very common pattern
  of "remember where I started, go back there later", pulled out so any
  job script can reuse it instead of re-deriving it. Persists to
  /state/home.state, so it survives startup.lua's wipe and, unlike
  nav.state, isn't touched by ordinary movement.
------------------------------------------------------------------------]]

if _G.__HOME_MODULE then return _G.__HOME_MODULE end

local nav = dofile("/lib/nav.lua")
local routing = dofile("/lib/routing.lua")

local STATE_PATH = "/state/home.state"

local M = {}

local function save(pos)
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(pos))
  f.close()
end

-- Records the current position as home, overwriting any previous one.
-- Returns the position recorded.
function M.mark()
  local pos = nav.getPosition()
  local home = { x = pos.x, y = pos.y, z = pos.z, heading = pos.heading }
  save(home)
  return home
end

-- Returns the recorded home position, or nil if M.mark() was never called
-- (on this turtle, or since its last /state wipe).
function M.get()
  if not fs.exists(STATE_PATH) then return nil end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

-- Pathfinds back to home. opts are passed straight through to
-- pathfind.goto (tolerance, allowDig). Returns false, "no home marked" if
-- M.mark() was never called; otherwise pathfind.goto's own ok, info.
function M.go(opts)
  local home = M.get()
  if not home then return false, "no home marked -- call home.mark() first" end
  return routing.goto(home.x, home.y, home.z, opts)
end

_G.__HOME_MODULE = M
return M

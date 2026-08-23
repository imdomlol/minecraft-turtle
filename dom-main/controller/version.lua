--[[----------------------------------------------------------------------
  dom-main/controller/version.lua -- the controller's manually-updated
  "current version" counter, so turtles can tell when they're running
  stale code and are safe to reboot.

  Deliberately not tied to git/the manifest automatically: the operator
  bumps this once they've pushed new code AND are ready for the fleet to
  actually pick it up (see lib/updater.lua, turtle-side) -- decoupling
  "code changed" from "turtles should reboot now" is the whole point,
  since those often shouldn't happen at the same moment.

  Persisted to its own /state/controller_version.state, deliberately
  separate from dom-main/controller/mode.lua's /state/controller.state --
  each module's save() writes a fresh table, not a merge, so sharing one
  file between two independently-saving modules would let one silently
  clobber the other's field.
------------------------------------------------------------------------]]

if _G.__VERSION_MODULE then return _G.__VERSION_MODULE end

local STATE_PATH = "/state/controller_version.state"

local M = {}

local version -- lazily loaded, defaults to 1

local function save()
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON({ version = version }))
  f.close()
end

local function loadState()
  if version then return end
  version = 1
  if not fs.exists(STATE_PATH) then return end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" and type(decoded.version) == "number" then
    version = decoded.version
  end
end

function M.get()
  loadState()
  return version
end

function M.set(newVersion)
  if type(newVersion) ~= "number" then
    error("version must be a number", 2)
  end
  loadState()
  version = newVersion
  save()
  return version
end

-- Convenience for the common "just pushed new code" operator workflow --
-- turtlectl.py's `version --bump` shortcut.
function M.bump()
  loadState()
  version = version + 1
  save()
  return version
end

_G.__VERSION_MODULE = M
return M

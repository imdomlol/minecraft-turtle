--[[----------------------------------------------------------------------
  lib/identity.lua -- assigns this turtle a stable, human-readable name to
  identify itself to the relay with, instead of the bare CC:Tweaked
  computer ID lib/remote.lua used to send. Computer IDs are only unique
  *within a single world* -- two turtles on two different servers sharing
  one relay can easily both be ID 0, and since relay.py keys everything
  (queue, results, live console log) purely by that id string, colliding
  turtles silently interleave into the same slot: commands meant for one
  can execute on the other, and their results/logs mix together.

  Picks a name from lib/champions.lua, checking the relay's own /status
  for names already in use so two turtles don't pick the same one (this
  is a best-effort check, not an atomic claim -- see M.get()). Persists
  to /state/identity.state (survives startup.lua's wipe), so a turtle
  keeps its name across every future reboot rather than re-registering as
  a new identity each time, which would fragment its own result history
  across many different IDs.
------------------------------------------------------------------------]]

if _G.__IDENTITY_MODULE then return _G.__IDENTITY_MODULE end

local STATE_PATH = "/state/identity.state"

local M = {}

local function save(name)
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON({ name = name }))
  f.close()
end

local function loadSaved()
  if not fs.exists(STATE_PATH) then return nil end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" and decoded.name then return decoded.name end
  return nil
end

-- Fisher-Yates shuffle, so name candidates are tried in random order
-- rather than every fresh turtle racing for "Aatrox" first.
local function shuffled(list)
  local copy = {}
  for i, v in ipairs(list) do copy[i] = v end
  for i = #copy, 2, -1 do
    local j = math.random(i)
    copy[i], copy[j] = copy[j], copy[i]
  end
  return copy
end

-- GET cfg.url/status -- who's already registered, so a fresh name pick
-- can avoid colliding with them. Returns a set (name -> true), or nil if
-- the relay couldn't be reached (best-effort: proceeds without a
-- uniqueness check rather than getting stuck unable to identify at all).
local function takenNames(cfg)
  if not http then return nil end
  local handle = http.get(cfg.url .. "/status", {
    ["Authorization"] = "Bearer " .. cfg.token,
  })
  if not handle then return nil end
  local code = handle.getResponseCode()
  local body = handle.readAll()
  handle.close()
  if code ~= 200 then return nil end
  local ok, decoded = pcall(textutils.unserializeJSON, body)
  if not ok or type(decoded) ~= "table" then return nil end
  local taken = {}
  for name in pairs(decoded) do taken[name] = true end
  return taken
end

-- Returns this turtle's stable identity, assigning one on first call
-- (and persisting it) if it doesn't have one yet. cfg (see
-- lib/remote.lua's loadConfig()) is used to check the relay for names
-- already in use; pass nil to skip that check and just pick randomly.
--
-- Note this is a check-then-act, not an atomic claim: two turtles
-- assigning themselves an identity at the exact same moment, before
-- either has registered with the relay, could in principle both pick the
-- same free-looking name. Acceptable here since this only ever runs once
-- per turtle's whole lifetime (persisted after) rather than every boot,
-- making that a vanishingly narrow window -- not worth a real
-- distributed-locking mechanism for this.
function M.get(cfg)
  local saved = loadSaved()
  if saved then return saved end

  math.randomseed((os.epoch and os.epoch("utc") or os.time()) + os.getComputerID())

  local champions = dofile("/lib/champions.lua")
  local taken = cfg and takenNames(cfg) or nil

  local name
  for _, candidate in ipairs(shuffled(champions)) do
    if not taken or not taken[candidate] then
      name = candidate
      break
    end
  end

  if not name then
    -- Every name in the pool is already taken (a lot of turtles!) --
    -- fall back to a numbered variant instead of getting stuck.
    local base = champions[math.random(#champions)]
    local suffix = 2
    name = base .. suffix
    while taken and taken[name] do
      suffix = suffix + 1
      name = base .. suffix
    end
  end

  save(name)
  if os.setComputerLabel then os.setComputerLabel(name) end
  return name
end

_G.__IDENTITY_MODULE = M
return M

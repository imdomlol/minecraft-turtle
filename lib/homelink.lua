--[[----------------------------------------------------------------------
  lib/homelink.lua -- the shared home-link Ender Chest every turtle
  carries: a portable inventory that, once placed, is the SAME physical
  inventory as a matching chest sitting at home (EnderStorage's frequency
  linking), wired there into an AE2 network via a plain Import Bus
  (drains anything dropped in) and an Export Bus (keeps it stocked with
  fuel). This lets a turtle unload loot and refuel without ever
  traveling anywhere -- it just places the chest wherever it currently
  is, transfers, and picks it back up.

  M.SLOT is a fixed inventory slot (16, the last one) reserved for this
  item on every turtle -- never cargo space. lib/inventory.lua's own
  slot-scanning functions already exclude it for exactly this reason
  (see that file's own RESERVED_SLOT comment); keep the two in sync if
  this ever changes.

  This module only handles getting the chest itself into and out of the
  world reliably. Once M.place() returns a direction, use the EXISTING
  primitives for the actual transfer -- lib/inventory.lua's M.dropAll()
  for loot, lib/fuel.lua's M.ensureFuel() for fuel (its own drain() logic
  already checks front/up/down, so whichever direction the chest landed
  in just works) -- rather than duplicating either here.
------------------------------------------------------------------------]]

if _G.__HOMELINK_MODULE then return _G.__HOMELINK_MODULE end

local nav = dofile("/lib/nav.lua")

local M = {}

M.SLOT = 16
-- Confirmed live (turtlectl.py send + turtle.dig() against a real placed
-- one) -- EnderStorage's actual registry name, not a guess. Used only to
-- verify a RECOVERY candidate in M.pickUp() below, never to gate
-- M.place() -- a caller already knows slot 16 is supposed to hold this,
-- and M.place() trusts that positionally, same as before.
local ITEM_NAME = "enderstorage:ender_chest"
local STATE_PATH = "/state/homelink.state"
local DELTA = {
  north = { x = 0,  z = -1 },
  east  = { x = 1,  z = 0 },
  south = { x = 0,  z = 1 },
  west  = { x = -1, z = 0 },
}

local function isProtected(data)
  return data ~= nil and (nav.isChest(data.name) or nav.isComputerCraftBlock(data.name))
end

local function saveState(data)
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(textutils.serializeJSON(data))
  f.close()
end

local function loadState()
  if not fs.exists(STATE_PATH) then return nil end
  local f = fs.open(STATE_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

local function blockPosition(pos, direction)
  if direction == "up" then
    return { x = pos.x, y = pos.y + 1, z = pos.z }
  elseif direction == "down" then
    return { x = pos.x, y = pos.y - 1, z = pos.z }
  end
  local d = DELTA[pos.facing] or { x = 0, z = 0 }
  return { x = pos.x + d.x, y = pos.y, z = pos.z + d.z }
end

local function markPlaced(direction, gpsOk, gpsInfo)
  local pos = nav.getPosition()
  local marker = {
    status = "placed",
    direction = direction,
    turtle = {
      x = pos.x, y = pos.y, z = pos.z,
      heading = pos.heading,
      facing = pos.facing,
      gpsFixed = pos.gpsFixed,
      source = pos.source,
    },
    chest = blockPosition(pos, direction),
    gps = {
      attempted = true,
      ok = gpsOk == true,
      result = gpsInfo,
    },
    at = os.epoch and os.epoch("utc") or os.clock(),
  }
  saveState(marker)
  return marker
end

local function markPickup(status, reason)
  local pos = nav.getPosition()
  local previous = loadState() or {}
  previous.status = status
  previous.reason = reason
  previous.turtle = {
    x = pos.x, y = pos.y, z = pos.z,
    heading = pos.heading,
    facing = pos.facing,
    gpsFixed = pos.gpsFixed,
    source = pos.source,
  }
  previous.updatedAt = os.epoch and os.epoch("utc") or os.clock()
  saveState(previous)
end

function M.getState()
  return loadState()
end

local function placed(direction, gpsOk, gpsInfo)
  markPlaced(direction, gpsOk, gpsInfo)
  return direction
end

-- Tries front, then up, then down, and places the chest in whichever
-- one is actually open -- or, if all three are already occupied, clears
-- ONE of them first and retries. Confirmed live: a turtle mid-shaft,
-- surrounded by solid rock on every side, is the COMMON case here, not
-- a rare edge case -- refusing to dig at all (an earlier version of
-- this function) made the whole feature useless in exactly the
-- situation it exists for. Uses the same protected-block check dom-main/
-- mining/vertical.lua's own leg-stepping already relies on (never a
-- chest or ComputerCraft block -- a player's storage or another
-- turtle/computer) -- ordinary stone/dirt/ore is exactly what a mining
-- turtle already digs through as a matter of course, so clearing one
-- more block here to make room for its own hardware isn't any riskier
-- than the job it's already running. Only refuses (returns nil, reason)
-- if every direction is either genuinely undiggable or specifically
-- protected. Returns the direction it succeeded in ("front", "up", or
-- "down").
function M.place()
  if turtle.getItemCount(M.SLOT) == 0 then
    return nil, "no home-link chest in slot " .. M.SLOT
  end
  local gpsOk, gpsInfo = nav.reacquireGPS()
  turtle.select(M.SLOT)

  if turtle.place() then return placed("front", gpsOk, gpsInfo) end
  if turtle.placeUp() then return placed("up", gpsOk, gpsInfo) end
  if turtle.placeDown() then return placed("down", gpsOk, gpsInfo) end

  local found, data = turtle.inspect()
  if found and not isProtected(data) and turtle.dig() then
    turtle.select(M.SLOT)
    if turtle.place() then return placed("front", gpsOk, gpsInfo) end
  end
  found, data = turtle.inspectUp()
  if found and not isProtected(data) and turtle.digUp() then
    turtle.select(M.SLOT)
    if turtle.placeUp() then return placed("up", gpsOk, gpsInfo) end
  end
  found, data = turtle.inspectDown()
  if found and not isProtected(data) and turtle.digDown() then
    turtle.select(M.SLOT)
    if turtle.placeDown() then return placed("down", gpsOk, gpsInfo) end
  end

  return nil, "no open space to place the home-link chest (front/up/down all blocked, protected, or undiggable)"
end

-- Digs the chest back up from `direction` (as returned by M.place()) and
-- confirms it actually landed back in M.SLOT AS THE RIGHT ITEM before
-- reporting success -- CC:Tweaked gives a dig's collected item to the
-- CURRENTLY SELECTED slot first (as long as that slot is empty, or
-- merges into a matching stack there), which M.SLOT always is right
-- before this call, so selecting M.SLOT first is normally enough on its
-- own. This still verifies rather than assumes, and specifically checks
-- WHAT landed, not just that something did: confirmed live, something
-- else entirely (a full inventory of ordinary cargo, sucked back in by
-- a concurrent job's own fuel-pull step racing this same call) can
-- legitimately increase some slot's count at exactly the wrong moment --
-- an earlier version of this function treated ANY slot's count going up
-- as "found the chest" and happily recovered cobblestone into M.SLOT
-- while the real chest was left behind in the world. A before/after
-- snapshot plus an item-name check catches that: only a slot whose NEW
-- item is actually ITEM_NAME counts as a real recovery (via
-- table.transferTo if it landed somewhere other than M.SLOT directly),
-- and a genuine failure to reappear as itself ANYWHERE is reported
-- clearly rather than let the caller carry on with the wrong item
-- sitting in M.SLOT, believing it still has its home-link chest.
function M.pickUp(direction)
  local dig = turtle.dig
  if direction == "up" then dig = turtle.digUp
  elseif direction == "down" then dig = turtle.digDown end

  local function isChest(slot)
    local detail = turtle.getItemDetail(slot)
    return detail ~= nil and detail.name == ITEM_NAME
  end

  local function dropAwayFromChest()
    if direction ~= "down" then return turtle.dropDown() end
    return turtle.drop()
  end

  local function firstEmptySlot(except)
    for slot = 1, 16 do
      if slot ~= except and turtle.getItemCount(slot) == 0 then
        return slot
      end
    end
    return nil
  end

  local before = {}
  for slot = 1, 16 do before[slot] = turtle.getItemCount(slot) end

  local slotDetail = turtle.getItemDetail(M.SLOT)
  if slotDetail and slotDetail.name ~= ITEM_NAME then
    turtle.select(M.SLOT)
    dropAwayFromChest()
    if turtle.getItemCount(M.SLOT) > 0 and not firstEmptySlot(M.SLOT) then
      return false, "not picking the home-link chest up while slot " .. M.SLOT
        .. " is blocked and no spare slot is available"
    end
  end

  turtle.select(M.SLOT)
  local ok, reason = dig()
  if not ok then
    return false, "could not pick the home-link chest back up: " .. tostring(reason)
  end

  if turtle.getItemCount(M.SLOT) > before[M.SLOT] and isChest(M.SLOT) then
    markPickup("picked_up")
    return true
  end

  -- Didn't land in M.SLOT as the right item -- find whichever slot
  -- actually gained a NEW chest (not just any increased count -- see
  -- the function comment above) and move it over, rather than leave it
  -- stranded in the wrong place or accept a false positive.
  for slot = 1, 16 do
    if slot ~= M.SLOT and turtle.getItemCount(slot) > (before[slot] or 0) and isChest(slot) then
      if turtle.getItemCount(M.SLOT) > 0 and not isChest(M.SLOT) then
        local spare = firstEmptySlot(slot)
        if not spare then
          markPickup("pickup_failed", "slot " .. M.SLOT .. " blocked and no spare slot is available")
          return false, "dug the home-link chest into slot " .. slot
            .. " but slot " .. M.SLOT .. " is blocked and no spare slot is available"
        end
        turtle.select(M.SLOT)
        if not turtle.transferTo(spare) then
          markPickup("pickup_failed", "could not clear blocked slot " .. M.SLOT)
          return false, "dug the home-link chest into slot " .. slot
            .. " but could not clear blocked slot " .. M.SLOT
        end
      end
      turtle.select(slot)
      if not turtle.transferTo(M.SLOT) then
        markPickup("pickup_failed", "could not move recovered chest back to slot " .. M.SLOT)
        return false, "dug the home-link chest into slot " .. slot
          .. " but could not move it back to slot " .. M.SLOT
      end
      if isChest(M.SLOT) then
        markPickup("picked_up", "recovered from slot " .. slot)
        return true, "recovered from slot " .. slot .. " instead of landing directly in " .. M.SLOT
      end
    end
  end

  markPickup("pickup_failed", "dug chest but no ender chest item appeared in inventory")
  return false, "dug the home-link chest but it never reappeared in inventory -- may be lost"
end

_G.__HOMELINK_MODULE = M
return M

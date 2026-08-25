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

local M = {}

M.SLOT = 16
-- Confirmed live (turtlectl.py send + turtle.dig() against a real placed
-- one) -- EnderStorage's actual registry name, not a guess. Used only to
-- verify a RECOVERY candidate in M.pickUp() below, never to gate
-- M.place() -- a caller already knows slot 16 is supposed to hold this,
-- and M.place() trusts that positionally, same as before.
local ITEM_NAME = "enderstorage:ender_chest"

-- Tries front, then up, then down, and places the chest in whichever
-- one is actually open. Deliberately doesn't dig to clear a blocked
-- direction -- unlike a mining job's own forward step (already vetted
-- as safe to dig by that job's own logic), blindly digging just to make
-- room for this would risk digging into something the caller never
-- intended to touch. A caller that hits "nowhere to place it" here can
-- simply try again later (a different position, a leg later), or fall
-- back to whatever else is available. Returns the direction it
-- succeeded in ("front", "up", or "down"), or nil, reason on failure.
function M.place()
  if turtle.getItemCount(M.SLOT) == 0 then
    return nil, "no home-link chest in slot " .. M.SLOT
  end
  turtle.select(M.SLOT)

  if turtle.place() then return "front" end
  if turtle.placeUp() then return "up" end
  if turtle.placeDown() then return "down" end
  return nil, "no open space to place the home-link chest (front/up/down all blocked)"
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

  local before = {}
  for slot = 1, 16 do before[slot] = turtle.getItemCount(slot) end

  turtle.select(M.SLOT)
  local ok, reason = dig()
  if not ok then
    return false, "could not pick the home-link chest back up: " .. tostring(reason)
  end

  local function isChest(slot)
    local detail = turtle.getItemDetail(slot)
    return detail ~= nil and detail.name == ITEM_NAME
  end

  if turtle.getItemCount(M.SLOT) > before[M.SLOT] and isChest(M.SLOT) then
    return true
  end

  -- Didn't land in M.SLOT as the right item -- find whichever slot
  -- actually gained a NEW chest (not just any increased count -- see
  -- the function comment above) and move it over, rather than leave it
  -- stranded in the wrong place or accept a false positive.
  for slot = 1, 16 do
    if slot ~= M.SLOT and turtle.getItemCount(slot) > (before[slot] or 0) and isChest(slot) then
      turtle.select(slot)
      turtle.transferTo(M.SLOT)
      if isChest(M.SLOT) then
        return true, "recovered from slot " .. slot .. " instead of landing directly in " .. M.SLOT
      end
    end
  end

  return false, "dug the home-link chest but it never reappeared in inventory -- may be lost"
end

_G.__HOMELINK_MODULE = M
return M

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
-- confirms it actually landed back in M.SLOT before reporting success --
-- CC:Tweaked gives a dig's collected item to the CURRENTLY SELECTED slot
-- first (as long as that slot is empty), which M.SLOT always is right
-- before this call (it's only ever non-empty while the chest is safely
-- in inventory, not placed), so selecting M.SLOT first is normally
-- enough on its own. This still verifies rather than assumes: a
-- before/after snapshot of every slot catches the item landing somewhere
-- else instead (recovered via table.transferTo, not silently left
-- there), and a genuine failure to reappear ANYWHERE is reported
-- clearly rather than let the caller carry on as if it still has its
-- home-link chest when it doesn't.
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

  if turtle.getItemCount(M.SLOT) > before[M.SLOT] then
    return true
  end

  -- Didn't land in M.SLOT as expected -- find whichever slot's count
  -- actually went up and move it over, rather than leave it stranded in
  -- the wrong place (see the module comment above on why this is
  -- checked instead of trusted blindly).
  for slot = 1, 16 do
    if slot ~= M.SLOT and turtle.getItemCount(slot) > (before[slot] or 0) then
      turtle.select(slot)
      turtle.transferTo(M.SLOT)
      if turtle.getItemCount(M.SLOT) > before[M.SLOT] then
        return true, "recovered from slot " .. slot .. " instead of landing directly in " .. M.SLOT
      end
    end
  end

  return false, "dug the home-link chest but it never reappeared in inventory -- may be lost"
end

_G.__HOMELINK_MODULE = M
return M

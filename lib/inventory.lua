--[[----------------------------------------------------------------------
  lib/inventory.lua -- inventory space/unloading helpers, so any job that
  needs "am I full" and "empty myself into a chest" doesn't have to
  re-derive slot-scanning logic on its own.
------------------------------------------------------------------------]]

if _G.__INVENTORY_MODULE then return _G.__INVENTORY_MODULE end

local homelink = dofile("/lib/homelink.lua")

local M = {}

local SLOTS = 16
-- lib/homelink.lua's shared home-link Ender Chest permanently lives in
-- the LAST slot whenever it isn't currently placed mid-transfer -- never
-- cargo space, and never a candidate for M.dropAll() to empty out (that
-- would mean literally dropping the fleet's shared link chest into
-- whatever unrelated chest is being unloaded into). Keep in sync with
-- lib/homelink.lua's own M.SLOT if this ever changes. CARGO_SLOTS being
-- exactly SLOTS-1 (rather than an arbitrary excluded slot in the middle)
-- is what lets every loop below stay a plain `1, CARGO_SLOTS` range.
local CARGO_SLOTS = SLOTS - 1

-- Number of completely empty CARGO slots (never counts the reserved
-- home-link slot, occupied or not -- see CARGO_SLOTS above). This, not
-- remaining space in existing stacks, is what decides whether the
-- turtle can still pick up a block of a brand new type -- a half-full
-- stack of cobblestone doesn't help when the next block dug is iron ore.
function M.emptySlotCount()
  local count = 0
  for slot = 1, CARGO_SLOTS do
    if turtle.getItemCount(slot) == 0 then count = count + 1 end
  end
  return count
end

-- True once there's no empty CARGO slot left at all.
function M.isFull()
  return M.emptySlotCount() == 0
end

-- True once every CARGO slot is empty -- NOT just "not full anymore"
-- (even one freed slot satisfies that). dom-main/mining/vertical.lua's
-- own unloadIfFull() keeps searching for more chests until this is true
-- (or it genuinely runs out of chests to try) -- confirmed live:
-- stopping the moment the inventory was merely no longer completely
-- full left a turtle heading back to mining with 14 of 16 slots still
-- full, after the first chest it found only had room for 2.
function M.isEmpty()
  return M.emptySlotCount() == CARGO_SLOTS
end

-- Every nonempty slot as { slot, name, count }, in slot order.
function M.here()
  local items = {}
  for slot = 1, SLOTS do
    local detail = turtle.getItemDetail(slot)
    if detail then
      items[#items + 1] = { slot = slot, name = detail.name, count = detail.count }
    end
  end
  return items
end

-- Prints a human-readable inventory listing and returns the same data as
-- M.here(), so it's equally useful typed interactively (incl. over the
-- remote console) or called from a script.
function M.report()
  local items = M.here()
  if #items == 0 then
    print("inventory: empty")
  else
    for _, item in ipairs(items) do
      print(("slot %2d: %3dx %s"):format(item.slot, item.count, item.name))
    end
  end
  -- Cargo-slot count, not SLOTS -- matches what M.emptySlotCount() above
  -- now means (see CARGO_SLOTS), even though the listing above it can
  -- still include the reserved slot (informational: confirms the
  -- home-link chest is actually present).
  print(("%d/%d slots empty"):format(M.emptySlotCount(), CARGO_SLOTS))
  return items
end

-- Drops every nonempty CARGO slot's contents in the given direction
-- ("front" (default), "up", or "down" -- matches lib/chestfinder.lua's
-- returned `direction`). Never touches the reserved home-link slot (see
-- CARGO_SLOTS above), NOR any cargo slot that happens to hold the
-- home-link chest item itself -- that item is moved back to slot 16
-- before any drop is attempted. This is what's dumping into some OTHER,
-- unrelated chest (a real physical one found by lib/chestfinder.lua),
-- and the home-link chest isn't cargo to get rid of there no matter
-- which slot it's currently sitting in.
-- Returns how many slots were emptied. Restores whichever slot was
-- selected beforehand. A slot that fails to drop (destination full,
-- nothing there to drop into) is simply left as-is -- this doesn't
-- retry or hunt for another container, so a chest that's itself full
-- means those items just stay in inventory.
--
-- drop()'s own return value is deliberately NOT trusted on its own --
-- confirmed live against a sophisticatedstorage chest: it reported
-- success (true) for a slot whose full stack never actually left the
-- turtle, with the chest confirmed not full at the time -- some
-- destination inventories' APIs apparently tell CC:Tweaked "accepted"
-- even when nothing was. turtle.getItemCount(slot) == 0 is checked
-- straight after every drop() to catch exactly this, so `emptied` (and
-- anything that trusts it, e.g. this file's own M.isEmpty()) reflects
-- what's actually still in the turtle's inventory, not what a
-- destination merely claimed.
function M.dropAll(direction)
  direction = direction or "front"
  local drop = turtle.drop
  if direction == "up" then drop = turtle.dropUp
  elseif direction == "down" then drop = turtle.dropDown end

  local originalSlot = turtle.getSelectedSlot()
  local emptied = 0
  for slot = 1, CARGO_SLOTS do
    if homelink.isItem(slot) then
      homelink.moveToReserved(slot)
    elseif turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      drop()
      if turtle.getItemCount(slot) == 0 then emptied = emptied + 1 end
    end
  end
  turtle.select(originalSlot)
  return emptied
end

_G.__INVENTORY_MODULE = M
return M

--[[----------------------------------------------------------------------
  lib/inventory.lua -- inventory space/unloading helpers, so any job that
  needs "am I full" and "empty myself into a chest" doesn't have to
  re-derive slot-scanning logic on its own.
------------------------------------------------------------------------]]

if _G.__INVENTORY_MODULE then return _G.__INVENTORY_MODULE end

local M = {}

local SLOTS = 16

-- Number of completely empty slots. This, not remaining space in
-- existing stacks, is what decides whether the turtle can still pick up
-- a block of a brand new type -- a half-full stack of cobblestone
-- doesn't help when the next block dug is iron ore.
function M.emptySlotCount()
  local count = 0
  for slot = 1, SLOTS do
    if turtle.getItemCount(slot) == 0 then count = count + 1 end
  end
  return count
end

-- True once there's no empty slot left at all.
function M.isFull()
  return M.emptySlotCount() == 0
end

-- True once every slot is empty -- NOT just "not full anymore" (even
-- one freed slot satisfies that). dom-main/mining/vertical.lua's own
-- unloadIfFull() keeps searching for more chests until this is true (or
-- it genuinely runs out of chests to try) -- confirmed live: stopping
-- the moment the inventory was merely no longer completely full left a
-- turtle heading back to mining with 14 of 16 slots still full, after
-- the first chest it found only had room for 2.
function M.isEmpty()
  return M.emptySlotCount() == SLOTS
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
  print(("%d/%d slots empty"):format(M.emptySlotCount(), SLOTS))
  return items
end

-- Drops every nonempty slot's contents in the given direction ("front"
-- (default), "up", or "down" -- matches lib/chestfinder.lua's returned
-- `direction`). Returns how many slots were emptied. Restores whichever
-- slot was selected beforehand. A slot that fails to drop (destination
-- full, nothing there to drop into) is simply left as-is -- this doesn't
-- retry or hunt for another container, so a chest that's itself full
-- means those items just stay in inventory.
function M.dropAll(direction)
  direction = direction or "front"
  local drop = turtle.drop
  if direction == "up" then drop = turtle.dropUp
  elseif direction == "down" then drop = turtle.dropDown end

  local originalSlot = turtle.getSelectedSlot()
  local emptied = 0
  for slot = 1, SLOTS do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      if drop() then emptied = emptied + 1 end
    end
  end
  turtle.select(originalSlot)
  return emptied
end

_G.__INVENTORY_MODULE = M
return M

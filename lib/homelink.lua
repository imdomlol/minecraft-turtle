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
local routing = dofile("/lib/routing.lua")

local M = {}

M.SLOT = 16
-- Confirmed live (turtlectl.py send + turtle.dig() against a real placed
-- one) -- EnderStorage's actual registry name, not a guess. Used only to
-- verify a RECOVERY candidate in M.pickUp() below, never to gate
-- M.place() -- a caller already knows slot 16 is supposed to hold this,
-- and M.place() trusts that positionally, same as before.
local ITEM_NAME = "enderstorage:ender_chest"
local STATE_PATH = "/state/homelink.state"
local BLACKBOX_PATH = "/state/homelink_blackbox.state"
local DELTA = {
  north = { x = 0,  z = -1 },
  east  = { x = 1,  z = 0 },
  south = { x = 0,  z = 1 },
  west  = { x = -1, z = 0 },
}
local blackbox
local inspectDirection

local function isProtected(data)
  return data ~= nil and (nav.isChest(data.name) or nav.isComputerCraftBlock(data.name))
end

local function now()
  return os.epoch and os.epoch("utc") or os.clock()
end

local function safeDetail(slot)
  local detail = turtle.getItemDetail(slot)
  if not detail then return { slot = slot, empty = true } end
  return { slot = slot, name = detail.name, count = detail.count }
end

local function safeInspect(direction)
  local found, data = inspectDirection(direction)
  if not found then return { direction = direction, present = false } end
  return { direction = direction, present = true, name = data.name, state = data.state }
end

local function hasEnderChest(value)
  if type(value) ~= "table" then return value == ITEM_NAME end
  if value.name == ITEM_NAME then return true end
  for _, child in pairs(value) do
    if hasEnderChest(child) then return true end
  end
  return false
end

local function saveBlackbox()
  if not (blackbox and blackbox.sawEnderChest) then return end
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(BLACKBOX_PATH, "w")
  f.write(textutils.serializeJSON(blackbox))
  f.close()
end

local function beginBlackbox(reason)
  blackbox = {
    reason = reason,
    startedAt = now(),
    events = {},
    sawEnderChest = false,
  }
end

function M.blackbox(event, data)
  if not blackbox then beginBlackbox("implicit") end
  local entry = { at = now(), event = event, data = data }
  blackbox.events[#blackbox.events + 1] = entry
  if hasEnderChest(data) then blackbox.sawEnderChest = true end
  saveBlackbox()
end

function M.getBlackbox()
  if not fs.exists(BLACKBOX_PATH) then return nil end
  local f = fs.open(BLACKBOX_PATH, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

function M.blackboxSlot(label, slot)
  M.blackbox(label, safeDetail(slot))
end

function M.blackboxInspect(label, direction)
  M.blackbox(label, safeInspect(direction))
end

function M.blackboxInventory(label)
  local items = {}
  for slot = 1, 16 do items[#items + 1] = safeDetail(slot) end
  M.blackbox(label, items)
end

function M.isItem(slot)
  local detail = turtle.getItemDetail(slot)
  return detail ~= nil and detail.name == ITEM_NAME
end

local function firstEmptySlot(except)
  for slot = 1, 16 do
    if slot ~= except and turtle.getItemCount(slot) == 0 then
      return slot
    end
  end
  return nil
end

local function clearReservedSlot(avoidSlot)
  if turtle.getItemCount(M.SLOT) == 0 or M.isItem(M.SLOT) then return true end
  local spare = firstEmptySlot(avoidSlot or M.SLOT)
  if spare then
    turtle.select(M.SLOT)
    return turtle.transferTo(spare)
  end
  turtle.select(M.SLOT)
  return turtle.dropDown() or turtle.drop() or turtle.dropUp()
end

function M.moveToReserved(slot)
  if not slot or slot == M.SLOT then return M.isItem(M.SLOT) end
  if not M.isItem(slot) then return false, "slot " .. tostring(slot) .. " is not the home-link chest" end
  if not clearReservedSlot(slot) then
    return false, "could not clear slot " .. M.SLOT .. " for the home-link chest"
  end
  turtle.select(slot)
  if not turtle.transferTo(M.SLOT) then
    return false, "could not move home-link chest from slot " .. slot .. " to " .. M.SLOT
  end
  return M.isItem(M.SLOT)
end

function M.findInInventory()
  if M.isItem(M.SLOT) then return M.SLOT end
  for slot = 1, 16 do
    if slot ~= M.SLOT and M.isItem(slot) then return slot end
  end
  return nil
end

function M.normalizeInventory()
  local slot = M.findInInventory()
  if not slot then return false, "no home-link chest in inventory" end
  if slot == M.SLOT then return true, "already in slot " .. M.SLOT end
  return M.moveToReserved(slot)
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

-- `forensics` (optional): extra diagnostic fields merged straight into
-- the saved state (e.g. { preDig = <block name seen right before
-- digging, or false>, floorRetry = true }) -- see M.pickUp()'s own
-- comments for why these specific fields exist: distinguishing "already
-- gone before this turtle touched it" from "genuinely dug it and lost
-- the drop" needed more than a single free-text reason string to
-- diagnose after the fact.
local function markPickup(status, reason, forensics)
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
  if forensics then
    for k, v in pairs(forensics) do previous[k] = v end
  end
  saveState(previous)
end

function M.getState()
  return loadState()
end

local function placed(direction, gpsOk, gpsInfo)
  markPlaced(direction, gpsOk, gpsInfo)
  M.blackbox("place.succeeded", { direction = direction, gpsOk = gpsOk == true, gpsInfo = gpsInfo })
  M.blackboxInspect("place.inspect_expected_block_after_place", direction)
  return direction
end

inspectDirection = function(direction)
  if direction == "up" then return turtle.inspectUp() end
  if direction == "down" then return turtle.inspectDown() end
  return turtle.inspect()
end

-- Steps into the space just dug, briefly, and back out. turtle.dig()
-- only reports whether the BLOCK broke -- collecting the resulting item
-- is a separate step that (per CC:Tweaked/Minecraft) happens by the
-- turtle occupying or passing through that space, not from dig() itself.
-- Confirmed live earlier this session (lib/chestfinder.lua's incidental
-- travel-digging): a dug item can sit as an uncollected floor entity for
-- a tick or two rather than landing in inventory immediately. This is a
-- last-resort recovery attempt for M.pickUp()'s "dug it, nothing
-- appeared" case below -- cheap, and directionally safe (moves back the
-- way it came, into a space it just confirmed is now empty).
local function tryCollectFloorItem(direction)
  local move, back
  if direction == "up" then move, back = turtle.up, turtle.down
  elseif direction == "down" then move, back = turtle.down, turtle.up
  else move, back = turtle.forward, turtle.back end

  if not move() then return false end
  sleep(0.5)
  back()
  return true
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
  beginBlackbox("home-link place/use/pickup attempt")
  M.blackboxSlot("place.slot16_before_place", M.SLOT)
  if not M.isItem(M.SLOT) then
    local normalized = M.normalizeInventory()
    M.blackbox("place.normalize_inventory", { ok = normalized == true })
    M.blackboxSlot("place.slot16_after_normalize", M.SLOT)
    if not normalized then
      -- Deliberately NOT trying M.recover() here (a previous version of
      -- this function did) -- confirmed live, it can hang the entire
      -- job: M.recover()'s routing.goto() back to a recorded "placed"
      -- position takes no shouldStop at all, and M.place() is called
      -- from dom-main/mining/vertical.lua's tryHomeLink() every single
      -- time a turtle's inventory fills up during ordinary mining, with
      -- no cooperative-stop check anywhere in that whole call chain --
      -- so a turtle stuck mid-recovery here can't honor ANY interrupt,
      -- including an operator's plain stop, until that trip finishes on
      -- its own. A stray "placed" chest is exactly what dom-main/
      -- controller/scheduler.lua's M.checkHomeLink() sweep already
      -- exists to fix instead: it runs recovery as its own top-level
      -- "recover_home_link" job (dom-main/turtle_main.lua), the same
      -- cooperative job.request() switch goto/stop already use, which
      -- CAN be interrupted like any other job -- and dom-main/
      -- turtle_main.lua's own boot-time M.recover() call covers the
      -- reboot case. This function just fails fast instead, same as
      -- always.
      return nil, "no home-link chest in slot " .. M.SLOT
    end
  end
  local gpsOk, gpsInfo = nav.reacquireGPS()
  M.blackbox("place.gps_reacquire", { ok = gpsOk == true, result = gpsInfo })
  turtle.select(M.SLOT)
  M.blackbox("place.select_slot16", { selected = turtle.getSelectedSlot() })

  if turtle.place() then return placed("front", gpsOk, gpsInfo) end
  if turtle.placeUp() then return placed("up", gpsOk, gpsInfo) end
  if turtle.placeDown() then return placed("down", gpsOk, gpsInfo) end

  local found, data = turtle.inspect()
  M.blackbox("place.front_blocked", { found = found, name = found and data.name or nil })
  if found and not isProtected(data) and turtle.dig() then
    turtle.select(M.SLOT)
    M.blackbox("place.front_cleared_for_retry", { selected = turtle.getSelectedSlot() })
    if turtle.place() then return placed("front", gpsOk, gpsInfo) end
  end
  found, data = turtle.inspectUp()
  M.blackbox("place.up_blocked", { found = found, name = found and data.name or nil })
  if found and not isProtected(data) and turtle.digUp() then
    turtle.select(M.SLOT)
    M.blackbox("place.up_cleared_for_retry", { selected = turtle.getSelectedSlot() })
    if turtle.placeUp() then return placed("up", gpsOk, gpsInfo) end
  end
  found, data = turtle.inspectDown()
  M.blackbox("place.down_blocked", { found = found, name = found and data.name or nil })
  if found and not isProtected(data) and turtle.digDown() then
    turtle.select(M.SLOT)
    M.blackbox("place.down_cleared_for_retry", { selected = turtle.getSelectedSlot() })
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
local function attemptPickUp(direction)
  local dig = turtle.dig
  if direction == "up" then dig = turtle.digUp
  elseif direction == "down" then dig = turtle.digDown end

  local function isChest(slot)
    return M.isItem(slot)
  end

  local function dropAwayFromChest()
    if direction ~= "down" then return turtle.dropDown() end
    return turtle.drop()
  end

  M.blackboxInspect("pickup.inspect_expected_block_before_cleanup", direction)
  M.blackboxSlot("pickup.slot16_before_cleanup", M.SLOT)
  local slotDetail = turtle.getItemDetail(M.SLOT)
  if slotDetail and slotDetail.name ~= ITEM_NAME then
    turtle.select(M.SLOT)
    local dropped = dropAwayFromChest()
    M.blackbox("pickup.slot16_wrong_item_drop_away", {
      item = { name = slotDetail.name, count = slotDetail.count },
      dropped = dropped == true,
    })
    if turtle.getItemCount(M.SLOT) > 0 then
      local spare = firstEmptySlot(M.SLOT)
      M.blackbox("pickup.slot16_still_blocked_after_drop", { spare = spare })
      if not spare then
        return false, "not picking the home-link chest up while slot " .. M.SLOT
          .. " is blocked and no spare slot is available"
      end
      local moved = turtle.transferTo(spare)
      M.blackbox("pickup.slot16_wrong_item_moved_to_spare", { spare = spare, moved = moved == true })
      if not moved then
        return false, "not picking the home-link chest up because slot " .. M.SLOT
          .. " could not be cleared"
      end
    end
  end
  M.blackboxSlot("pickup.slot16_after_cleanup", M.SLOT)

  -- Confirmed live (4 of 6 turtles, same night, same exact failure):
  -- dig() can report success (the block broke) while no ender chest item
  -- ever appears anywhere in inventory afterward -- happened at
  -- different positions, y-levels, and directions, so it isn't one bad
  -- spot. Checking what was actually there right before digging (rather
  -- than trusting M.place()'s minutes-old record) separates two very
  -- different failures: something else already removed/replaced the
  -- block before this turtle ever touched it (preDig.found == false, or
  -- a name that isn't a chest at all) vs. this turtle's own dig()
  -- genuinely destroyed the real chest and its drop never showed up
  -- (preDig confirms a chest was really there). Recorded either way for
  -- forensics -- see markPickup() calls below.
  local preDigFound, preDigData = inspectDirection(direction)
  local preDigName = preDigFound and preDigData.name or nil
  M.blackbox("pickup.inspect_expected_block_before_dig", {
    found = preDigFound == true,
    name = preDigName,
  })
  if not (preDigFound and nav.isChest(preDigName)) then
    markPickup("pickup_failed", "expected chest not present before digging (saw: "
      .. tostring(preDigName or "nothing") .. ")", { preDig = preDigName or false })
    return false, "home-link chest is no longer at the expected position (saw: "
      .. tostring(preDigName or "nothing") .. ") -- something else happened to it before pickup"
  end

  local before = {}
  for slot = 1, 16 do before[slot] = turtle.getItemCount(slot) end

  turtle.select(M.SLOT)
  M.blackbox("pickup.select_slot16_before_dig", {
    selected = turtle.getSelectedSlot(),
    empty = turtle.getItemCount(M.SLOT) == 0,
  })
  local ok, reason = dig()
  M.blackbox("pickup.dig_expected_block", { ok = ok == true, reason = reason })
  if not ok then
    return false, "could not pick the home-link chest back up: " .. tostring(reason)
  end

  M.blackboxSlot("pickup.slot16_after_dig", M.SLOT)
  M.blackboxInventory("pickup.inventory_after_dig")
  M.blackboxInspect("pickup.inspect_expected_location_after_dig", direction)
  if turtle.getItemCount(M.SLOT) > before[M.SLOT] and isChest(M.SLOT) then
    M.blackboxSlot("pickup.slot16_direct_success", M.SLOT)
    M.blackboxInspect("pickup.inspect_expected_location_direct_success", direction)
    markPickup("picked_up")
    return true
  end

  -- Didn't land in M.SLOT as the right item -- find whichever slot
  -- actually gained a NEW chest (not just any increased count -- see
  -- the function comment above) and move it over, rather than leave it
  -- stranded in the wrong place or accept a false positive.
  for slot = 1, 16 do
    if slot ~= M.SLOT and turtle.getItemCount(slot) > (before[slot] or 0) and isChest(slot) then
      M.blackbox("pickup.found_ender_chest_in_other_slot", {
        slot = slot,
        count = turtle.getItemCount(slot),
      })
      if turtle.getItemCount(M.SLOT) > 0 and not isChest(M.SLOT) then
        if not clearReservedSlot(slot) then
          markPickup("pickup_failed", "slot " .. M.SLOT .. " blocked and no spare slot is available")
          return false, "dug the home-link chest into slot " .. slot
            .. " but slot " .. M.SLOT .. " is blocked and no spare slot is available"
        end
      end
      turtle.select(slot)
      local moved = turtle.transferTo(M.SLOT)
      M.blackbox("pickup.move_recovered_chest_to_slot16", { from = slot, moved = moved == true })
      if not moved then
        markPickup("pickup_failed", "could not move recovered chest back to slot " .. M.SLOT)
        return false, "dug the home-link chest into slot " .. slot
          .. " but could not move it back to slot " .. M.SLOT
      end
      M.blackboxInventory("pickup.inventory_after_recovered_from_other_slot")
      M.blackboxInspect("pickup.inspect_expected_location_after_other_slot_recovery", direction)
      if isChest(M.SLOT) then
        markPickup("picked_up", "recovered from slot " .. slot)
        return true, "recovered from slot " .. slot .. " instead of landing directly in " .. M.SLOT
      end
    end
  end

  -- Confirmed the block WAS the chest right before digging (preDig check
  -- above), dig() reported success, and yet nothing matching ITEM_NAME
  -- showed up in any slot -- the item may simply not have been auto-
  -- collected yet (see tryCollectFloorItem()'s own comment: this exact
  -- gap already produced a false "lost" reading once earlier this
  -- session, via lib/chestfinder.lua's incidental travel-digging). One
  -- cheap last-resort attempt before giving up for good.
  if tryCollectFloorItem(direction) then
    for slot = 1, 16 do
      if turtle.getItemCount(slot) > (before[slot] or 0) and isChest(slot) then
        if slot ~= M.SLOT then
          if turtle.getItemCount(M.SLOT) > 0 and not isChest(M.SLOT) and not clearReservedSlot(slot) then
            markPickup("pickup_failed", "recovered via floor pickup into slot " .. slot
              .. " but slot " .. M.SLOT .. " is blocked and no spare slot is available")
            return false, "recovered the home-link chest off the floor into slot " .. slot
              .. " but slot " .. M.SLOT .. " is blocked and no spare slot is available"
          end
          turtle.select(slot)
          turtle.transferTo(M.SLOT)
        end
        M.blackboxInventory("pickup.inventory_after_floor_recovery_move")
        M.blackboxInspect("pickup.inspect_expected_location_after_floor_recovery", direction)
        if isChest(M.SLOT) then
          markPickup("picked_up", "recovered from the floor after dig() alone didn't collect it")
          return true, "recovered from the floor (not collected directly by dig())"
        end
      end
    end
  end

  M.blackboxInventory("pickup.inventory_final_failure_scan")
  M.blackboxInspect("pickup.inspect_expected_location_final_failure", direction)
  markPickup("pickup_failed", "confirmed a real chest was dug (preDig saw " .. tostring(preDigName)
    .. ") but no ender chest item ever appeared in inventory, including after a floor-pickup retry -- genuinely lost",
    { preDig = preDigName, floorRetry = true })
  return false, "dug the home-link chest but it never reappeared in inventory, even after a floor-pickup retry -- may be lost"
end

-- Thin wrapper around attemptPickUp() above: guarantees the recorded
-- "placed" state gets resolved (to "pickup_failed") on ANY failure, even
-- one attemptPickUp() itself doesn't explicitly markPickup() for.
--
-- Confirmed live, twice: several of attemptPickUp()'s own early-return
-- branches (a plain dig() failure, "slot 16 blocked and no spare slot")
-- never called markPickup() at all -- and dom-main/mining/vertical.lua's
-- tryHomeLink() calls this DIRECTLY (not through M.recover(), which
-- previously had its own separate catch-all wrapped around its OWN call
-- to this function) -- so a turtle's very FIRST pickup attempt, right
-- after placing, could fail via one of those branches and leave the
-- record stuck "placed" under its original timestamp with nothing ever
-- correcting it, regardless of M.recover()'s own safety net. Patching
-- every individual branch is exactly the kind of thing that's easy to
-- get wrong again the next time one gets added -- a single wrapper here
-- covers all of them, present and future, for every caller, without
-- needing to remember to call markPickup() at each new return point.
function M.pickUp(direction)
  local ok, err = attemptPickUp(direction)
  if not ok then
    local stillPlaced = loadState()
    if stillPlaced and stillPlaced.status == "placed" then
      markPickup("pickup_failed", err)
    end
  end
  return ok, err
end

function M.recover()
  local inventoryOk, inventoryInfo = M.normalizeInventory()
  if inventoryOk then
    -- Clears a stale "placed" record left behind by whatever put the
    -- chest back in inventory without going through M.pickUp() itself
    -- (a boot-time recovery on a PREVIOUS boot, an operator's manual
    -- fix, another call to M.recover()) -- otherwise it sits there with
    -- its original timestamp forever, and dom-main/controller/
    -- scheduler.lua's M.checkHomeLink() sweep (which keys off
    -- status == "placed") keeps re-alerting on a chest that's actually
    -- already safe. Confirmed live: exactly this kept a turtle's chest
    -- reported "stuck" indefinitely after it had genuinely recovered.
    local saved = loadState()
    if saved and saved.status == "placed" then
      markPickup("picked_up", "already in inventory")
    end
    return true, inventoryInfo
  end

  local saved = loadState()
  if not saved or saved.status ~= "placed" or not saved.turtle or not saved.direction then
    return false, "no home-link chest in inventory and no placed chest recorded"
  end

  local target = saved.turtle
  local reached, reachInfo = routing.goto(target.x, target.y, target.z, { tolerance = 0, allowDig = "safe" })
  if not reached then
    -- markPickup() here too (unlike before) -- otherwise this stays
    -- "placed" forever with its original timestamp even though the
    -- attempt is over, and M.checkHomeLink() just keeps re-triggering
    -- the exact same doomed attempt every sweep. Recorded as
    -- "pickup_failed" (same status M.pickUp()'s own failure branches
    -- use), not silently dropped -- still visible via M.getState() for
    -- an operator to actually go check on.
    local reason = "could not reach recorded home-link chest position: " .. tostring(reachInfo and reachInfo.reason)
    markPickup("pickup_failed", reason)
    return false, reason
  end
  nav.face(target.heading or target.facing)

  local found, data = inspectDirection(saved.direction)
  if not (found and nav.isChest(data.name)) then
    local reason = "recorded home-link chest is no longer present at the saved position"
    markPickup("pickup_failed", reason)
    return false, reason
  end

  -- M.pickUp() itself now guarantees the record gets resolved to
  -- "pickup_failed" on any failure (see its own comment) -- no separate
  -- catch-all needed here anymore.
  local picked, pickInfo = M.pickUp(saved.direction)
  if not picked then return false, pickInfo end
  return true, pickInfo or "recovered placed home-link chest"
end

_G.__HOMELINK_MODULE = M
return M

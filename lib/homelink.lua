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

  This module mostly just handles getting the chest itself into and out
  of the world reliably. Once M.place() returns a direction, a caller
  driving its own multi-step transfer (e.g. dom-main/mining/vertical.lua's
  tryHomeLink(), which also has to interleave a cargo deposit) should use
  the EXISTING primitives directly -- lib/inventory.lua's M.dropAll() for
  loot, lib/fuel.lua's M.refuelFrom() for fuel -- rather than duplicating
  either here. M.refuelTo() below is the one exception: a self-contained
  place -> refuel -> pick back up cycle for a caller that ONLY needs fuel
  (dom-main/controller/scheduler.lua's stranded-turtle self-serve path),
  with no cargo step to interleave and no reason to make every such
  caller re-derive the same place/retry/pickup sequence on its own.
------------------------------------------------------------------------]]

if _G.__HOMELINK_MODULE then return _G.__HOMELINK_MODULE end

local nav = dofile("/lib/nav.lua")
local routing = dofile("/lib/routing.lua")
local fuel = dofile("/lib/fuel.lua")
local stats = dofile("/lib/stats.lua")
local safeserialize = dofile("/lib/safeserialize.lua")

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

-- Confirmed live: a turtle stuck retrying recovery for several minutes
-- (many M.recover() -> attemptPickUp() calls in a row -- attemptPickUp()
-- never calls beginBlackbox() itself, only M.place() does, so every
-- retry just kept appending to the SAME session's events) crashed the
-- whole job on "Cannot serialize table with repeated entries" -- most
-- likely CC:Tweaked's serializer choking on however large/deep that had
-- grown, though the exact trigger wasn't pinned down. Either way, a
-- LOGGING call being able to crash the job it's merely trying to record
-- is the real bug: this must never be fatal. pcall here (defense in
-- depth) plus the size cap below (the likely actual fix) both guard
-- against it independently.
local function saveBlackbox()
  if not (blackbox and blackbox.sawEnderChest) then return end
  if not fs.exists("/state") then fs.makeDir("/state") end
  local ok, encoded = safeserialize.encode(blackbox)
  if not ok then
    print("homelink: could not save blackbox -- " .. tostring(encoded))
    return
  end
  local f = fs.open(BLACKBOX_PATH, "w")
  f.write(encoded)
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

-- Permanent, timestamped archive of the blackbox session for every
-- CONFIRMED chest loss (see markLost() below -- never for a merely
-- retriable hiccup). Unlike M.blackbox()'s own single rolling session
-- (overwritten by the very next M.place() call, e.g. once a turtle
-- recovers or an operator manually fixes things), one file per incident
-- here, so it survives exactly the kind of after-the-fact investigation
-- that had nothing left to look at tonight -- confirmed live: by the
-- time this was needed, the live session had already been overwritten
-- by a fresh, healthy one.
local INCIDENTS_DIR = "/state/homelink_incidents"
-- Oldest pruned first once this many incident files pile up -- this is a
-- forensic log, not unbounded storage, and disk here is a real, shared,
-- bounded per-computer quota (see dom-main/controller/worldstore.lua's
-- own MIN_FREE_SPACE_BYTES comment for the exact failure this avoids).
-- Chest losses should be rare; 50 retained incidents is generous
-- headroom, not a tight budget.
local MAX_INCIDENT_FILES = 50

local function archiveIncident(status, reason, forensics)
  if not fs.exists(INCIDENTS_DIR) then fs.makeDir(INCIDENTS_DIR) end
  local record = {
    lostAt = now(),
    status = status,
    reason = reason,
    forensics = forensics,
    blackbox = blackbox,
  }
  local ok, encoded = safeserialize.encode(record)
  if not ok then
    print("homelink: could not archive lost-chest incident -- " .. tostring(encoded))
    return
  end
  local path = INCIDENTS_DIR .. "/" .. tostring(record.lostAt) .. ".json"
  local f = fs.open(path, "w")
  f.write(encoded)
  f.close()

  local files = fs.list(INCIDENTS_DIR)
  if #files > MAX_INCIDENT_FILES then
    table.sort(files)
    for i = 1, #files - MAX_INCIDENT_FILES do
      fs.delete(INCIDENTS_DIR .. "/" .. files[i])
    end
  end
end

function M.listIncidents()
  if not fs.exists(INCIDENTS_DIR) then return {} end
  local files = fs.list(INCIDENTS_DIR)
  table.sort(files)
  return files
end

function M.getIncident(filename)
  local path = INCIDENTS_DIR .. "/" .. tostring(filename)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local text = f.readAll()
  f.close()
  local ok, decoded = pcall(textutils.unserializeJSON, text)
  if ok and type(decoded) == "table" then return decoded end
  return nil
end

-- Oldest dropped first once a single blackbox session (see
-- beginBlackbox()'s own comment on when a fresh one starts) accumulates
-- this many events -- a long run of retries against the same "placed"
-- record would otherwise grow this without bound.
local MAX_BLACKBOX_EVENTS = 200

function M.blackbox(event, data)
  if not blackbox then beginBlackbox("implicit") end
  local entry = { at = now(), event = event, data = data }
  blackbox.events[#blackbox.events + 1] = entry
  if #blackbox.events > MAX_BLACKBOX_EVENTS then
    table.remove(blackbox.events, 1)
  end
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

-- Never blind-drops as a last resort (an earlier version did:
-- turtle.dropDown() or turtle.drop() or turtle.dropUp(), whichever
-- direction happened to succeed first) -- confirmed live: this is exactly
-- what deposited a turtle's own home-link chest into the communal site
-- chest. Slot 16 being blocked by something that isn't the chest, with no
-- spare slot free, only happens while the turtle is at some chest to
-- unload cargo into in the first place -- so "drop whatever's blocking
-- it in whatever direction works" reliably means "into that very chest"
-- whenever what's actually blocking slot 16 is a second, stray
-- chest-named item (e.g. dug up incidentally from an old abandoned one
-- elsewhere) that a caller is trying to move OUT of the way. Failing
-- loudly here instead is safe: every call site already treats a false
-- return as a real failure (pickup_failed / job stop), never as license
-- to discard anything.
local function clearReservedSlot(avoidSlot)
  if turtle.getItemCount(M.SLOT) == 0 or M.isItem(M.SLOT) then return true end
  local spare = firstEmptySlot(avoidSlot or M.SLOT)
  if not spare then return false end
  turtle.select(M.SLOT)
  return turtle.transferTo(spare)
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

-- pcall-guarded for the same reason lib/job.lua's M.checkpoint() now is
-- (see that function's own comment): this runs on every place()/
-- markPickup() call, right in the middle of a normal mining pass -- a
-- serialization failure here must degrade to "this update didn't get
-- persisted" (still visible via M.getState() next time it DOES
-- succeed), never crash the whole job over what's fundamentally a
-- bookkeeping write.
local function saveState(data)
  local ok, encoded = safeserialize.encode(data)
  if not ok then
    print("homelink: could not save state -- " .. tostring(encoded))
    return
  end
  if not fs.exists("/state") then fs.makeDir("/state") end
  local f = fs.open(STATE_PATH, "w")
  f.write(encoded)
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

-- The ONLY three places a chest is ever confirmed genuinely gone, not
-- just stuck/blocked/unreachable (operator policy: only a chest
-- CONFIRMED absent is a reason to stop retrying -- see M.pickUp()'s own
-- comment) -- call this instead of markPickup("pickup_failed", ...)
-- directly at exactly those three spots, so a permanent, timestamped
-- record survives regardless of whatever place()/pickUp() session comes
-- next and overwrites the rolling blackbox.
local function markLost(reason, forensics)
  archiveIncident("pickup_failed", reason, forensics)
  markPickup("pickup_failed", reason, forensics)
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

-- Whether a chest is actually sitting in `direction` right now -- the
-- one thing that's allowed to end a retry loop against a placed home-
-- link chest (see dom-main/mining/vertical.lua's tryHomeLink()):
-- refuel/deposit/pickup hiccups are all meant to be retried while the
-- chest is confirmed still there, and only "it's genuinely not where
-- expected anymore" is a real reason to give up on it.
function M.isPresent(direction)
  local found, data = inspectDirection(direction)
  return found and nav.isChest(data.name)
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

  M.blackboxInspect("pickup.inspect_expected_block_before_cleanup", direction)
  M.blackboxSlot("pickup.slot16_before_cleanup", M.SLOT)
  local slotDetail = turtle.getItemDetail(M.SLOT)
  -- Moves whatever's wrongly sitting in slot 16 to a spare cargo slot --
  -- never drops it, blindly or otherwise (see clearReservedSlot()'s own
  -- comment: a blind "drop it in whatever direction works" is exactly
  -- what deposited a turtle's own home-link chest into the communal site
  -- chest, since the only time this branch is reached is while the
  -- turtle is standing at some chest anyway). No spare slot is a real
  -- failure, not license to discard anything.
  if slotDetail and slotDetail.name ~= ITEM_NAME then
    local spare = firstEmptySlot(M.SLOT)
    M.blackbox("pickup.slot16_blocked_before_pickup", {
      item = { name = slotDetail.name, count = slotDetail.count },
      spare = spare,
    })
    if not spare then
      return false, "not picking the home-link chest up while slot " .. M.SLOT
        .. " is blocked and no spare slot is available"
    end
    turtle.select(M.SLOT)
    local moved = turtle.transferTo(spare)
    M.blackbox("pickup.slot16_wrong_item_moved_to_spare", { spare = spare, moved = moved == true })
    if not moved then
      return false, "not picking the home-link chest up because slot " .. M.SLOT
        .. " could not be cleared"
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
    markLost("expected chest not present before digging (saw: "
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
      -- Confirmed present and just dug up (this whole branch only runs
      -- after that) -- a full slot 16 or a failed transfer here is a
      -- retriable inventory-management hiccup, NOT a lost chest (operator
      -- policy: only a confirmed-absent chest is terminal -- see this
      -- file's own markLost() comment). Re-stamping "placed" keeps
      -- dom-main/controller/scheduler.lua's recovery sweep retrying
      -- instead of abandoning a chest that's demonstrably still in hand.
      if turtle.getItemCount(M.SLOT) > 0 and not isChest(M.SLOT) then
        if not clearReservedSlot(slot) then
          markPickup("placed", "slot " .. M.SLOT .. " blocked and no spare slot is available")
          return false, "dug the home-link chest into slot " .. slot
            .. " but slot " .. M.SLOT .. " is blocked and no spare slot is available"
        end
      end
      turtle.select(slot)
      local moved = turtle.transferTo(M.SLOT)
      M.blackbox("pickup.move_recovered_chest_to_slot16", { from = slot, moved = moved == true })
      if not moved then
        markPickup("placed", "could not move recovered chest back to slot " .. M.SLOT)
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
            markPickup("placed", "recovered via floor pickup into slot " .. slot
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
  markLost("confirmed a real chest was dug (preDig saw " .. tostring(preDigName)
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
-- Operator policy: only a chest CONFIRMED gone (attemptPickUp()'s own
-- "expected chest not present before digging" branch -- the one case
-- that already explicitly marks "pickup_failed" itself) is ever a
-- reason to stop retrying. Everything else that can fail here (dig()
-- itself failing, "slot 16 blocked and no spare slot") only happens
-- AFTER that same preDig check already confirmed a real chest was
-- there -- so by construction, reaching this fallback with the record
-- still "placed" means something WENT WRONG after confirming presence,
-- not that the chest is gone. Re-stamping "placed" (bumping updatedAt,
-- same status) rather than a terminal "pickup_failed" keeps
-- dom-main/controller/scheduler.lua's automated recovery retrying
-- instead of giving up after one hiccup -- a turtle mid-recovery should
-- stay in recovery, not silently move on as though nothing happened.
function M.pickUp(direction)
  local ok, err = attemptPickUp(direction)
  if not ok then
    local stillPlaced = loadState()
    if stillPlaced and stillPlaced.status == "placed" then
      markPickup("placed", err)
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
    -- the exact same doomed attempt every sweep. Re-stamped "placed"
    -- (bumping updatedAt), NOT a terminal "pickup_failed" -- failing to
    -- REACH the recorded position (a blocked path, a fuel hiccup, a bad
    -- route) doesn't confirm the chest itself is gone, and operator
    -- policy is only to give up on a chest that's actually confirmed
    -- absent. Still visible via M.getState() for an operator to check
    -- on either way.
    local reason = "could not reach recorded home-link chest position: " .. tostring(reachInfo and reachInfo.reason)
    markPickup("placed", reason)
    return false, reason
  end
  nav.face(target.heading or target.facing)

  local found, data = inspectDirection(saved.direction)
  if not (found and nav.isChest(data.name)) then
    -- This IS the confirmed-gone case -- operator policy: only reason to
    -- ever stop retrying and treat the local chest as abandoned.
    local reason = "recorded home-link chest is no longer present at the saved position"
    markLost(reason)
    return false, reason
  end

  -- M.pickUp() itself now guarantees the record gets resolved to
  -- "pickup_failed" on any failure (see its own comment) -- no separate
  -- catch-all needed here anymore.
  local picked, pickInfo = M.pickUp(saved.direction)
  if not picked then return false, pickInfo end
  return true, pickInfo or "recovered placed home-link chest"
end

-- Maps a placed direction to the matching turtle.suck*() function -- see
-- dom-main/mining/vertical.lua's own SUCK_BY_DIRECTION for why
-- lib/fuel.lua's M.refuelFrom() (not M.ensureFuel()) is the right call
-- here: ensureFuel()'s drain() only pulls from a direction whose block
-- NAME looks like "chest", and this module's own ITEM_NAME confirms
-- EnderStorage's real registry name doesn't reliably match that.
local SUCK_BY_DIRECTION = { front = turtle.suck, up = turtle.suckUp, down = turtle.suckDown }

-- Places the home-link chest wherever the turtle currently is and tries
-- to refuel from it, then picks it back up -- no travel required, so a
-- turtle that's simply low on fuel (not mid-mining-pass -- dom-main/
-- mining/vertical.lua's own tryHomeLink() already covers that case, as
-- part of a full unload cycle) can serve itself right where it's
-- standing instead of waiting on a rescuer turtle or a trip to a real
-- chest. Same operator policy as everywhere else in this file: a chest
-- confirmed still present is always worth trying, and M.pickUp() itself
-- already guarantees the record resolves correctly (retriable "placed"
-- vs. a genuinely confirmed-gone loss) on any failure here, so this
-- doesn't need its own separate bookkeeping.
--
-- Returns true once fuel reaches targetFuel (or is unlimited) AND the
-- chest is safely back in inventory; false, reason, reasonCode
-- otherwise -- reasonCode mirrors tryHomeLink()'s own:
--   "unavailable" -- no chest to place at all (nothing local to try;
--     caller should fall back to some other refuel source).
--   "stuck" -- placed but not retrievable -- operator policy: the
--     caller must NOT treat this as "nothing happened" and move on;
--     dom-main/controller/scheduler.lua's own recovery sweep will keep
--     retrying it independently of whatever this call's caller does next.
function M.refuelTo(targetFuel)
  local direction, placeErr = M.place()
  if not direction then
    return false, placeErr, "unavailable"
  end
  stats.recordEnderChestPlacement()

  if M.isPresent(direction) then
    fuel.refuelFrom(SUCK_BY_DIRECTION[direction], targetFuel)
  end

  local ok, pickErr = M.pickUp(direction)
  if not ok then
    return false, pickErr, "stuck"
  end

  local fuelLevel = turtle.getFuelLevel()
  if fuelLevel == "unlimited" or fuelLevel >= targetFuel then return true end
  return false, "picked the chest back up but still short of " .. targetFuel
    .. " fuel (has " .. tostring(fuelLevel) .. ") -- it may simply be out of fuel to give right now"
end

_G.__HOMELINK_MODULE = M
return M

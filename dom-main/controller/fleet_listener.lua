--[[----------------------------------------------------------------------
  dom-main/controller/fleet_listener.lua -- opens this controller's ender
  modem, advertises itself over rednet so turtles' lib/fleet.lua can find
  it via rednet.lookup(), and hands every incoming message to
  dom-main/controller/roster.lua.

  Unlike a turtle (whose modem is an equipment upgrade, always on a fixed
  side), a controller is a plain Computer -- its modem could be attached
  to any face, so this finds it by peripheral type instead of assuming a
  side.
------------------------------------------------------------------------]]

local roster = dofile("/dom-main/controller/roster.lua")
local PROTOCOL = dofile("/lib/fleet.lua").PROTOCOL

local M = {}

function M.run()
  if not rednet then
    print("fleet_listener: rednet api disabled -- no modem support on this computer.")
    return
  end

  local modem = peripheral.find("modem", function(_, m) return m.isWireless() end)
  if not modem then
    print("fleet_listener: no wireless/ender modem attached to this computer.")
    return
  end
  -- peripheral.find() hands back the wrapped peripheral, not the side it
  -- lives on -- peripheral.getName() recovers that so rednet.open() gets
  -- a side name instead of a peripheral table.
  local side = peripheral.getName(modem)

  if not rednet.isOpen(side) then
    rednet.open(side)
  end

  -- lib/identity.lua's state is persisted/cached the same way regardless
  -- of who calls M.get() first -- lib/remote.lua also calls it (with the
  -- relay uniqueness check) for this same controller's relay identity,
  -- so whichever of the two runs first settles the name and the other
  -- just loads it back, keeping the controller's rednet-hosted name and
  -- relay id identical without any extra coordination.
  local id = dofile("/lib/identity.lua").get(nil)
  rednet.host(PROTOCOL, id)
  print("fleet_listener: hosting as \"" .. id .. "\" on protocol " .. PROTOCOL)

  while true do
    local senderId, message = rednet.receive(PROTOCOL)
    roster.handleMessage(senderId, message)
  end
end

return M

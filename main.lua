--[[----------------------------------------------------------------------
  main.lua -- entry point, run by startup.lua after every OTA update.

  A `turtle` global only exists on an actual turtle -- a plain Computer
  (a fleet controller) never has one -- so this is a free, zero-config
  way to tell the two device roles apart without a manual flag anywhere:
  every device in the fleet runs the exact same OTA'd files, and this is
  the one branch that decides which entry point actually runs.
------------------------------------------------------------------------]]

if turtle then
  dofile("/dom-main/turtle_main.lua")
else
  dofile("/dom-main/controller/controller_main.lua")
end

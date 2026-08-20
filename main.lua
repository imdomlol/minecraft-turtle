--[[----------------------------------------------------------------------
  main.lua -- entry point, run by startup.lua after every OTA update.

  Starts the remote console loop (lib/remote.lua) so this turtle can be
  driven from the relay server (see server/relay.py). Add turtle "day job"
  code here later and run it alongside the console via parallel.waitForAny,
  so a stuck job never blocks incoming commands and a bad command never
  blocks the job.
------------------------------------------------------------------------]]

local remote = dofile("/lib/remote.lua")

parallel.waitForAny(remote.run)

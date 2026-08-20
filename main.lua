--[[----------------------------------------------------------------------
  main.lua -- entry point, run by startup.lua after every OTA update.

  Starts the remote console loop (lib/remote.lua) alongside the
  background job runner (lib/job.lua) so this turtle can run a long
  "day job" (mining, etc.) while still answering the remote console --
  a job started via a blocking remote command would otherwise starve the
  console of ever hearing a "stop" command. Every known job needs
  registering here before job.run() starts, so the remote console can
  request it later by name.
------------------------------------------------------------------------]]

local remote = dofile("/lib/remote.lua")
local job = dofile("/lib/job.lua")

job.register("mine_vertical", dofile("/dom-main/mining/vertical.lua").run)

parallel.waitForAny(remote.run, job.run)

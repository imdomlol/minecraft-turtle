--[[----------------------------------------------------------------------
  remote-setup.lua -- one-time config for the relay connection.

  Run this on a fleet controller computer, not on individual turtles --
  turtles talk to their controller over rednet (lib/fleet.lua) and need
  no setup at all; the controller is the only thing that polls
  server/relay.py, so it's the only thing that needs a URL/token.

  Saves {url, token} to /state/remote.cfg, which survives startup.lua's
  OTA wipe. Re-run any time to change the relay server or rotate the
  token. Never commit the token to the repo -- it's public.
------------------------------------------------------------------------]]

local remote = dofile("/lib/remote.lua")

local function ask(prompt, default)
  write(prompt)
  if default then write(" [" .. default .. "]") end
  write(": ")
  local answer = read()
  if answer == "" then return default end
  return answer
end

local existing = remote.loadConfig() or {}

print("== controller relay setup ==")
print(("computer id: %d   label: %s"):format(os.getComputerID(), os.getComputerLabel() or "(none)"))
print("")

local url = ask("relay server URL (e.g. http://1.2.3.4:8787)", existing.url)

write("shared token")
if existing.token then write(" [keep existing]") end
write(": ")
local tokenInput = read("*")
local token = (tokenInput ~= "" and tokenInput) or existing.token

if not url or url == "" or not token or token == "" then
  printError("url and token are both required. aborting.")
  return
end

remote.saveConfig({ url = remote.normalizeUrl(url), token = token })
print("")
print("saved to /state/remote.cfg")
print("this controller will start polling the relay on next boot (or run main.lua now).")

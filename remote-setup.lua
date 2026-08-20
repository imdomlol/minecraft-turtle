--[[----------------------------------------------------------------------
  remote-setup.lua -- one-time config for the remote console.

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

print("== remote console setup ==")
print(("turtle id: %d   label: %s"):format(os.getComputerID(), os.getComputerLabel() or "(none)"))
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

remote.saveConfig({ url = url, token = token })
print("")
print("saved to /state/remote.cfg")
print("this turtle will start polling the relay on next boot (or run main.lua now).")

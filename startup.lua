--[[----------------------------------------------------------------------
  startup.lua  --  bootstrap only

  On every boot:
    1. Fetch manifest.txt from GitHub (cache-busted).
    2. Download every file listed in it INTO MEMORY.
    3. Only if all downloads succeeded, wipe the turtle's local files
       (everything except rom / state / .settings / mounted disks).
    4. Write the freshly downloaded files to disk.
    5. Hand off to /main.lua if the repo provided one.

  The download-before-wipe order matters: if GitHub is unreachable the
  turtle keeps the programs it already has instead of bricking itself.
------------------------------------------------------------------------]]

-------------------------------------------------- config
local GITHUB_USER   = "imdomlol"
local GITHUB_REPO   = "minecraft-turtle"
local GITHUB_BRANCH = "main"
local MANIFEST_PATH = "manifest.txt"

-- Names in the turtle's root that the wipe must never touch.
local PROTECTED = {
  ["state"]     = true,   -- persistent turtle memory (position, job, etc.)
  [".settings"] = true,   -- CraftOS `set` values
  ["rom"]       = true,   -- read-only anyway, listed for clarity
}

local MAX_RETRIES = 3
local ENTRY_POINT = "main.lua"   -- run after update if it exists; "" to disable


math.randomseed(os.epoch("utc") % 2147483647)
local BOOT_TAG = tostring(os.epoch("utc")) .. "-" .. tostring(math.random(0, 999999))

local NOCACHE_HEADERS = {
  ["Cache-Control"] = "no-cache, no-store, must-revalidate, max-age=0",
  ["Pragma"]        = "no-cache",
  ["User-Agent"]    = "cc-turtle-bootstrap",
}

local function rawURL(path, attempt)
  return string.format(
    "https://raw.githubusercontent.com/%s/%s/%s/%s?cb=%s-%d",
    GITHUB_USER, GITHUB_REPO, GITHUB_BRANCH, path, BOOT_TAG, attempt
  )
end

-------------------------------------------------- helpers
local function say(fmt, ...)
  print(string.format(fmt, ...))
end

local function fail(fmt, ...)
  printError(string.format(fmt, ...))
end

-- Returns body, or nil + reason.
local function fetch(path)
  local lastErr = "unknown error"
  for attempt = 1, MAX_RETRIES do
    local handle, err = http.get(rawURL(path, attempt), NOCACHE_HEADERS)
    if handle then
      local code = handle.getResponseCode()
      local body = handle.readAll()
      handle.close()
      if code == 200 then return body end
      lastErr = "HTTP " .. tostring(code)
    else
      lastErr = tostring(err)
    end
    if attempt < MAX_RETRIES then sleep(1) end
  end
  return nil, lastErr
end

-- manifest lines:
--   path/in/repo.lua                     -> same path on the turtle
--   path/in/repo.lua -> other/name.lua   -> renamed / relocated
--   # comment            (ignored)
local function parseManifest(text)
  local files = {}
  for line in text:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local src, dst = line:match("^(%S+)%s*%->%s*(%S+)$")
      files[#files + 1] = { src = src or line, dst = dst or line }
    end
  end
  return files
end

local function writeFile(path, content)
  local dir = fs.getDir(path)
  if dir ~= "" and dir ~= "." and not fs.exists(dir) then
    fs.makeDir(dir)
  end
  local f = fs.open(path, "w")
  f.write(content)
  f.close()
end

-- Only delete things living on the turtle's own drive ("hdd"). This
-- automatically spares /rom and any floppy mounted at /disk.
local function wipeLocalFiles(keepStartup)
  local removed = 0
  for _, name in ipairs(fs.list("/")) do
    local path = "/" .. name
    local skip = PROTECTED[name]
      or (keepStartup and name == "startup.lua")
      or fs.isReadOnly(path)
      or fs.getDrive(path) ~= "hdd"
    if not skip then
      fs.delete(path)
      removed = removed + 1
    end
  end
  return removed
end

-------------------------------------------------- run
term.clear()
term.setCursorPos(1, 1)
say("== turtle bootstrap ==")
say("repo: %s/%s @ %s", GITHUB_USER, GITHUB_REPO, GITHUB_BRANCH)

if not http then
  fail("The http API is disabled on this server. Cannot update.")
  return
end

-- 1. manifest
local manifestText, mErr = fetch(MANIFEST_PATH)
if not manifestText then
  fail("Could not fetch %s: %s", MANIFEST_PATH, mErr)
  fail("Keeping existing local files. Aborting update.")
  return
end

local files = parseManifest(manifestText)
if #files == 0 then
  fail("%s listed no files. Refusing to wipe. Aborting.", MANIFEST_PATH)
  return
end
say("manifest: %d file(s)", #files)

-- 2. download everything to memory first
local staged, manifestHasStartup = {}, false
for i, entry in ipairs(files) do
  write(string.format("  [%d/%d] %s ... ", i, #files, entry.src))
  local body, err = fetch(entry.src)
  if not body then
    print("FAIL")
    fail("  %s: %s", entry.src, err)
    fail("Aborting before wipe. Local files untouched.")
    return
  end
  print(#body .. "b")
  staged[#staged + 1] = { path = "/" .. entry.dst, body = body }
  if entry.dst == "startup.lua" then manifestHasStartup = true end
end

-- 3. wipe (all downloads are safely in memory at this point)
if not manifestHasStartup then
  fail("Warning: manifest does not include startup.lua; keeping the local one.")
end
local removed = wipeLocalFiles(not manifestHasStartup)
say("wiped %d local entr%s", removed, removed == 1 and "y" or "ies")

-- 4. write
for _, item in ipairs(staged) do
  writeFile(item.path, item.body)
end
say("wrote %d file(s). up to date.", #staged)

-- 5. hand off
if ENTRY_POINT ~= "" and fs.exists("/" .. ENTRY_POINT) then
  say("-> running /%s", ENTRY_POINT)
  sleep(0.5)
  shell.run("/" .. ENTRY_POINT)
else
  say("no /%s -- dropping to shell.", ENTRY_POINT)
end

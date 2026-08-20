# minecraft-turtle

ComputerCraft (CC: Tweaked) turtle programs, deployed over the air from this repo.

Minecraft 1.21.1 / NeoForge / All The Mods 10.

## How deployment works

`startup.lua` is a bootstrap. On every turtle boot it:

1. Fetches `manifest.txt` from this repo, cache-busted.
2. Downloads every file the manifest lists **into memory**.
3. Only once all downloads succeed, wipes the turtle's local files.
4. Writes the fresh copies to disk.
5. Runs `/main.lua` if the manifest provided one.

Downloading before wiping means an unreachable GitHub or a typo'd manifest
path leaves the turtle with the programs it already had, instead of bricking
it.

### What survives the wipe

| Path | Why |
|---|---|
| `/rom` | CraftOS read-only mount |
| `/state` | persistent turtle memory — position, current job |
| `/.settings` | CraftOS `set` values |
| `/disk*` | any mounted floppy |

Anything else in the turtle's root is replaced from this repo on every boot.
Treat the turtle's local disk as disposable; `/state` is the only thing that
belongs to the turtle rather than to the repo.

### Cache busting

`raw.githubusercontent.com` sits behind a CDN that will serve a stale copy for
several minutes. The bootstrap defeats this with a unique query string per
request (`?cb=<epoch-ms>-<random>-<attempt>`) plus `Cache-Control: no-cache`
and `Pragma: no-cache` request headers.

## manifest.txt

One entry per line, paths relative to the repo root:

```
foo.lua                    # -> /foo.lua on the turtle
dir/foo.lua                # -> /dir/foo.lua
dir/foo.lua -> bar.lua     # -> /bar.lua  (rename / flatten)
```

Blank lines and `#` comments are ignored. Keep `startup.lua` listed so the
bootstrap can update itself.

## First-time setup on a turtle

Once per turtle:

```
wget https://raw.githubusercontent.com/imdomlol/minecraft-turtle/main/startup.lua startup.lua
reboot
```

Every reboot after that self-updates.

## Remote console

Turtles are usually scattered across the map, out of rednet range of each
other, so remote control works over HTTP instead: each turtle polls a
small relay server for queued commands, runs them, and posts the output
back. This is the same `http` API `startup.lua` already uses to reach
GitHub, so no wireless modem or in-game host computer is required.

Because this repo is public, the relay's address and shared token are
**not** committed to it — they're entered once per turtle via
`remote-setup.lua` and stored in `/state/remote.cfg`, which `startup.lua`
never wipes.

### 1. Run the relay server

Anywhere reachable by your turtles — remember the `http` calls happen on
whatever machine is actually simulating the world, not on your game
client, so "reachable" means reachable from the Minecraft *server*.

```
server/start-relay.sh
```

This is a thin wrapper around `python3 server/relay.py` (stdlib only, no
pip install) that generates a random token on first run and saves it to
`server/.relay_token` (gitignored) so restarts don't hand out a new token
and lock out already-configured turtles. It prints the token on every
start. Pass `RELAY_TOKEN=...` or `RELAY_PORT=...` to override either.

If your turtles need to reach it over the internet — e.g. the Minecraft
server runs on someone else's machine — forward the port on *your own*
router to this machine and use your public IP when running
`remote-setup.lua` on the turtle (see below).

> **CC:Tweaked note:** by default the mod blocks the `http` API from
> reaching private/local IP addresses (SSRF protection). This only
> matters if the relay and the Minecraft server share a LAN — in that
> case add the relay's address to `http.rules` in the server's
> `computercraft-server.toml`. A relay reachable at a public IP needs no
> such change.

### 1b. No port to forward? Tunnel instead

Port forwarding needs a router you control and a real public IP. Neither
exists behind carrier-grade NAT (phone hotspots, some ISPs) or a router
you don't have admin access to. In that case, tunnel out instead of
forwarding in: [ngrok](https://ngrok.com) opens an *outbound* connection
from your machine to a public relay, which then forwards traffic back
down it — no inbound port needed anywhere.

```
# one-time: sign up, then from the dashboard grab an authtoken and
# reserve your one free static domain (Cloud Edge -> Domains -> New Domain)
curl -s https://ngrok-agent.s3.amazonaws.com/ngrok.asc | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
echo "deb https://ngrok-agent.s3.amazonaws.com buster main" | sudo tee /etc/apt/sources.list.d/ngrok.list
sudo apt update && sudo apt install ngrok
ngrok config add-authtoken <your-authtoken>

# every time you want turtles reachable:
server/start-relay.sh                                   # terminal 1
ngrok http --domain=your-name.ngrok-free.app 8787        # terminal 2
```

Use `https://your-name.ngrok-free.app` as the relay URL in step 3 below
(CC:Tweaked's `http` API handles `https://` fine). A static domain means
the URL doesn't change between restarts, so turtles don't need
`remote-setup` re-run every time you bring the tunnel back up. This does
mean turtles only stay reachable while both the relay and the tunnel are
running on your machine — fine for hands-on sessions, not for
unattended/always-on control (a small cloud VM with a real public IP is
the fix for that, if you get there later).

### 2. Verify it's actually reachable

Before touching a turtle, confirm the path works end to end. From a
network that *isn't* the one running the relay (phone data works well):

```
curl -s -o /dev/null -w "%{http_code}\n" https://your-name.ngrok-free.app/status
```

A `401` means it made it all the way through (tunnel + relay + auth
check) and just needs a token — that's success. A timeout or connection
error means the tunnel or port forward isn't actually up yet.

### 3. Point a turtle at it

On the turtle, after it's bootstrapped at least once (so `/lib/remote.lua`
and `remote-setup.lua` exist):

```
remote-setup
```

Enter the relay's URL — `http://1.2.3.4:8787` for a direct/forwarded
setup, or `https://your-name.ngrok-free.app` for a tunnel — and the
token (`cat server/.relay_token` if you used `start-relay.sh`). This
runs once per turtle — re-run it later to change the server or rotate the
token. `main.lua` (run automatically after every OTA update) then polls
the relay in the background for commands.

### 4. Send commands from your machine

```
export RELAY_URL=http://localhost:8787   # talking to your own relay directly; no need to go via the tunnel
export RELAY_TOKEN=$(cat server/.relay_token)

python3 server/turtlectl.py list                       # which turtles have checked in
python3 server/turtlectl.py send 12 turtle.getFuelLevel()
python3 server/turtlectl.py send-all os.getComputerLabel()
python3 server/turtlectl.py results 12
python3 server/turtlectl.py watch 12                    # stream new results
```

Turtle IDs are their CC:Tweaked computer ID (`os.getComputerID()`), shown
by `turtlectl.py list` alongside each turtle's label and last-seen time.
Commands are plain Lua, evaluated the same way CraftOS's own `lua` shell
program does — bare expressions like `turtle.getFuelLevel()` print their
return value, and `print(...)` output is captured too.

## lib/nav.lua

A shared "where am I / what's around me" module, meant to be `dofile()`'d
by other turtle scripts (including one-off commands sent through the
remote console):

```
dofile("/lib/nav.lua").report()
```
```
pos: (1, 0, -2)  facing: east  [relative, no GPS fix]
front: minecraft:stone
up:    air/none
down:  minecraft:dirt
```

`nav.here()` returns the same data as a plain table instead of printing
it, for scripts to consume programmatically. Position is anchored to a
real GPS fix if a GPS satellite network is reachable in-world the first
time a turtle uses it, otherwise it's relative to wherever the turtle
was when tracking began (0,0,0) — `gpsFixed` in the returned table tells
you which. Either way, keeping the tracked position accurate requires
routing all movement through `nav.forward()` / `nav.back()` / `nav.up()`
/ `nav.down()` / `nav.turnLeft()` / `nav.turnRight()` instead of calling
`turtle.forward()` etc directly — they return the same values, just also
update the tracked position on success. State lives in `/state/nav.state`,
so it survives the OTA wipe.

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

Turtles don't talk to the relay over HTTP directly. Instead, one plain
Computer per Minecraft dimension — the **fleet controller** — is
equipped with an ender modem and is the only thing that polls a small
relay server for queued commands; turtles (each equipped with an ender
modem of their own, in their left slot) talk to their dimension's
controller over `rednet` (`lib/fleet.lua`) instead. Since ender modems
can't cross dimensions, "one controller per dimension" and "a turtle
only ever finds its own dimension's controller" both fall out for free —
there's nothing to configure.

Because this repo is public, the relay's address and shared token are
**not** committed to it — they're entered once **per controller** (not
per turtle — turtles need no setup at all, see below) via
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

### 3. Point the controller at it

This step is done once **per dimension's controller computer**, not per
turtle. On the controller, after it's bootstrapped at least once (so
`/lib/remote.lua` and `remote-setup.lua` exist):

```
remote-setup
```

Enter the relay's URL — `http://1.2.3.4:8787` for a direct/forwarded
setup, or `https://your-name.ngrok-free.app` for a tunnel — and the
token (`cat server/.relay_token` if you used `start-relay.sh`). This
runs once per controller — re-run it later to change the server or
rotate the token. `main.lua` (run automatically after every OTA update,
on any device with no `turtle` API — i.e. a plain Computer) then polls
the relay in the background for commands.

Turtles need none of this. A turtle equipped with an ender modem finds
its dimension's controller automatically over `rednet` the moment it
boots — there's no URL or token to enter, and no per-turtle setup step
at all.

### 4. Send commands from your machine

```
export RELAY_URL=http://localhost:8787   # talking to your own relay directly; no need to go via the tunnel
export RELAY_TOKEN=$(cat server/.relay_token)

python3 server/turtlectl.py list                        # which controllers have checked in
python3 server/turtlectl.py roster Ferrum               # every turtle controller "Ferrum" currently knows about
python3 server/turtlectl.py send Ferrum Lux turtle.getFuelLevel()
python3 server/turtlectl.py send-fleet Ferrum os.getComputerLabel()   # every turtle behind Ferrum
python3 server/turtlectl.py results Ferrum
python3 server/turtlectl.py watch Ferrum                # stream new results
python3 server/turtlectl.py console Ferrum              # live feed of the controller's screen (+ every turtle's log lines, tagged)
```

Controller and turtle IDs are both names assigned by `lib/identity.lua`
(see below) — a controller's is shown by `turtlectl.py list`, a turtle's
by `turtlectl.py roster <controller>`, alongside last-seen time; each is
equal to its CraftOS label too. Every turtle-targeting command needs
*both* — the controller name so `turtlectl.py` knows which relay
connection to use, and the turtle name so that controller knows which of
its turtles to relay the command to over rednet (see
`dom-main/controller/roster.lua`'s `proxy()`). Commands are plain Lua,
evaluated the same way CraftOS's own `lua` shell program does — bare
expressions like `turtle.getFuelLevel()` print their return value, and
`print(...)` output is captured too.

`console` is different from `watch`: `watch` only shows the result of
commands you send through the relay, while `console` mirrors everything
that ever gets printed to the controller's own screen *and* every
turtle's — boot messages, whatever a "day job" script prints on its own,
and command output — as it happens, polled at ~1-2s resolution. A
turtle's own lines arrive tagged `[name] ...` (`lib/fleet.lua` streams
them to its controller over rednet; `dom-main/controller/roster.lua`
folds them into the controller's own log feed), so one `console` session
shows the whole fleet in that dimension, not just one device. It works
by wrapping `term` so every write is both shown on the real screen and
shipped to the relay; the relay keeps the last ~20K characters per id in
memory only (not persisted to `relay_state.json`), so history resets on
a relay restart.

`console` also accepts input, not just output: type a command and press
enter to send it (queued the same way `send` does) while still watching
the live feed in the same terminal — a background thread handles the
polling/printing, the foreground reads your typed lines. Ctrl-D or
Ctrl-C to stop. Up/down arrows cycle through previously typed lines
within that session (via Python's `readline`, POSIX only).

A command's own progress streams live too, not just the final result:
`lib/exec.lua` (shared by `lib/remote.lua` and `lib/fleet.lua`) mirrors
whatever a command `print()`s as it happens, not only once the whole
command returns — important for anything
long-running (a `pathfind.goto()` across a big distance, say), which
would otherwise leave the console looking dead for the entire duration
before dumping everything at once at the end.

### Shortcuts for common calls

Typing out `dofile("/lib/job.lua").request("goto", { x = -89, y = 55, z
= -87, allowDig = "safe" })` from memory is a lot to ask — and it's easy
to forget which lib/*.lua file a call lives in, or whether it's a
background job (`request`/`stop`) versus a plain call. `turtlectl.py` has
shortcuts that build the right command for you:

Every one of these takes `<controller> <turtle>` — which controller to
talk to over the relay, then which of its turtles to relay the command
to:

```
python3 server/turtlectl.py goto Ferrum Lux -89 55 -87 --dig          # background job, cancellable (--dig alone means "safe" -- see below)
python3 server/turtlectl.py goto Ferrum Lux -89 55 -87 --dig all       # dig through a chest/ComputerCraft block too, not just route around it
python3 server/turtlectl.py mine Ferrum Lux --width-facing west --length 12   # any omitted flag keeps its default
python3 server/turtlectl.py mine Ferrum Lux --length-facing all --height 40 --width 20
python3 server/turtlectl.py mine Ferrum Lux --no-tidy --no-observant  # --tidy/--observant/--thorough, all default true
python3 server/turtlectl.py stop Ferrum Lux                           # stop the running job, back to idle
python3 server/turtlectl.py jobstatus Ferrum Lux
python3 server/turtlectl.py pos Ferrum Lux
python3 server/turtlectl.py pos Ferrum Lux --full                      # spin to see all 6 surrounding blocks
python3 server/turtlectl.py setpos Ferrum Lux -89 70 -87 west          # manual calibration, e.g. after an F3 check
python3 server/turtlectl.py turnleft Ferrum Lux
python3 server/turtlectl.py turnright Ferrum Lux
python3 server/turtlectl.py inv Ferrum Lux
python3 server/turtlectl.py home Ferrum Lux --dig
python3 server/turtlectl.py markhome Ferrum Lux
python3 server/turtlectl.py findchest Ferrum Lux --radius 12           # or --x/--y/--z to search elsewhere
python3 server/turtlectl.py dump Ferrum Lux                            # find a chest nearby (radius 8) and empty into it
python3 server/turtlectl.py dump Ferrum Lux --x 100 --y 64 --z -200    # a known chest location (exact by default)
python3 server/turtlectl.py roster Ferrum                              # controller-only -- no turtle argument
```

`--dig` on `goto`/`home` takes an optional mode: bare `--dig` (same as
`--dig safe`) digs/attacks through obstacles but never destroys a chest
or a ComputerCraft block (another turtle, computer, modem, etc) — it
routes around either instead, the same as it would an undiggable block —
since a dig-through trip has no way to tell a player's storage chest (or
another turtle's computer) apart from ordinary terrain otherwise. `--dig
all` is an explicit opt-in to dig through either too. `mine` has no
`--dig` flag at all (it always digs, by nature), but is chest-safe and
ComputerCraft-safe unconditionally regardless — it always routes around
either in its path rather than destroying it.

Every shortcut above also takes `--wait` (block and print the result once
it completes — no separate `results`/`console` lookup for a quick check)
and `--wait-timeout` (seconds, default 120). `--help` on any of them
lists its flags, e.g. `turtlectl.py goto --help`.

The same shortcuts (minus `<controller>`, already implied by the session,
and `--wait`, pointless when you're already watching the live feed) work
typed directly into an active `console <controller>` session too —
turtle-targeting ones still need a `<turtle>` first, e.g. `goto Lux -89
55 -87 --dig` or `mine Lux --width-facing west --length 12`; `roster`
takes none. Anything whose first word isn't a shortcut name is sent
through unchanged, as raw Lua, run on the controller itself (not
proxied to any turtle). Type `help` in a console session to list them
all without leaving it.

## lib/identity.lua

Assigns a stable name to identify a device with, used by both
`lib/remote.lua` (a controller identifying itself to the relay) and
`lib/fleet.lua` (a turtle identifying itself to its controller), instead
of the raw CC:Tweaked computer ID (`os.getComputerID()`). That matters
because computer IDs are only unique *within a single world*: if more
than one Minecraft server shares this same relay, two controllers on two
different servers can easily both be ID 0. Since `relay.py` keys
everything — the command queue, results, live console log — purely by
that id string, two colliding on it silently interleave into the same
slot: a command meant for one can execute on the other, and their output
mixes together. This is exactly what happened once already in this
project.

Names come from `lib/champions.lua` (League of Legends champions,
cleaned to plain alphanumeric CamelCase so they're safe directly in a
relay URL). On first run, a controller GETs the relay's `/status` to see
which names are already taken, picks a free one at random, sets it as
both its CraftOS label (`os.setComputerLabel()`) and its relay id, and
persists it to `/state/identity.state` — so it keeps that name across
every future reboot rather than re-registering as a new identity (and a
fragmented result history) each time. If the relay can't be reached yet,
it still picks a name (best-effort, no uniqueness check) rather than
getting stuck unable to identify itself at all.

A turtle picks its name the same way, but with no relay `/status` to
check at all — rednet registration has no shared directory to consult
before picking (see `M.get(nil)` in `lib/fleet.lua`). Instead, its
controller (the one authority that actually knows its whole roster of
turtles) is what detects a genuine collision, the moment two different
turtles report the same name in a heartbeat, and tells the loser to
switch via `M.set(name)` — see `dom-main/controller/roster.lua`'s
`upsert()`.

The uniqueness check is a check-then-act, not an atomic claim — two
devices picking their very first identity at the exact same instant
could in principle pick the same "free" name. Not worth a real
distributed lock for how narrow that window is (this runs once per
device's lifetime, not every boot): `dofile("/lib/identity.lua").get(cfg)`
directly if you ever need to force a re-check.

## lib/exec.lua

"Run this Lua string, capture its output" — pulled out of what used to
be `lib/remote.lua`'s own private `execute()`, since `lib/fleet.lua` (the
rednet transport) needs the exact same behavior and shouldn't have to
duplicate it. Tries an implicit `"return " ..` prefix first, same as
CraftOS's own `lua` shell program, so a bare expression reports its
return value; falls back to the raw parse for genuine statements. Also
owns the pending-log buffer both transports stream to their relay/rednet
peer for a live console to tail:

```
dofile("/lib/exec.lua").run("turtle.getFuelLevel()")  -- ok, output
dofile("/lib/exec.lua").pendingLog()                  -- text accumulated since the last drain
dofile("/lib/exec.lua").dropSentLog(sentChunk)        -- remove exactly what was just shipped out
dofile("/lib/exec.lua").append("[Lux] hello\n")       -- feed in externally-sourced text (see roster.lua)
```

## lib/fleet.lua

A turtle's transport to its dimension's fleet controller, replacing
`lib/remote.lua`'s HTTP polling. Opens `rednet` on the ender modem
always equipped in the left slot, finds its controller via
`rednet.lookup()` (no setup needed — a fixed protocol name, and ender
modems can't cross dimensions, so there's only ever one controller a
turtle can find), and registers via its first heartbeat rather than a
separate message. Runs three loops in parallel: one blocks on
`rednet.receive()` and answers exec requests through `lib/exec.lua`
(event-driven, no busy-polling, unlike the HTTP side); one sends a
status heartbeat (fuel, position, `lib/job.lua` status) every ~3s; one
ships `lib/exec.lua`'s pending log to the controller every ~1.5s. All
three are fire-and-forget over rednet — there's no delivery confirmation
the way an HTTP response gives `lib/remote.lua` one, so a dropped
heartbeat/log chunk is simply skipped rather than retried; the next tick
re-establishes freshness regardless.

Since rednet registration has no relay `/status` to check names against
first, a genuine collision (two different turtles reporting the same
name) is instead caught by the controller — see `dom-main/controller/
roster.lua` — which replies with a `"rename"` message; a turtle applies
it via `lib/identity.lua`'s `M.set(name)` and keeps going under the new
name immediately.

## dom-main/controller/

The fleet controller's own code, run by `dom-main/controller/
controller_main.lua` on any device with no `turtle` API (a plain
Computer) — `main.lua`'s dispatcher sends every other device to
`dom-main/turtle_main.lua` instead. A controller runs `lib/remote.lua`
completely unchanged (it's now the only thing in its dimension polling
the relay) alongside `fleet_listener.lua`, which hosts this dimension's
`rednet` protocol and hands every incoming message to `roster.lua`.

`roster.lua` tracks every turtle heard from (`M.report()`, behind
`turtlectl.py roster`) and is the one function operator commands and the
(future) autopilot scheduler both go through to actually reach a turtle:

```
dofile("/dom-main/controller/roster.lua").proxy("Lux", command)      -- run `command` on turtle Lux, wait for its result
dofile("/dom-main/controller/roster.lua").proxyAll(command)          -- same, for every known turtle, sequentially
dofile("/dom-main/controller/roster.lua").report()                   -- { name -> { label, fuel, position, job, secondsAgo } }
```

`M.proxy()`'s own wait loop re-enters `M.handleMessage()` for anything
that arrives while it's waiting that *isn't* its answer (another
turtle's heartbeat or log line) — so a slow reply from one turtle never
means a dropped heartbeat from another. This relies on CraftOS resuming
every coroutine parked in `rednet.receive()` with the same event rather
than handing it to just one of them, so `fleet_listener.lua`'s own
receive loop and a `proxy()` call's nested one can safely coexist.

`worldstore.lua` is the controller's source of truth for "what block is
at (x, y, z)" (`turtlectl.py worldblock`), chunked the way Minecraft
itself is (16×16×16 regions, one file per chunk under `/state/world/`)
and paletted (block names map to small integers in a shared table) so it
scales to a whole fleet mining around the clock instead of one
ever-growing flat file. It's fed by `block_sync.lua`, which every ~2s
pulls buffered observations from whichever turtle has gone longest
since its last pull (`roster.lua`'s `M.leastRecentlyPulled()`) — turtles
buffer what they've seen (`lib/worldmap.lua`, which wraps
`turtle.inspect*()` so this needs no changes anywhere else) and hand a
batch over only when asked, rather than pushing on a timer.

`mode.lua` is the `idle`/`passive`/`aggressive` switch for the (not yet
built) autopilot scheduler — `turtlectl.py mode <controller>
[idle|passive|aggressive]`, adjustable at any time regardless of what
it's currently set to. `idle` never autopilots; `aggressive` always
does; `passive` does only while nobody's remoted in — `console`
sessions call `M.connect()` at start (and again every ~10s, as a
heartbeat) and `M.disconnect()` on exit, so a crashed session times out
of "connected" instead of wedging passive mode into idle forever. Only
the mode itself is persisted (`/state/controller.state`, survives
reboot); whether an operator is connected right now is deliberately
runtime-only state, since a reboot should always start with nobody
connected.

## lib/fuel.lua

Keeps a turtle from silently failing to move for lack of fuel. CC:Tweaked
checks for a physical obstruction *before* checking fuel internally, so an
out-of-fuel turtle that also happens to have something else in its way at
that exact moment reports `"Movement obstructed"` instead of `"Out of
fuel"` — permanently masking a fuel shortage behind what looks like a
routine, temporary obstruction. `lib/nav.lua`'s `forward`/`back`/`up`/`down`
call into this module before every move so that never happens:

```
dofile("/lib/fuel.lua").ensureFuel()
```

If the turtle already has fuel, this does nothing and returns `true`
immediately. Otherwise it tries, in order: burning whatever's already in
its own inventory, then sucking from and refueling off of any chest
touching it right now — front, up, down, and (since turning costs no
fuel, so even a turtle at 0 fuel can still spin in place to look) left
and right too. It always ends up facing the way it started. Returns
`true` once fuel is sufficient, or `false, reason` if nothing nearby
helped.

Every refuel attempt goes through every inventory slot, not just a bare
`turtle.refuel()` on whatever's currently selected — `turtle.refuel()`
only ever burns the *currently selected* slot, and `turtle.suck()` drops
a pulled item into whichever slot it lands in (the first empty or
already-matching one), which is often not the one that happened to be
selected before the trip started. A bare `turtle.refuel()` right after a
successful suck can easily be checking the wrong slot and find nothing
there, even though fuel really did just get pulled in — turtles have
been observed doing exactly this: visibly pulling fuel out of a chest
and then still reporting no fuel available. Every check here selects
each non-empty slot in turn instead, restoring the original selection
before returning either way.

Takes an optional minimum fuel level (default 1, i.e. "any fuel at all").
`nav.lua`'s movement wrappers just need enough for the one move they're
about to attempt, so they call it bare; `dom-main/mining/vertical.lua`'s
own pre-pass fuel check passes its actual `minFuel` target instead, since
having 1 fuel isn't the same as having enough to keep working.

This is a last-resort, no-movement rescue, not a replacement for
`lib/chestfinder.lua`'s wider radius search — it can only reach chests
already touching the turtle, since finding one further away would require
moving, which is exactly what being out of fuel makes impossible.
`vertical.lua`'s preventive fuel check calls this first and can still fall
back on a real `chestfinder` search of its own, since that check runs
before fuel actually reaches 0.

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
it, for scripts to consume programmatically. Both take an optional
`opts.full` — spin through all 4 compass headings (exactly 4
`turnRight()`s, so it always ends back at the original heading) plus
up/down, surveying the full 6-block "shell" around the turtle instead of
just whichever way it happens to be facing:

```
dofile("/lib/nav.lua").report({ full = true })
```
```
pos: (1, 0, -2)  facing: east  [relative, no GPS fix]
north: minecraft:stone
east:  minecraft:stone
south: air/none
west:  minecraft:coal_ore
up:    air/none
down:  minecraft:dirt
```

Position is anchored to a
real GPS fix if a GPS satellite network is reachable in-world the first
time a turtle uses it, otherwise it's relative to wherever the turtle
was when tracking began (0,0,0) — `gpsFixed` in the returned table tells
you which. Either way, keeping the tracked position accurate requires
routing all movement through `nav.forward()` / `nav.back()` / `nav.up()`
/ `nav.down()` / `nav.turnLeft()` / `nav.turnRight()` instead of calling
`turtle.forward()` etc directly — they return the same values, just also
update the tracked position on success. State lives in `/state/nav.state`,
so it survives the OTA wipe. Before attempting the actual move, each of
these four also checks fuel and tries to auto-recover it if low or empty —
see `lib/fuel.lua` above — so a fuel shortage is always reported as
exactly that, never masked by a coincidental "Movement obstructed."

No GPS network set up? Seed a turtle's position manually (e.g. from the
F3 debug screen) instead:

```
dofile("/lib/nav.lua").setPosition(-1358, 61, -4337, "west")
```

`facing` takes a compass name or a heading number (0=north, 1=east,
2=south, 3=west). This is tracked separately from a real GPS fix
(`source` in the returned table is `"gps"`, `"manual"`, or `"relative"`),
but treated the same as an absolute, trustworthy position everywhere
else — it's on you to get the reading right, since nothing re-verifies it.

`nav.face(facing)` turns to a given heading (same `facing` format as
`setPosition` above) using the fewest turns — at most one `turnLeft`,
`turnRight`, or 180. Used by `lib/pathfind.lua`'s own stepping and by
`dom-main/mining/vertical.lua` to orient itself for a chosen mining
direction regardless of which way the turtle happened to be facing when
the job started.

`nav.isLiquid(name)` — is a block name water or lava. Fluids aren't
solid, so a turtle can already move straight through either one (and
takes no lava damage) without digging first, and digging one does
nothing useful anyway (there's no block to break). Used by
`lib/pathfind.lua` and `dom-main/mining/vertical.lua` to skip straight to
moving instead of wasting a dig attempt whenever the thing in the way
turns out to be a liquid.

`nav.isChest(name)` — is a block name any chest variant (trapped, modded,
etc). Used by `lib/pathfind.lua`'s `"safe"` dig mode and by
`dom-main/mining/vertical.lua`'s own tunnel digging to recognize a chest
and route around it instead of destroying it — see both sections below.

`nav.isComputerCraftBlock(name)` — is a block name a ComputerCraft block
(another turtle, computer, modem, monitor, disk drive, etc — anything in
the `computercraft:` namespace). Used the same way and in the same two
places as `nav.isChest()` above, so a job never bulldozes another turtle
or computer just because it happened to be in the way.

## lib/pathfind.lua

Moves the turtle toward a target position, digging/attacking through
obstacles only if you allow it:

```
dofile("/lib/pathfind.lua").goto(-1358, 65, -4337, { tolerance = 1, allowDig = "safe" })
```

- `tolerance` (default `0`): stop once within this many blocks of the
  target, rather than requiring an exact arrival.
- `allowDig` (default `false`): `false`, `"safe"`, or `"all"`. `false`
  never digs — blocked means blocked, route around via the other axes or
  give up. `"safe"` digs/attacks through obstacles, same as before this
  distinction existed (a bare `true` is still accepted, as an alias for
  `"safe"`, so old callers keep working), *except* a chest or a
  ComputerCraft block (another turtle, computer, modem, etc) — those get
  routed around instead, same as an undiggable block, since a dig-through
  trip has no way to tell a player's storage chest (or another turtle's
  computer) apart from ordinary terrain otherwise. `"all"` is an explicit
  opt-in to dig through either too, for when that's genuinely what's
  wanted.
- `shouldStop` (optional, a `function() -> boolean`): checked before
  every single step — the finest-grained interruption point in this
  repo. A multi-hundred-block trip (or a merely slow one) would otherwise
  block whatever called it for the entire duration with no way to call
  it off; see `lib/job.lua`'s `"goto"` job below, which wires this up to
  `job.stop()`/switching jobs.

There's no map to plan a real route against — a turtle only ever sees
the block immediately touching it, not the wider world — so this isn't
A*. It's a greedy stepper: each step it picks whichever axis (x, z, or y)
has the largest remaining distance and tries to move that way, falling
back to the other axes if that fails. Liquids (`lib/nav.lua`'s
`isLiquid()`) are never dug regardless of `allowDig` — there's nothing to
break, and a turtle can already move straight through one — so hitting a
liquid just moves through it instead of wasting a dig attempt.

**If every axis that would make progress toward the target is blocked
too** (undiggable bedrock, say), it falls back further still to
whichever directions are left — including moving *away* from the target
— since a turtle boxed in by bedrock on every useful side can often
still find a way around by backtracking or sidestepping first, the same
as a person would, even though that step alone moves further from the
target. These fallback directions are tried in **random order**, not a
fixed one — a fixed order that always tries backtracking (the exact
opposite of the blocked toward-target direction) first can oscillate
forever: that backtrack usually succeeds, which just re-presents the
exact same blocker next step, triggering the exact same backtrack again,
and so on, without ever trying the sidesteps that would actually clear
it. Randomizing makes repeating the same losing pair exponentially
unlikely instead of guaranteed. This runs fresh again every step, so
normal toward-target stepping resumes correcting course the moment it's
possible again. Only if *that* also fails — every direction in every
axis is blocked — does
it finally give up, alongside taking more than roughly 4x the starting
distance in steps without arriving (this cap also bounds a turtle that
keeps finding an escape but never a real way through, e.g. repeatedly
backtracking between two dead-end pockets).

A second, subtler oscillation survives escape randomization alone,
though: a toward move can succeed *trivially* by walking right back onto
the cell an escape move just retreated from (that cell is open — the
turtle was just standing on it a moment ago), even though the real
obstacle is still one cell further on. Reported live: a turtle depositing
into a chest (a `allowDig = false` trip, so no digging through any of
this) got boxed in — blocked ahead, left, and right, with the ceiling
directly overhead blocked too — and needed to back up *one* cell before
"up" opened up, since the ceiling only cleared one cell further back, not
directly overhead. It correctly backed up once, but then immediately
walked forward right back into the same pocket (a valid, always-open
toward move — that cell's obviously clear, it just came from there) —
forcing another retreat, forcing the same walk back in, forever, without
ever trying "up" from the retreated-to cell. Every `tryOneStep()` call
now also remembers the cell the *previous* call moved away from, and
deprioritizes (never forbids outright — undoing the previous step is
sometimes genuinely the only option) any candidate, toward or escape,
that would step right back onto it — trying everything else in that same
list first. That's enough for the up-then-around move to actually get
tried instead of immediately undone.

Returns `ok, info` where `info.reason` is `"arrived"`, `"stuck: <error>"`
(every direction failed, including the escape fallback — genuinely boxed
in), `"interrupted"` (`shouldStop()` returned true), or `"gave up: too
many steps"`, alongside the final `distance` and `position`. Builds on
`lib/nav.lua`, so the same rule applies — the tracked position (and thus
this whole feature) only stays accurate if nothing moves the turtle
outside of `nav`/`pathfind` mid-trip.

`lib/nav.lua` (and `lib/pathfind.lua` itself) cache themselves on `_G`
the first time any script `dofile()`s them, so `pathfind.lua`'s own
internal `dofile("/lib/nav.lua")` gets back the exact same nav instance
rather than a second, independently-tracked copy that would silently go
stale the moment `pathfind.goto()` moves the turtle — and repeated
`dofile("/lib/pathfind.lua")` calls (there are several: inside
`lib/job.lua`'s `"goto"` job every time it runs, inside
`lib/chestfinder.lua`, inside `lib/home.lua`) don't each re-parse the
file from disk. Anything else that dofiles either in the same running
session shares those same instances too.

## lib/job.lua

A background job runner, so a long-running task can be redirected from
the remote console *while it's running*. Without this, a command blocks
the poll/listen loop until it returns (see `lib/exec.lua`'s `M.run()`,
shared by both `lib/remote.lua` and `lib/fleet.lua`) — a job meant to run
forever would starve the console of ever hearing a "stop".
`dom-main/turtle_main.lua` runs `job.run()` alongside `fleet.run()`, and
registers every known job by name before starting it:

```
job.register("mine_vertical", dofile("/dom-main/mining/vertical.lua").run)
```

From the remote console, starting/stopping a job is instant — it just
records what should run next; the switch happens on the job's own next
check, not synchronously:

```
dofile("/lib/job.lua").request("mine_vertical", { length = 10 })
dofile("/lib/job.lua").stop()                    -- back to idle
dofile("/lib/job.lua").status()                  -- { current, params, pending }
```

A job function is registered as `function(params, shouldStop)` and is
expected to call `shouldStop()` between steps, returning promptly if it's
true — how often depends on the job (see `dom-main/mining/vertical.lua`
for the pattern, and its own caveat about how coarse-grained that check
is there). Like `lib/nav.lua`, this caches itself on `_G`, since
`dom-main/turtle_main.lua`'s `dofile()` (running the loop) and a remote
command's `dofile()` (requesting a switch) must resolve to the same
instance or the request vanishes into a copy nothing is watching.

A built-in `"goto"` job is always registered, no setup needed — it exists
so an ad-hoc long trip doesn't have to block the console the way running
`dofile("/lib/pathfind.lua").goto(...)` as a plain command does (that
starves the poll loop of answering *anything* else, even a quick
`nav.report()`, until the whole trip finishes):

```
dofile("/lib/job.lua").request("goto", { x = -89, y = 70, z = -87, allowDig = "safe" })
```

Same params as `pathfind.goto()` (`x`, `y`, `z`, `tolerance`,
`allowDig`) — and, unlike a plain command, it *can* be cancelled mid-trip:
`shouldStop` is passed straight through to `pathfind.goto()`, which
checks it before every step, so `dofile("/lib/job.lua").stop()` (or
switching to a different job) interrupts a `"goto"` job almost
immediately rather than only between whole commands.

## lib/home.lua

Remembers a "home" position and gets back to it — pulled out of
`lib/pathfind.lua`/`lib/nav.lua` since "remember where I started, return
there later" is common enough to reuse rather than re-derive per script.
Persisted separately from `lib/nav.lua`'s own state, so ordinary movement
never touches it:

```
dofile("/lib/home.lua").mark()             -- record the current position as home
dofile("/lib/home.lua").go({ tolerance = 1 })  -- pathfind back to it (opts -> pathfind.goto)
dofile("/lib/home.lua").get()              -- the recorded position, or nil if never marked
```

## lib/chestfinder.lua

Locates a nearby chest by physically searching for one — a turtle has no
long-range scan, only `turtle.inspect()` of whatever's touching it, so
this walks an expanding square spiral around a point, inspecting as it
goes:

```
dofile("/lib/chestfinder.lua").find({ maxRadius = 8 })
dofile("/lib/chestfinder.lua").find({ x = 100, y = 64, z = -20, maxRadius = 12 })
```

Defaults to searching around `lib/home.lua`'s recorded position if no
`x`/`y`/`z` is given. Getting there digs through obstacles (`"safe"`
mode — never a chest or ComputerCraft block) since that's typically a
trip home from wherever a job just finished digging, through terrain
nothing has opened up yet; without this, a mining job's own full-
inventory deposit (see `dom-main/mining/vertical.lua`) would fail every
time home isn't already reachable by walking. The search itself, once
there, stays non-destructive: it gives up if a step is blocked rather
than plowing through obstacles — a locator digging through walls near a
base full of player-built structures would be surprising. On success,
returns `{ x,
y, z, name }` for the chest and leaves the turtle facing it (ready to
`turtle.drop()` into it); on failure, returns `nil, reason` and the
turtle is back where the search started, not stranded mid-spiral.
`matchName(blockName)` overrides the default "name contains `chest`"
check, for modded storage that doesn't follow that convention. The
returned table's `direction` (`"front"`, `"up"`, or `"down"`) says which
`turtle.drop*()` reaches it — see `lib/inventory.lua`.

`M.dump(opts)` combines `M.find()` with `lib/inventory.lua`'s
`dropAll()` — find a chest and empty into it in one call:

```
dofile("/lib/chestfinder.lua").dump({})
dofile("/lib/chestfinder.lua").dump({ x = 100, y = 64, z = -200 })
```

Unlike `M.find()`, this defaults to searching around the turtle's own
*current* position, not home — "dump nearby" is the natural default for
an ad-hoc unload, as opposed to a mining job's own unloading, which
wants the long-lived remembered home location. `x`/`y`/`z` (give all
three, or none) and `maxRadius` interact:

- neither given: search around the turtle, radius 8.
- `maxRadius` only: search around the turtle, that radius.
- `x`/`y`/`z` only: search *at* those coordinates, radius 0 — they're
  assumed to already be the chest's exact location.
- both given: search around those coordinates, that radius — an "error"
  margin for when you know roughly, but not exactly, where the chest is.

Returns `{ chest = <M.find()'s result>, emptied = <slots dropped> }` on
success, or `nil, reason` on failure, same as `M.find()`.

## lib/inventory.lua

Inventory space/unloading helpers:

```
dofile("/lib/inventory.lua").isFull()        -- true once every slot has something in it
dofile("/lib/inventory.lua").emptySlotCount() -- how many slots are completely empty
dofile("/lib/inventory.lua").dropAll("front") -- drop everything; "front"/"up"/"down"
dofile("/lib/inventory.lua").report()        -- print + return what's in every slot
```

`isFull()` counts *empty* slots, not remaining stack space — a
half-full stack of cobblestone doesn't help once the next block dug is
iron ore, so "full" means no empty slot left at all, not "no room
anywhere." `dropAll(direction)` drops every nonempty slot that way
(matching `lib/chestfinder.lua`'s returned `direction`) and returns how
many slots it emptied; a slot that fails to drop (destination full) is
just left as-is — this doesn't hunt for another container or retry.
`report()` prints a `slot: NNx name` line per nonempty slot (matching
`lib/nav.lua`'s `report()`/`here()` split) and returns the same data as
a plain list of `{ slot, name, count }`, for scripts to consume.

## dom-main/mining/strip.lua

A branch-mine strip miner — one of what's meant to become several
`dom-main/<category>/*.lua` programs (see the commented-out entries in
`manifest.txt`), deployed flattened to the turtle's root:

```
dofile("/strip.lua").run({ length = 32, branchInterval = 3, branchLength = 5 })
```

Digs a 2-tall main shaft forward; every `branchInterval` blocks it digs a
branch out to each side before continuing. It doesn't chase ore veins —
just clears everything inside the tunnels it digs, like any classic strip
miner — since following veins would need a per-modpack list of ore block
names this script has no way to know. Checks fuel before starting (and
tries `turtle.refuel()` once if short) rather than digging partway and
stranding itself; by default pathfinds back to the starting position when
done (`returnHome = false` to skip that). Doesn't yet manage a full
inventory — that's a known gap for a future pass, same as vein-following.

Options (all optional): `length` (default 32), `branchInterval` (default
2), `branchLength` (default 5), `minFuel` (default 200), `returnHome`
(default true). Returns `ok, info` where `info` is `{ traveled, position
}` on success or an error string on abort (e.g. insufficient fuel).

**Currently WIP and not deployed** (commented out in `manifest.txt`) —
the on-disk file doesn't match this description right now (calls a
`tunnel()` function that no longer exists). Left alone rather than fixed
here since it looked like in-progress local edits.

## dom-main/mining/vertical.lua

A vertical switchback strip miner — leans on a turtle being 1 block
wide/tall (unlike a player) to mine straight down a zigzag staircase
instead of a horizontal shaft. Two independent, perpendicular directions
control it:

- `widthFacing`: the direction the mine advances in *over time*, as it
  starts new **width positions**.
- `lengthFacing`: the direction each **leg** actually digs into — i.e.
  what's being mined right now. Can also be `"all"` (see below).

Since marching parallel to the legs would just walk new width positions
down the same line the legs already dug, `widthFacing` and
`lengthFacing` must be on different axes — north/south paired with
east/west is fine; anything sharing an axis (north+south, or a direction
paired with itself) fails the job immediately with a clear error.

At each width position: descend, dig a `length`-block leg, turn 180°,
repeat — since legs alternate direction every time, leg N and leg N+2
land on the same footprint one level apart. That continues until it
bottoms out (bedrock — the normal end of a **pass**), a leg is blocked
immediately (a side wall), or, if `height` is set, that many blocks have
been descended in this pass. It then gets back under the pass's own
start (x, z) — digging through anything in the way, since most of it is
already opened up by the zigzag's own legs — and climbs straight back up
to the start's y, rather than retracing the zigzag turn by turn.

`lengthFacing = "all"` runs that twice per width position — once in each
perpendicular direction (e.g. west then east) — before advancing,
instead of alternating direction between width positions: both passes
happen at the *same* width position back to back, so the extra travel
cost of covering both directions is paid once per width position, not
once per pass. After however many passes ran, it shifts to a new width
position and starts again, until `width` positions have been done or
it's told to stop.

Registered as a job (`mine_vertical`, see `lib/job.lua` above) rather
than called directly, since a run meant to go forever would otherwise
permanently block the remote console:

```
dofile("/lib/job.lua").request("mine_vertical", {
  widthFacing = "north", lengthFacing = "all", length = 10, stepDown = 5,
  height = 40, width = 20, minFuel = 500, columnStep = 1, columnDY = 2,
})
dofile("/lib/job.lua").stop()
```

- `widthFacing` (default `"north"`): compass name for the direction the
  mine advances in over time — the legs always run perpendicular to it.
  `M.run()` turns to face the right perpendicular itself, once, right at
  the start (via `nav.face()`), so **no particular starting orientation
  is required** — whatever the turtle happens to be facing when the job
  starts is irrelevant.
- `lengthFacing` (default: auto-picked, one of the two directions
  perpendicular to `widthFacing`): compass name for the direction each
  leg digs into, or `"all"` to dig both perpendicular directions per
  width position (doubling leg coverage) rather than just one. Must be
  perpendicular to `widthFacing`, or the job fails immediately with a
  clear error.
- `length` (default 10): blocks dug per forward/backward leg.
- `stepDown` (default 5 with `observant`, 2 without — see `observant`
  below): blocks descended per leg step within a pass.
- `height` (default: none — dig to bedrock): caps how many blocks a
  single pass descends before resetting, even if bedrock is still
  further down. Useful for staying within a known-safe depth band.
- `width` (default: none — unlimited): caps how many width positions the
  job does before stopping cleanly, instead of running forever.
- `minFuel` (default 500): stops before starting a new pass if fuel
  can't be brought above this.
- `columnStep` (default 1): blocks each new width position advances,
  along `widthFacing`, from the previous one.
- `columnDY` (default 2 with `observant`, 1 without — see `observant`
  below): magnitude of the *starting height* shift each new width
  position; sign alternates every time, so width positions
  march steadily outward, staggered up/down around the original height
  (never drifting through a range of offsets — it only ever alternates
  between two fixed ones) rather than all starting at the same y. That
  stagger means adjacent width positions' horizontal legs also land at
  different depths instead of perfectly overlapping — **but only if
  `columnDY` isn't a multiple of `stepDown` (including 0)**, which puts
  both offsets in the same phase (identical depths, no interleaving at
  all). Any other value interleaves to some degree; `columnDY = stepDown
  / 2` exactly is actually the *best* case when `stepDown` is even, not
  a bad one — it spaces the combined leg depths perfectly evenly (the
  defaults without `observant`, `stepDown = 2` and `columnDY = 1`, cover
  *every* depth between two adjacent width positions this way).

The climb back up deliberately doesn't retrace the zigzag turn by turn —
it just repositions horizontally (via `pathfind.goto()`, `allowDig =
"safe"`) and digs straight up. That does mean the turtle isn't guaranteed
to end up facing the same direction it started the pass facing, unlike
the horizontal-shaft `strip.lua`. Travel *between* width positions, over
already-surveyed ground, also uses `pathfind.goto()` with `allowDig =
"safe"` — so a stray surface obstacle can't stall an unattended run; edit
the file if you'd rather it stop and wait instead.

Mining never destroys a chest or a ComputerCraft block (another turtle,
computer, modem, etc) — not just this repositioning travel (`"safe"` mode
already routes around one, same as `goto`/`home` do), but the actual
ore-digging tunnel too, which has no `allowDig` switch to begin with
(mining always digs, by nature) and refuses either unconditionally:
hitting one mid-leg stops just that leg with a clear "chest in the way"
or "ComputerCraft block in the way" reason instead of consuming it, the
same as running into undiggable bedrock would. See `nav.isChest()` and
`nav.isComputerCraftBlock()` above.

Real bedrock near the world floor is patchy, not a clean plane, and is
undiggable regardless of `allowDig` — so the horizontal repositioning
above can fail at the exact depth a pass stopped at, even though the
same move would succeed a few blocks higher (above the pocket, where the
leg that was just dug already opened things up). Rather than give up on
the first failure, it climbs one block and retries, repeating until it
either succeeds or has climbed all the way to the pass's own start
height with no success — at which point something other than a shallow
bedrock pocket is blocking it, and it stops with a clear reason instead
of getting stuck in place. This composes with `pathfind.goto()`'s own
escape fallback (see above) — the climb-and-retry here handles a bedrock
pocket blocking the way *up*, while pathfind's own fallback handles
bedrock blocking the way *across* at a given depth, backtracking or
sidestepping around it before this loop even needs to try a different
height.

Checks fuel once per pass, before it starts — so twice per width position
under `lengthFacing = "all"`. Checks the inventory (`lib/inventory.lua`)
both there *and* after every successful forward leg step, so a full
inventory gets caught within a single leg instead of potentially sitting
full for however long the rest of a deep pass takes. If the inventory's
full and `tidy` (see below) is true, it finds a chest
(`lib/chestfinder.lua`, defaulting to `lib/home.lua`'s position — digging
through obstacles to actually get there, since that's usually a trip back
through terrain the pass just finished mining, not open ground), drops
everything in, and returns to the exact position/heading it was at
before continuing — including resuming a leg it was partway through. If
no chest can be found, or the one found can't take everything, or `tidy`
is false, the whole job stops with a clear reason — even if this
happened mid-leg, deep inside a pass — rather than discarding items or
looping forever hunting for space.

Three optional boolean modes, all default `true`:

- `tidy`: the auto-unload-into-a-chest behavior described above.
  `tidy = false` skips the chest hunt entirely and just stops the job the
  moment the inventory's full, for when no chest is set up nearby or
  you'd rather manage unloading by hand.
- `observant`: turns to peek at the block immediately to the left and
  right (four extra turns) — after every successful forward leg step,
  *and* after every individual block of a `stepDown` descent (not just
  once for the whole descent burst) — and prints anything notable it
  sees. Up and down get checked too on every leg step, but that's
  unconditional (see `thorough` below) since it costs no extra turns;
  `observant` only controls the left/right peek, which does.
  `observant = false` also changes `stepDown`/`columnDY`'s own defaults
  (see below) — with no active left/right scanning, a smaller `stepDown`
  (denser zigzag) and bigger `columnDY` stagger lean on the switchback's
  own geometry for coverage instead.
- `thorough`: chases down veins of anything spotted (any block name
  containing `_ore` anywhere, plus `ancient_debris` — broad on purpose,
  so a modded server's ore naming, including a trailing variant/suffix
  after `_ore` itself, mostly gets picked up too — see `lib/ores.lua`
  below for exceptions) instead of leaving it for a neighboring leg or
  width position to maybe stumble into later. **`thorough` acts on
  whatever gets found regardless of `observant`** — the always-on
  up/down check alone is enough to trigger it even with
  `observant = false`; `observant` just means there's more to look at
  (left/right too). It doesn't separately re-inspect the block a leg is
  about to dig through, since by the time a vein is spotted that way the
  turtle's already committed to consuming it as a normal part of the
  leg. When it does trigger, it flood-fills
  outward through connected valuable neighbors (BFS over each
  newly-mined block's own 6 neighbors, moving to and digging through
  each one via `pathfind.goto()`'s `allowDig`), capped at 48 blocks so a
  huge or misidentified "vein" (an exposed ore-heavy cave wall, say)
  can't turn into an unbounded side quest. `shouldStop` is honored
  between targets while chasing (never mid-step) — but, like the climb
  back to a pass's own top below, the *final* return to the exact
  position/heading the detour started from is not interruptible and
  always happens regardless of how the search ended, since the leg's own
  step-accounting depends on landing back exactly where it left off.

  If chasing a spotted block turns out to be impossible — undiggable
  regardless of tool tier (e.g. a modded end-game ore that needs a
  better pickaxe than this turtle has) — `thorough` remembers that
  block's *name* for the rest of the job run and stops treating it as
  valuable at all, rather than re-discovering and re-chasing the same ore
  type from scratch every time a later leg step or width position grazes
  the same (often large) deposit. `observant`'s own line for a
  since-blacklisted name is tagged accordingly (`(valuable, but couldn't
  be mined earlier -- skipping)`) instead of triggering another attempt.
  This memory doesn't survive past the current job — a fresh `mine`
  request starts with a clean slate.

`shouldStop` reaches `pathfind.goto()`'s per-step check for the travel
*to the next width position* (interrupting that is safe — it's the start
of new work), but deliberately **not** for the climb back to a pass's own
top or the trip back after unloading — those are recovery steps that run
right after a stop was already requested (that's often *why* the pass
stopped), so passing the same `shouldStop` through would abort them
immediately and strand the turtle mid-pass instead of getting it
somewhere safe first.

`shouldStop()` is only checked once per pass iteration (between full
down+forward+turn cycles), not between individual blocks — so expect up
to roughly a `stepDown + length` block actions' worth of latency between
requesting a stop and it actually taking effect.

Marks `lib/home.lua`'s position on first start if nothing's marked yet
(so the very first width position's top survives a mid-run reboot), but
tracks every later width position's own top locally — `home` only
remembers one position, and every width position needs its own.

## lib/ores.lua

Two plain lists, edited directly (no code changes needed) to override
`thorough`'s `_ore`/`ancient_debris` block-name matching (see above) —
for whenever a block should or shouldn't count as valuable, but doesn't
fit that pattern:

```lua
return {
  INCLUDE = {
    -- "silentgear:blasting_ore",
  },
  EXCLUDE = {
    -- "somemod:decorative_ore_block",
  },
}
```

- `INCLUDE`: extra names to treat as valuable even though they don't
  contain `_ore` or `ancient_debris` at all — add one whenever `thorough`
  is skipping over something you want chased.
- `EXCLUDE`: names to *never* treat as valuable, checked before
  everything else — wins over both `INCLUDE` and a genuine `_ore` match.
  Add one whenever `thorough` is chasing something that isn't actually
  worth mining (a purely decorative block that happens to have `_ore` in
  its name, say).

Both lists use plain substring matching against the block's full
registry name (e.g. `"modid:block_name"`) — not an exact match, and not
Lua pattern syntax, so a short, distinctive fragment is enough and
characters like `.` or `-` are matched literally. Add a name and
redeploy for it to take effect.

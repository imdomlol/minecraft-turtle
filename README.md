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
python3 server/turtlectl.py console 12                  # live feed of the turtle's screen
```

Turtle IDs are a name assigned by `lib/identity.lua` (see below) — shown
by `turtlectl.py list` alongside each turtle's last-seen time, and equal
to its CraftOS label too. Commands are plain Lua, evaluated the same way
CraftOS's own `lua` shell program does — bare expressions like
`turtle.getFuelLevel()` print their return value, and `print(...)` output
is captured too.

`console` is different from `watch`: `watch` only shows the result of
commands you send through the relay, while `console` mirrors everything
that ever gets printed to the turtle's actual screen — boot messages,
whatever a "day job" script prints on its own, and remote command
output — as it happens, polled at ~1-2s resolution. It works by wrapping
the turtle's `term` so every write is both shown on the real screen and
shipped to the relay; the relay keeps the last ~20K characters per
turtle in memory only (not persisted to `relay_state.json`), so history
resets on a relay restart.

`console` also accepts input, not just output: type a command and press
enter to send it (queued the same way `send` does) while still watching
the live feed in the same terminal — a background thread handles the
polling/printing, the foreground reads your typed lines. Ctrl-D or
Ctrl-C to stop. Up/down arrows cycle through previously typed lines
within that session (via Python's `readline`, POSIX only).

A command's own progress streams live too, not just the final result:
`lib/remote.lua` mirrors whatever a command `print()`s as it happens,
not only once the whole command returns — important for anything
long-running (a `pathfind.goto()` across a big distance, say), which
would otherwise leave the console looking dead for the entire duration
before dumping everything at once at the end.

## lib/identity.lua

Assigns each turtle a stable name to identify itself to the relay with —
`lib/remote.lua` uses this instead of the raw CC:Tweaked computer ID
(`os.getComputerID()`). That matters because computer IDs are only
unique *within a single world*: if more than one Minecraft server shares
this same relay, two turtles on two different servers can easily both be
ID 0. Since `relay.py` keys everything — the command queue, results,
live console log — purely by that id string, two turtles colliding on it
silently interleave into the same slot: a command meant for one can
execute on the other, and their output mixes together. This is exactly
what happened once already in this project.

Names come from `lib/champions.lua` (League of Legends champions,
cleaned to plain alphanumeric CamelCase so they're safe directly in a
relay URL). On first run, a turtle GETs the relay's `/status` to see
which names are already taken, picks a free one at random, sets it as
both its CraftOS label (`os.setComputerLabel()`) and its relay id, and
persists it to `/state/identity.state` — so it keeps that name across
every future reboot rather than re-registering as a new identity (and a
fragmented result history) each time. If the relay can't be reached yet,
it still picks a name (best-effort, no uniqueness check) rather than
getting stuck unable to identify itself at all.

The uniqueness check is a check-then-act, not an atomic claim — two
turtles picking their very first identity at the exact same instant
could in principle pick the same "free" name. Not worth a real
distributed lock for how narrow that window is (this runs once per
turtle's lifetime, not every boot): `dofile("/lib/identity.lua").get(cfg)`
directly if you ever need to force a re-check.

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

## lib/pathfind.lua

Moves the turtle toward a target position, digging/attacking through
obstacles only if you allow it:

```
dofile("/lib/pathfind.lua").goto(-1358, 65, -4337, { tolerance = 1, allowDig = false })
```

- `tolerance` (default `0`): stop once within this many blocks of the
  target, rather than requiring an exact arrival.
- `allowDig` (default `false`): if the direct route is blocked, dig/attack
  through it instead of only trying to route around via the other axes.
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
back to the other axes if that fails. If every axis fails, or it's taken
more than roughly 4x the starting distance in steps without arriving, it
gives up rather than looping forever. Returns `ok, info` where
`info.reason` is `"arrived"`, `"stuck: <error>"`, `"interrupted"`
(`shouldStop()` returned true), or `"gave up: too many steps"`, alongside
the final `distance` and `position`. Builds on `lib/nav.lua`, so the same
rule applies — the tracked position (and thus this whole feature) only
stays accurate if nothing moves the turtle outside of `nav`/`pathfind`
mid-trip.

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
the remote console *while it's running*. Without this, a remote command
blocks the poll loop until it returns (see `lib/remote.lua`'s
`execute()`) — a job meant to run forever would starve the console of
ever hearing a "stop". `main.lua` runs `job.run()` alongside
`remote.run()`, and registers every known job by name before starting it:

```
job.register("mine_vertical", dofile("/dom-main/mining/vertical.lua").run)
```

From the remote console, starting/stopping a job is instant — it just
records what should run next; the switch happens on the job's own next
check, not synchronously:

```
dofile("/lib/job.lua").request("mine_vertical", { legLength = 10 })
dofile("/lib/job.lua").stop()                    -- back to idle
dofile("/lib/job.lua").status()                  -- { current, params, pending }
```

A job function is registered as `function(params, shouldStop)` and is
expected to call `shouldStop()` between steps, returning promptly if it's
true — how often depends on the job (see `dom-main/mining/vertical.lua`
for the pattern, and its own caveat about how coarse-grained that check
is there). Like `lib/nav.lua`, this caches itself on `_G`, since
`main.lua`'s `dofile()` (running the loop) and a remote command's
`dofile()` (requesting a switch) must resolve to the same instance or the
request vanishes into a copy nothing is watching.

A built-in `"goto"` job is always registered, no setup needed — it exists
so an ad-hoc long trip doesn't have to block the console the way running
`dofile("/lib/pathfind.lua").goto(...)` as a plain command does (that
starves the poll loop of answering *anything* else, even a quick
`nav.report()`, until the whole trip finishes):

```
dofile("/lib/job.lua").request("goto", { x = -89, y = 70, z = -87, allowDig = true })
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
`x`/`y`/`z` is given. Non-destructive: never digs, and gives up if a step
is blocked rather than plowing through obstacles — a locator digging
through walls on its own would be surprising. On success, returns `{ x,
y, z, name }` for the chest and leaves the turtle facing it (ready to
`turtle.drop()` into it); on failure, returns `nil, reason` and the
turtle is back where the search started, not stranded mid-spiral.
`matchName(blockName)` overrides the default "name contains `chest`"
check, for modded storage that doesn't follow that convention. The
returned table's `direction` (`"front"`, `"up"`, or `"down"`) says which
`turtle.drop*()` reaches it — see `lib/inventory.lua`.

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
instead of a horizontal shaft: descend, dig a leg, turn 180°, repeat —
since a descend happens before every leg and legs alternate direction,
leg N and leg N+2 land on the same footprint one level apart, covering a
`legLength * 2`-wide vertical slice as it goes. When a column bottoms out
(bedrock) or a leg is blocked immediately (a side wall), it gets back
under the column's own start (x, z) at the current depth — digging
through anything in the way, since most of that path is already opened
up by the zigzag's own legs crossing through it — then digs straight up
to the start's y. It then shifts to a new column, and starts again —
forever, until told to stop.

Registered as a job (`mine_vertical`, see `lib/job.lua` above) rather
than called directly, since a run meant to go forever would otherwise
permanently block the remote console:

```
dofile("/lib/job.lua").request("mine_vertical", {
  legLength = 10, descend = 3, minFuel = 500, columnDZ = 1, columnDY = 1,
})
dofile("/lib/job.lua").stop()
```

- `legLength` (default 10): blocks dug per forward/backward leg.
- `descend` (default 3): blocks descended before each leg.
- `minFuel` (default 500): stops before starting a new column if fuel
  can't be brought above this.
- `columnDZ` (default 1): z shift applied to each new column, relative
  to the previous one. x never changes.
- `columnDY` (default 1): magnitude of the *starting height* shift each
  new column; sign alternates every column, so columns march steadily in
  z at a fixed x, staggered up/down by 1 around the original height
  rather than all starting at the same y. That stagger means adjacent
  columns' horizontal legs also land at different depths instead of
  perfectly overlapping.

The marching axis (z) is deliberately perpendicular to the legs'
forward/back axis (x, assuming the turtle is facing east or west when
the job starts — see below): marching along x too would just walk new
columns down the same line the legs already dug, instead of spreading
into fresh rock. **This assumes a specific starting orientation** —
`digColumn`'s legs run along whichever horizontal axis the turtle happens
to be facing when the job starts (its very first move is a `descend`,
which doesn't turn it), so marching in z only avoids overlap if that
start facing is east or west. Face the turtle east or west before
starting the job if you're relying on the default `columnDZ`.

The climb back up deliberately doesn't retrace the zigzag turn by turn —
it just repositions horizontally (via `pathfind.goto()`, `allowDig =
true`) and digs straight up. That does mean the turtle isn't guaranteed
to end up facing the same direction it started the column facing, unlike
the horizontal-shaft `strip.lua`. Travel *between* columns, over
already-surveyed ground, also uses `pathfind.goto()` with `allowDig =
true` — so a stray surface obstacle can't stall an unattended run; edit
the file if you'd rather it stop and wait instead.

Real bedrock near the world floor is patchy, not a clean plane, and is
undiggable regardless of `allowDig` — so the horizontal repositioning
above can fail at the exact depth a column stopped at, even though the
same move would succeed a few blocks higher (above the pocket, where the
leg that was just dug already opened things up). Rather than give up on
the first failure, it climbs one block and retries, repeating until it
either succeeds or has climbed all the way to the column's own start
height with no success — at which point something other than a shallow
bedrock pocket is blocking it, and it stops with a clear reason instead
of getting stuck in place.

Checks its inventory (`lib/inventory.lua`) once per column boundary — the
same granularity as the `shouldStop` check, for the same reason. If full,
it finds a chest (`lib/chestfinder.lua`, defaulting to `lib/home.lua`'s
position), drops everything in, and returns to the column it was working
on before continuing. If no chest can be found, or the one found can't
take everything, mining stops with a clear reason rather than discarding
items or looping forever hunting for space.

`shouldStop` reaches `pathfind.goto()`'s per-step check for the travel
*to the next column* (interrupting that is safe — it's the start of new
work), but deliberately **not** for the climb back to a column's own top
or the trip back after unloading — those are recovery steps that run
right after a stop was already requested (that's often *why* the column
stopped), so passing the same `shouldStop` through would abort them
immediately and strand the turtle mid-column instead of getting it
somewhere safe first.

`shouldStop()` is only checked once per column iteration (between full
down+forward+turn cycles), not between individual blocks — so expect up
to roughly a `descend + legLength` block actions' worth of latency
between requesting a stop and it actually taking effect.

Marks `lib/home.lua`'s position on first start if nothing's marked yet
(so the very first column's top survives a mid-run reboot), but tracks
every later column's own top locally — `home` only remembers one
position, and every column needs its own.

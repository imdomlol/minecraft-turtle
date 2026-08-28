#!/usr/bin/env python3
"""
turtlectl.py -- operator CLI for the turtle relay server (see relay.py).

Turtles no longer talk to the relay directly -- a fleet controller
(one plain Computer per Minecraft dimension) is the only thing that
polls the relay; turtles talk to their controller over rednet
(lib/fleet.lua). Every turtle-targeting command below is therefore
addressed by *both* a controller id and a turtle id -- the controller is
who this CLI actually talks to over HTTP, and the turtle id tells that
controller which of its turtles to relay the command to (see
dom-main/controller/roster.lua's proxy()).

Usage:
  turtlectl.py list
  turtlectl.py send <controller> <turtle> <command...>
  turtlectl.py send-fleet <controller> <command...>   -- every turtle behind one controller
  turtlectl.py results <controller> [-n N]
  turtlectl.py watch <controller>
  turtlectl.py clearqueue <controller>  -- discard every currently-queued
                         (not yet delivered) command -- e.g. after a
                         controller was stuck/unreachable for a while and
                         you'd rather it come back idle than work through
                         a long backlog of stale commands
  turtlectl.py console <controller> [--silent]   -- live screen feed; type a command + enter to send it
                                       (always reflows a turtle's screen-wrapped lines back
                                       into one, and always drops this console's own
                                       connect()/disconnect() heartbeat noise; --silent
                                       additionally drops routine per-block "spotted" noise,
                                       short pathfind hops, and raw command echoes -- an
                                       autopilot dispatch (e.g. starting a mining job) is
                                       translated to a plain sentence instead of dropped)
  turtlectl.py roster <controller>    -- every turtle this controller currently knows about
  turtlectl.py worldblock <controller> <x> <y> <z>  -- block recorded at that coordinate, or None
  turtlectl.py whoami <controller> [turtle]  -- basic info about the controller, or a turtle if named
  turtlectl.py mode <controller> [idle|passive|aggressive]  -- get or set the autopilot mode
  turtlectl.py ignore <controller> <turtle>  -- stop autopilot from sending that turtle commands
  turtlectl.py unignore <controller> <turtle>  -- allow autopilot commands again
  turtlectl.py ignored <controller>  -- list turtles ignored by autopilot
  turtlectl.py version <controller> [N] [--bump]  -- get or set the controller's code version
  turtlectl.py addzone <controller> <minX> <minZ> <maxX> <maxZ> <y> <capacity> [height] [--name NAME]
                         -- add a mining zone -- height caps blocks descended per pass
                         (targets a specific Y-band instead of digging to bedrock); --name
                         is an optional, unique, operator-facing label (e.g. "diamonds")
  turtlectl.py removezone <controller> <index>  -- remove a zone by its index or --name (see `zones`)
  turtlectl.py zones <controller>     -- list every configured zone; the fleet balances
                         evenly across all zones with room, not fill-one-then-overflow
  turtlectl.py addchest <controller> <x> <y> <z> [maxX maxY maxZ]
                         -- add a chest location (or, with maxX/Y/Z, a range) turtles can unload/refuel at
  turtlectl.py removechest <controller> <index>  -- remove a configured chest (see `chests` for its index)
  turtlectl.py chests <controller>    -- list every configured chest location/range
  turtlectl.py worldexport <controller> [outfile]  -- pull the whole recorded world map to a
                         local JSON file (default: world_export.json), for an external viewer
  turtlectl.py worldwatch <controller> [jsonfile]  -- live-tail newly-observed blocks: NDJSON
                         on stdout (pipe to your own script), keeps jsonfile patched in place
  turtlectl.py gpshost <controller> [x y z]  -- get (no args) or set this controller's own GPS
                         anchor position -- see dom-main/controller/gpshost.lua

Shortcuts for common turtle-side calls, so you don't have to remember
which lib/*.lua file or function each one is, or which are background
jobs vs plain calls -- these build the right dofile(...) command for you,
and (except `roster`/`worldblock`/`mode` above, which query or control
the controller itself) route it through the named controller to the
named turtle:
  turtlectl.py goto <controller> <turtle> <x> <y> <z> [--tolerance N] [--dig [safe|all]]
  turtlectl.py mine <controller> <turtle> [--width-facing north|east|south|west]
                         [--length-facing north|east|south|west|all]
                         [--length N] [--step-down N] [--height N] [--width N]
                         [--min-fuel N] [--column-step N] [--column-dy N]
                         [--no-tidy] [--no-observant] [--no-thorough]
  turtlectl.py stop <controller> <turtle>              -- stop the running job, back to idle
  turtlectl.py jobstatus <controller> <turtle>
  turtlectl.py pos <controller> <turtle> [--full]                 -- --full spins to see all 6 surrounding blocks
  turtlectl.py setpos <controller> <turtle> <x> <y> <z> <facing>  -- manual calibration (facing: 0-3 or compass name)
  turtlectl.py gpsfix <controller> <turtle>            -- try to acquire a real GPS fix (needs a GPS
                         network -- see the gpshost shortcut above)
  turtlectl.py turnleft <controller> <turtle>
  turtlectl.py turnright <controller> <turtle>
  turtlectl.py inv <controller> <turtle>
  turtlectl.py home <controller> <turtle> [--dig [safe|all]]  -- go to the marked home position
  turtlectl.py markhome <controller> <turtle>          -- mark the current position as home
  turtlectl.py findchest <controller> <turtle> [--x N --y N --z N] [--radius N]
  turtlectl.py dump <controller> <turtle> [--x N --y N --z N] [--radius N]
                         -- find a chest and empty the inventory into it; no
                         -- coords searches near the turtle (radius 8 default),
                         -- coords with no radius means exactly there (radius 0)

--dig on its own (or --dig safe) never digs through a chest or a
ComputerCraft block (another turtle, computer, modem, etc) -- it routes
around either like any other obstacle it can't clear, since a dig-through
trip has no way to tell a player's storage chest (or another turtle's
computer) apart from ordinary terrain otherwise. --dig all is a
deliberate opt-in to dig through either too, for when that's really
what's wanted. Mining (`mine`) has no --dig switch at all since it always
digs by nature, but is chest-safe and ComputerCraft-safe unconditionally
-- it always routes around either in its path.

All of the above accept --wait (and --wait-timeout, default 120s) to
block and print the result once it completes, instead of just queuing
it -- handy for a quick check without a separate `results`/`console` look.

The same shortcuts (minus <controller>, which is already implied by an
active console session, and --wait, which is pointless when you're
already watching the live feed) also work typed directly into an active
`console` session -- turtle-targeting ones still need a <turtle> first,
e.g. `goto Lux -89 55 -87 --dig` or `mine Lux --length 12`; `roster`
takes none. Anything whose first word isn't a shortcut name is sent
through unchanged, as raw Lua, run on the controller itself.

Reads RELAY_URL and RELAY_TOKEN from the environment, falling back to
.relay_url/.relay_token files next to this script if either's unset
(one value per file, no quoting/export syntax -- see _read_config_file());
--url/--token override both. Precedence: --url/--token > environment >
config file > built-in default ("http://localhost:8787" for the URL).
"""
import argparse
import json
import os
import re
import shlex
import sys
import threading
import time
import urllib.error
import urllib.request

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def _read_config_file(name):
    """One-value-per-file fallback for RELAY_URL/RELAY_TOKEN -- e.g.
    .relay_token next to this script, `chmod 600`'d like a real secret.
    Whitespace-only or missing -> None, so callers can chain it with
    `or` the same way they already do for env vars."""
    path = os.path.join(SCRIPT_DIR, name)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        value = f.read().strip()
    return value or None


try:
    import readline  # noqa: F401 -- importing this enables input()'s up/down-arrow
    # history and left/right line editing on POSIX; not available on Windows,
    # where `console` still works, just without that.
except ImportError:
    pass


def request(url, token, method="GET", body=None):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", f"Bearer {token}")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        print(f"error: HTTP {e.code}: {e.read().decode('utf-8', 'replace')}", file=sys.stderr)
        sys.exit(1)
    except urllib.error.URLError as e:
        print(f"error: could not reach relay: {e.reason}", file=sys.stderr)
        sys.exit(1)


def print_result(r):
    status = "ok" if r.get("ok") else "ERR"
    print(f"[{status}] {r.get('command')}\n{r.get('output')}\n")


def wait_for_result(url, token, controller, cmd_id, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        results = request(f"{url}/results?id={controller}", token)
        for r in results:
            if r.get("cmd_id") == cmd_id:
                return r
        time.sleep(2)
    return None


def queue(url, args, description, command):
    """Queues `command` for args.controller, prints a one-line confirmation, and --
    if args.wait is set -- blocks for the result and prints it too."""
    res = request(f"{url}/cmd?id={args.controller}", args.token, "POST", {"command": command})
    print(f"queued {res['cmd_id']} on controller {args.controller}: {description}")
    if getattr(args, "wait", False):
        print("waiting for result...")
        r = wait_for_result(url, args.token, args.controller, res["cmd_id"], args.wait_timeout)
        if r:
            print_result(r)
        else:
            print(f"(no result after {args.wait_timeout}s -- it may still be running; "
                  f"check with `results {args.controller}` or `console {args.controller}`)")


WORLD_CHUNK_SIZE = 16  # must match dom-main/controller/worldstore.lua's own CHUNK_SIZE


def _resolve_palette(data):
    """Converts worldstore.lua's exportAll() shape ({chunkSize, palette:
    {id -> name}, chunks: {chunkKey -> {cellKey -> id}}}) into flat block
    names -- {chunkSize, chunks: {chunkKey -> {cellKey -> name}}}, no
    palette. The palette is purely a CC:Tweaked-side disk-size trick
    (see worldstore.lua's own header comment); nothing on the Python
    side benefits from carrying it forward, and cmd_worldwatch's live
    /blocks feed already only ever carries names, never ids -- so
    resolving here once keeps every JSON file this tool produces in the
    same, simpler shape.

    CC:Tweaked's textutils.serializeJSON encodes paletteById as a JSON
    object keyed by stringified id (see worldstore.lua's loadPalette()
    comment, which relies on exactly that); a JSON array (id = index + 1)
    is accepted too, defensively, in case that ever changes."""
    palette = data.get("palette", {})
    if isinstance(palette, list):
        id_to_name = {str(i + 1): name for i, name in enumerate(palette)}
    else:
        id_to_name = palette

    resolved_chunks = {}
    for chunk_key, cells in data.get("chunks", {}).items():
        resolved_chunks[chunk_key] = {
            cell_key: id_to_name.get(str(block_id), f"unknown:id={block_id}")
            for cell_key, block_id in cells.items()
        }
    return {"chunkSize": data.get("chunkSize", WORLD_CHUNK_SIZE), "chunks": resolved_chunks}


def _chunk_and_cell_key(coord_key, chunk_size):
    """Python mirror of worldstore.lua's chunkCoord()/localKey() -- turns
    a live /blocks entry's "x,y,z" key into the same chunkKey/cellKey
    worldexport's (already palette-resolved) JSON uses, so cmd_worldwatch
    can patch that same file in place. Python's // is floor division
    toward -inf for ints, same as Lua's math.floor(v / n) here -- both
    bucket a negative coordinate like -1 into chunk -1, not 0."""
    x, y, z = (int(v) for v in coord_key.split(","))
    cx, cy, cz = x // chunk_size, y // chunk_size, z // chunk_size
    dx, dy, dz = x - cx * chunk_size, y - cy * chunk_size, z - cz * chunk_size
    return f"{cx}_{cy}_{cz}", f"{dx},{dy},{dz}"


def cmd_worldexport(url, args):
    """Pulls the controller's whole worldstore.lua (every recorded block,
    chunked) and writes it to a local JSON file -- for feeding an
    external viewer/database, not for printing to the console like the
    other shortcuts. Always blocks for the result (there'd be nothing
    useful to do with a bare cmd_id otherwise)."""
    command = 'return dofile("/dom-main/controller/worldstore.lua").exportAll()'
    res = request(f"{url}/cmd?id={args.controller}", args.token, "POST", {"command": command})
    print(f"queued {res['cmd_id']} on controller {args.controller}: export worldstore")
    print("waiting for result...")
    r = wait_for_result(url, args.token, args.controller, res["cmd_id"], args.wait_timeout)
    if not r:
        print(f"error: no result after {args.wait_timeout}s -- it may still be running; "
              f"check with `results {args.controller}`", file=sys.stderr)
        sys.exit(1)
    if not r.get("ok"):
        print(f"error: {r.get('output')}", file=sys.stderr)
        sys.exit(1)

    # lib/exec.lua prefixes a single non-string return value's text with
    # "= " (see its `suffix = "= " .. ...` branch) -- exportAll() returns
    # a JSON string, so that's the only thing to strip before it's valid
    # JSON on its own.
    output = r.get("output", "")
    if output.startswith("= "):
        output = output[2:]

    try:
        raw = json.loads(output)
    except json.JSONDecodeError as e:
        print(f"error: controller's response wasn't valid JSON ({e}); raw output written to {args.outfile}.raw",
              file=sys.stderr)
        with open(f"{args.outfile}.raw", "w") as f:
            f.write(output)
        sys.exit(1)

    data = _resolve_palette(raw)
    with open(args.outfile, "w") as f:
        json.dump(data, f, indent=2)
    chunk_count = len(data.get("chunks", {}))
    print(f"wrote {chunk_count} chunk(s) to {args.outfile}")


def cmd_worldwatch(url, args):
    """Long-polls the relay's /blocks endpoint for this controller and
    keeps a local JSON cache (the same flat {chunkSize, chunks} shape
    cmd_worldexport() writes -- run worldexport first to seed it, or
    just let it start empty and fill in from here) patched in place, so
    a large map never needs a full re-pull just to pick up what's
    changed. Also prints each new batch as one line of NDJSON to stdout
    (status/progress instead goes to stderr, so stdout stays clean),
    so a separate script -- yours -- can do
      turtlectl.py worldwatch Rakan | python3 my_db_writer.py
    and read stdin line by line. What that script then does with each
    batch (a SQLite upsert, or anything else) is deliberately not this
    file's concern."""
    chunk_size = WORLD_CHUNK_SIZE
    chunks = {}
    if os.path.exists(args.jsonfile):
        with open(args.jsonfile) as f:
            cached = json.load(f)
        chunk_size = cached.get("chunkSize", WORLD_CHUNK_SIZE)
        chunks = cached.get("chunks", {})
        print(f"loaded {len(chunks)} cached chunk(s) from {args.jsonfile}", file=sys.stderr)

    print(f"watching controller {args.controller} for live block updates (ctrl-c to stop)", file=sys.stderr)
    cursor = 0
    try:
        while True:
            resp = request(f"{url}/blocks?id={args.controller}&after={cursor}", args.token)
            batches = resp.get("batches", [])
            if batches:
                for batch in batches:
                    cursor = max(cursor, batch["seq"])
                    print(json.dumps(batch))
                    sys.stdout.flush()
                    for coord_key, name in batch["entries"].items():
                        chunk_key, cell_key = _chunk_and_cell_key(coord_key, chunk_size)
                        chunks.setdefault(chunk_key, {})[cell_key] = name
                with open(args.jsonfile, "w") as f:
                    json.dump({"chunkSize": chunk_size, "chunks": chunks}, f, indent=2)
            else:
                cursor = resp.get("cursor", cursor)
            time.sleep(args.poll_interval)
    except KeyboardInterrupt:
        pass


def lua_bool(b):
    return "true" if b else "false"


def lua_string(s):
    """Escapes an arbitrary Python string as a double-quoted Lua string
    literal -- used to embed a turtle name or a raw command as a Lua
    argument (dom-main/controller/roster.lua's proxy()/proxyAll()),
    rather than the long-bracket [[ ]] form, since a `send`'s raw command
    text isn't under our control and could itself contain `]]`."""
    escaped = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    return f'"{escaped}"'


def proxy_wrap(turtle, inner_command):
    """Wraps a Lua command meant for one specific turtle so it actually
    runs there: the outer command (what gets queued for the controller)
    asks dom-main/controller/roster.lua to relay `inner_command` over
    rednet and wait for the result -- see roster.lua's M.proxy() for why
    this needs no changes on the turtle or relay.py side at all."""
    return f'return dofile("/dom-main/controller/roster.lua").proxy({lua_string(turtle)}, {lua_string(inner_command)})'


def lua_dig(mode):
    """mode is None (no --dig -- never dig), "safe" (dig, but never a
    chest or ComputerCraft block -- the default the instant --dig is
    given at all), or "all" (dig through anything, chests and
    ComputerCraft blocks included -- an explicit opt-in)."""
    if mode is None:
        return "false"
    return f'"{mode}"'


def facing_lua(facing):
    """facing is either a heading number (0-3) or a compass name -- pass
    numbers through bare, quote everything else so Lua sees a string."""
    if facing.lstrip("-").isdigit():
        return facing
    return f'"{facing}"'


# Shared by both the top-level `turtlectl.py goto ...` subcommand and a
# `goto ...` line typed into an active `console` session -- ns just needs
# the same attribute names in both cases (see build_console_parser()
# below, whose subparsers mirror main()'s). Returns (description, lua).
# TURTLE_SHORTCUTS entries build the command that runs *on the turtle*
# (proxy_wrap() handles getting it there); CONTROLLER_SHORTCUTS entries
# build a command that runs on the controller itself and are queued
# unwrapped. `whoami` is the one OPTIONAL_TURTLE_SHORTCUTS entry -- it
# builds one or the other Lua string itself, depending on whether ns has
# a turtle name, since "basic info about this device" means something
# different on each side (see its own branch below).
def build_shortcut(cmd, ns):
    if cmd == "goto":
        command = (
            'dofile("/lib/job.lua").request("goto", { '
            f'x = {ns.x}, y = {ns.y}, z = {ns.z}, '
            f'tolerance = {ns.tolerance}, allowDig = {lua_dig(ns.dig)} }})'
        )
        return f"goto ({ns.x}, {ns.y}, {ns.z}) tolerance={ns.tolerance} dig={ns.dig or 'off'}", command

    if cmd == "mine":
        fields = []
        if ns.width_facing is not None: fields.append(f'widthFacing = "{ns.width_facing}"')
        if ns.length_facing is not None: fields.append(f'lengthFacing = "{ns.length_facing}"')
        if ns.length is not None: fields.append(f"length = {ns.length}")
        if ns.step_down is not None: fields.append(f"stepDown = {ns.step_down}")
        if ns.height is not None: fields.append(f"height = {ns.height}")
        if ns.width is not None: fields.append(f"width = {ns.width}")
        if ns.min_fuel is not None: fields.append(f"minFuel = {ns.min_fuel}")
        if ns.column_step is not None: fields.append(f"columnStep = {ns.column_step}")
        if ns.column_dy is not None: fields.append(f"columnDY = {ns.column_dy}")
        if ns.tidy is not None: fields.append(f"tidy = {lua_bool(ns.tidy)}")
        if ns.observant is not None: fields.append(f"observant = {lua_bool(ns.observant)}")
        if ns.thorough is not None: fields.append(f"thorough = {lua_bool(ns.thorough)}")
        params = "{ " + ", ".join(fields) + " }"
        return f"mine_vertical {params}", f'dofile("/lib/job.lua").request("mine_vertical", {params})'

    if cmd == "stop":
        return "stop current job", 'dofile("/lib/job.lua").stop()'

    if cmd == "jobstatus":
        return "job status", 'return dofile("/lib/job.lua").status()'

    if cmd == "pos":
        if getattr(ns, "full", False):
            return "position report (full spin)", 'return dofile("/lib/nav.lua").report({ full = true })'
        return "position report", 'return dofile("/lib/nav.lua").report()'

    if cmd == "turnleft":
        return "turn left", 'dofile("/lib/nav.lua").turnLeft(); return dofile("/lib/nav.lua").report()'

    if cmd == "turnright":
        return "turn right", 'dofile("/lib/nav.lua").turnRight(); return dofile("/lib/nav.lua").report()'

    if cmd == "setpos":
        command = (
            f'dofile("/lib/nav.lua").setPosition({ns.x}, {ns.y}, {ns.z}, {facing_lua(ns.facing)}); '
            'return dofile("/lib/nav.lua").report()'
        )
        return f"set position to ({ns.x}, {ns.y}, {ns.z}) facing {ns.facing}", command

    if cmd == "gpsfix":
        command = (
            'local ok, result = dofile("/lib/nav.lua").reacquireGPS(); '
            'if not ok then return false, result end; '
            'return true, dofile("/lib/nav.lua").report()'
        )
        return "acquire a real GPS fix", command

    if cmd == "inv":
        return "inventory report", 'return dofile("/lib/inventory.lua").report()'

    if cmd == "home":
        command = f'return dofile("/lib/home.lua").go({{ allowDig = {lua_dig(ns.dig)} }})'
        return f"go home dig={ns.dig or 'off'}", command

    if cmd == "markhome":
        return "mark current position as home", 'return dofile("/lib/home.lua").mark()'

    if cmd == "findchest":
        fields = [f"maxRadius = {ns.radius}"]
        if ns.x is not None and ns.y is not None and ns.z is not None:
            fields += [f"x = {ns.x}", f"y = {ns.y}", f"z = {ns.z}"]
        params = "{ " + ", ".join(fields) + " }"
        return f"find chest {params}", f'return dofile("/lib/chestfinder.lua").find({params})'

    if cmd == "dump":
        fields = []
        if ns.x is not None and ns.y is not None and ns.z is not None:
            fields += [f"x = {ns.x}", f"y = {ns.y}", f"z = {ns.z}"]
        if ns.radius is not None:
            fields.append(f"maxRadius = {ns.radius}")
        params = "{ " + ", ".join(fields) + " }"
        return f"dump inventory {params}", f'return dofile("/lib/chestfinder.lua").dump({params})'

    if cmd == "whoami":
        if getattr(ns, "turtle", None):
            command = (
                'return { role = "turtle", '
                'id = dofile("/lib/identity.lua").get(nil), '
                'computerId = os.getComputerID(), label = os.getComputerLabel(), '
                'fuel = turtle.getFuelLevel(), fuelLimit = turtle.getFuelLimit(), '
                'position = dofile("/lib/nav.lua").getPosition(), '
                'job = dofile("/lib/job.lua").status(), uptime = os.clock() }'
            )
        else:
            command = (
                'local n = 0 for _ in pairs(dofile("/dom-main/controller/roster.lua").all()) do n = n + 1 end; '
                'return { role = "controller", '
                'id = dofile("/lib/identity.lua").get(nil), '
                'computerId = os.getComputerID(), label = os.getComputerLabel(), '
                'turtleCount = n, uptime = os.clock() }'
            )
        return "whoami", command

    if cmd == "roster":
        return "fleet roster", 'return dofile("/dom-main/controller/roster.lua").report()'

    if cmd == "worldblock":
        command = f'return dofile("/dom-main/controller/worldstore.lua").query({ns.x}, {ns.y}, {ns.z})'
        return f"block at ({ns.x}, {ns.y}, {ns.z})", command

    if cmd == "mode":
        if getattr(ns, "value", None):
            command = f'return dofile("/dom-main/controller/mode.lua").set("{ns.value}")'
            return f"set mode to {ns.value}", command
        return "current mode", 'return dofile("/dom-main/controller/mode.lua").get()'

    if cmd == "ignore":
        command = f'return dofile("/dom-main/controller/mode.lua").ignore({lua_string(ns.turtle)})'
        return f"ignore turtle {ns.turtle}", command

    if cmd == "unignore":
        command = f'return dofile("/dom-main/controller/mode.lua").unignore({lua_string(ns.turtle)})'
        return f"stop ignoring turtle {ns.turtle}", command

    if cmd == "ignored":
        return "ignored turtles", 'return dofile("/dom-main/controller/mode.lua").listIgnored()'

    if cmd == "version":
        if getattr(ns, "bump", False):
            return "bump version", 'return dofile("/dom-main/controller/version.lua").bump()'
        if getattr(ns, "n", None) is not None:
            return f"set version to {ns.n}", f'return dofile("/dom-main/controller/version.lua").set({ns.n})'
        return "current version", 'return dofile("/dom-main/controller/version.lua").get()'

    if cmd == "addzone":
        fields = [ns.minX, ns.minZ, ns.maxX, ns.maxZ, ns.y, ns.capacity]
        args_str = ", ".join(str(f) for f in fields)
        # height must be filled in (as `nil`) whenever name is given, even
        # if height itself was omitted -- Lua has no keyword args, so
        # addZone(...)'s 8th positional (name) can't be reached by just
        # skipping the 7th (height) the way the CLI itself allows.
        args_str += f", {ns.height if ns.height is not None else 'nil'}"
        if ns.name is not None:
            args_str += f", {lua_string(ns.name)}"
        command = f'return dofile("/dom-main/controller/worksite.lua").addZone({args_str})'
        description = f"add zone ({ns.minX},{ns.minZ})-({ns.maxX},{ns.maxZ}) y={ns.y} capacity={ns.capacity}"
        if ns.height is not None:
            description += f" height={ns.height}"
        if ns.name is not None:
            description += f' name="{ns.name}"'
        return description, command

    if cmd == "removezone":
        target = ns.index
        arg = target if re.fullmatch(r"-?\d+", target) else lua_string(target)
        return f"remove zone {target}", f'return dofile("/dom-main/controller/worksite.lua").removeZone({arg})'

    if cmd == "zones":
        return "configured zones", 'return dofile("/dom-main/controller/worksite.lua").listZones()'

    if cmd == "addchest":
        fields = [ns.x, ns.y, ns.z, ns.maxX, ns.maxY, ns.maxZ]
        args_str = ", ".join("nil" if f is None else str(f) for f in fields)
        command = f'return dofile("/dom-main/controller/worksite.lua").addChest({args_str})'
        if ns.maxX is None and ns.maxY is None and ns.maxZ is None:
            description = f"add chest at ({ns.x},{ns.y},{ns.z})"
        else:
            description = f"add chest range ({ns.x},{ns.y},{ns.z})-({ns.maxX},{ns.maxY},{ns.maxZ})"
        return description, command

    if cmd == "removechest":
        return f"remove chest #{ns.index}", f'return dofile("/dom-main/controller/worksite.lua").removeChest({ns.index})'

    if cmd == "chests":
        return "configured chests", 'return dofile("/dom-main/controller/worksite.lua").listChests()'

    if cmd == "gpshost":
        if ns.x is not None and ns.y is not None and ns.z is not None:
            command = f'return dofile("/dom-main/controller/gpshost.lua").set({ns.x}, {ns.y}, {ns.z})'
            return f"set this controller's GPS anchor position to ({ns.x}, {ns.y}, {ns.z})", command
        if ns.x is not None or ns.y is not None or ns.z is not None:
            print("error: gpshost needs all of x y z, or none of them (to just view it)", file=sys.stderr)
            sys.exit(1)
        return "current GPS anchor position", 'return dofile("/dom-main/controller/gpshost.lua").get()'

    raise ValueError(f"unknown shortcut: {cmd}")


TURTLE_SHORTCUTS = {
    "goto", "mine", "stop", "jobstatus", "pos", "setpos", "gpsfix", "turnleft", "turnright",
    "inv", "home", "markhome", "findchest", "dump",
}
CONTROLLER_SHORTCUTS = {
    "roster", "worldblock", "mode", "version", "addzone", "removezone", "zones",
    "ignore", "unignore", "ignored", "addchest", "removechest", "chests", "gpshost",
}
# whoami is the one shortcut where <turtle> is optional -- see its
# build_shortcut() branch and the unified dispatch below, which proxies
# to a turtle whenever one was given rather than checking set membership.
OPTIONAL_TURTLE_SHORTCUTS = {"whoami"}
SHORTCUT_NAMES = TURTLE_SHORTCUTS | CONTROLLER_SHORTCUTS | OPTIONAL_TURTLE_SHORTCUTS


class ConsoleArgError(Exception):
    """Raised instead of argparse's default sys.exit(2), so a mistyped
    shortcut in an active console session prints an error and loops back
    to the prompt instead of killing the whole session."""


class ConsoleArgParser(argparse.ArgumentParser):
    def error(self, message):
        raise ConsoleArgError(message)

    def exit(self, status=0, message=None):
        if message:
            raise ConsoleArgError(message)


# Same shortcuts as main()'s subparsers, minus <controller> (the console
# is already pinned to one controller) and --wait/--wait-timeout
# (pointless -- you're already watching the live feed). Turtle-targeting
# shortcuts still need a <turtle> first, since one controller relays to
# many turtles; `roster` (a controller shortcut) takes none.
def build_console_parser():
    p = ConsoleArgParser(prog="", add_help=False)
    sub = p.add_subparsers(dest="cmd")

    gp = sub.add_parser("goto", add_help=False)
    gp.add_argument("turtle")
    gp.add_argument("x", type=int)
    gp.add_argument("y", type=int)
    gp.add_argument("z", type=int)
    gp.add_argument("--tolerance", type=int, default=0)
    gp.add_argument("--dig", nargs="?", const="safe", choices=["safe", "all"], default=None)

    mp = sub.add_parser("mine", add_help=False)
    mp.add_argument("turtle")
    mp.add_argument("--width-facing", choices=["north", "east", "south", "west"])
    mp.add_argument("--length-facing", choices=["north", "east", "south", "west", "all"])
    mp.add_argument("--length", type=int)
    mp.add_argument("--step-down", type=int)
    mp.add_argument("--height", type=int)
    mp.add_argument("--width", type=int)
    mp.add_argument("--min-fuel", type=int)
    mp.add_argument("--column-step", type=int)
    mp.add_argument("--column-dy", type=int)
    mp.add_argument("--tidy", action=argparse.BooleanOptionalAction, default=None)
    mp.add_argument("--observant", action=argparse.BooleanOptionalAction, default=None)
    mp.add_argument("--thorough", action=argparse.BooleanOptionalAction, default=None)

    sp = sub.add_parser("stop", add_help=False)
    sp.add_argument("turtle")

    jp = sub.add_parser("jobstatus", add_help=False)
    jp.add_argument("turtle")

    posp = sub.add_parser("pos", add_help=False)
    posp.add_argument("turtle")
    posp.add_argument("--full", action="store_true")

    spc = sub.add_parser("setpos", add_help=False)
    spc.add_argument("turtle")
    spc.add_argument("x", type=int)
    spc.add_argument("y", type=int)
    spc.add_argument("z", type=int)
    spc.add_argument("facing")

    gfp = sub.add_parser("gpsfix", add_help=False)
    gfp.add_argument("turtle")

    tlp = sub.add_parser("turnleft", add_help=False)
    tlp.add_argument("turtle")

    trp = sub.add_parser("turnright", add_help=False)
    trp.add_argument("turtle")

    ip = sub.add_parser("inv", add_help=False)
    ip.add_argument("turtle")

    hp = sub.add_parser("home", add_help=False)
    hp.add_argument("turtle")
    hp.add_argument("--dig", nargs="?", const="safe", choices=["safe", "all"], default=None)

    mhp = sub.add_parser("markhome", add_help=False)
    mhp.add_argument("turtle")

    fcp = sub.add_parser("findchest", add_help=False)
    fcp.add_argument("turtle")
    fcp.add_argument("--x", type=int)
    fcp.add_argument("--y", type=int)
    fcp.add_argument("--z", type=int)
    fcp.add_argument("--radius", type=int, default=8)

    dp = sub.add_parser("dump", add_help=False)
    dp.add_argument("turtle")
    dp.add_argument("--x", type=int)
    dp.add_argument("--y", type=int)
    dp.add_argument("--z", type=int)
    dp.add_argument("--radius", type=int)

    sub.add_parser("roster", add_help=False)

    wbp = sub.add_parser("worldblock", add_help=False)
    wbp.add_argument("x", type=int)
    wbp.add_argument("y", type=int)
    wbp.add_argument("z", type=int)

    wap = sub.add_parser("whoami", add_help=False)
    wap.add_argument("turtle", nargs="?")

    modp = sub.add_parser("mode", add_help=False)
    modp.add_argument("value", nargs="?", choices=["idle", "passive", "aggressive"])

    igp = sub.add_parser("ignore", add_help=False)
    igp.add_argument("turtle")

    uigp = sub.add_parser("unignore", add_help=False)
    uigp.add_argument("turtle")

    sub.add_parser("ignored", add_help=False)

    verp = sub.add_parser("version", add_help=False)
    verp.add_argument("n", nargs="?", type=int)
    verp.add_argument("--bump", action="store_true")

    azp = sub.add_parser("addzone", add_help=False)
    for argname in ("minX", "minZ", "maxX", "maxZ", "y", "capacity"):
        azp.add_argument(argname, type=int)
    azp.add_argument("height", nargs="?", type=int)
    azp.add_argument("--name")

    rzp = sub.add_parser("removezone", add_help=False)
    rzp.add_argument("index")

    sub.add_parser("zones", add_help=False)

    acp = sub.add_parser("addchest", add_help=False)
    acp.add_argument("x", type=int)
    acp.add_argument("y", type=int)
    acp.add_argument("z", type=int)
    acp.add_argument("maxX", nargs="?", type=int)
    acp.add_argument("maxY", nargs="?", type=int)
    acp.add_argument("maxZ", nargs="?", type=int)

    rcp = sub.add_parser("removechest", add_help=False)
    rcp.add_argument("index", type=int)

    sub.add_parser("chests", add_help=False)

    ghp = sub.add_parser("gpshost", add_help=False)
    ghp.add_argument("x", nargs="?", type=int)
    ghp.add_argument("y", nargs="?", type=int)
    ghp.add_argument("z", nargs="?", type=int)

    return p


CONSOLE_HELP = """\
shortcuts (controller and --wait are implied -- you're already watching
this controller live; turtle-targeting ones still need a <turtle> name):
  goto <turtle> <x> <y> <z> [--tolerance N] [--dig [safe|all]]  move to (x, y, z) as a background job
  mine <turtle> [--width-facing north|east|south|west] [--length-facing north|east|south|west|all]
       [--length N] [--step-down N] [--height N] [--width N] [--min-fuel N]
       [--column-step N] [--column-dy N] [--no-tidy] [--no-observant] [--no-thorough]
                                                start the vertical strip miner (see below)
  stop <turtle>                                stop the running job (back to idle)
  jobstatus <turtle>                           what job is running / queued
  pos <turtle> [--full]                        report position and surroundings (--full spins to see all 6 sides)
  setpos <turtle> <x> <y> <z> <facing>         manually calibrate position/heading (0-3 or compass name)
  gpsfix <turtle>                              try to acquire a real GPS fix (needs a GPS network -- see gpshost)
  turnleft <turtle>                            turn left 90 degrees
  turnright <turtle>                           turn right 90 degrees
  inv <turtle>                                 report inventory contents
  home <turtle> [--dig [safe|all]]             go to the marked home position
  markhome <turtle>                            mark the current position as home
  findchest <turtle> [--x N --y N --z N] [--radius N]   search for a nearby chest
  dump <turtle> [--x N --y N --z N] [--radius N]        find a chest and empty the inventory into it
                                                (see below for how --x/--y/--z and --radius interact)
  roster                                       every turtle this controller currently knows about
  worldblock <x> <y> <z>                       block recorded at that coordinate, or None
  whoami [turtle]                              basic info about the controller, or that turtle if named
  mode [idle|passive|aggressive]               get or set the autopilot mode (omit to just report it)
  version [N] [--bump]                         get or set the controller's manually-tracked code version
  addzone <minX> <minZ> <maxX> <maxZ> <y> <capacity> [height] [--name NAME]
                                                add a mining zone -- height caps blocks descended per
                                                pass (targets a Y-band instead of digging to bedrock);
                                                the fleet balances evenly across every zone with room;
                                                --name is an optional, unique, operator-facing label
  removezone <index>                           remove a zone by its index or --name (see `zones`)
  zones                                         list every configured zone
  addchest <x> <y> <z> [maxX maxY maxZ]        add a chest location (or range) to unload/refuel at --
                                                multiple may be added; the nearest to a turtle is used
  removechest <index>                          remove a configured chest (see `chests` for its index)
  chests                                       list every configured chest location/range
  gpshost [x y z]                              get (no args) or set this controller's own GPS anchor position
  help                                         show this list

mode governs the (not yet built) autopilot scheduler, not manual commands
above -- those always work no matter what mode is set:
  idle        autopilot never issues commands
  aggressive  autopilot always issues commands, connected or not
  passive     autopilot issues commands only while nobody's connected --
              the moment you connect (this console session counts), it
              defers to you until you disconnect

version is manual, not tied to git -- bump it once you've pushed new code
AND actually want the fleet to reboot and pick it up. Turtles check it on
every heartbeat and reboot on their own once safe to (a mid-job turtle
finishes its current leg/height-step first, same latency as `stop`) --
never mid-job, and never losing progress even if interrupted, since
mine_vertical checkpoints and auto-resumes across a reboot regardless of
why it happened.

--dig safe (bare --dig's default) routes around a chest or a ComputerCraft
block (another turtle, computer, modem, etc) instead of digging it, since
a dig-through trip can't otherwise tell a player's storage chest (or
another turtle's computer) apart from ordinary terrain; --dig all is an
explicit opt-in to dig through either too. mine has no --dig switch (it
always digs) but is chest-safe and ComputerCraft-safe the same way,
unconditionally.

mine's directions (must be perpendicular to each other):
  width-facing   direction the mine advances in over time (default north)
  length-facing  direction each leg digs into (default: auto-picked perpendicular to
                 width-facing); "all" digs both perpendicular directions per width
                 position (west then east, or north then south) before offsetting,
                 doubling leg coverage with minimal extra backtracking

mine's step sizes (default 5/2 with --observant, 2/1 without -- see below):
  step-down   blocks descended per leg step within a pass
  column-dy   start-height shift per new width position; alternates sign each
              time -- avoid a value that's a multiple of step-down (including 0),
              or adjacent width positions' legs land at identical depths instead
              of interleaving; step-down / 2 exactly is actually the best case
              when step-down is even, not a bad one

mine's caps (default unlimited -- dig to bedrock / run forever):
  height   blocks descended per pass before resetting, instead of going to bedrock
  width    how many width positions to do before stopping

mine's three modes (all default true, --no-<mode> to disable):
  tidy       auto-unload into a chest when full, instead of just stopping
  observant  peek left/right on every leg step and every stepDown block (also
             changes step-down/column-dy's own defaults: 5/2 with, 2/1 without)
  thorough   chase veins of anything spotted -- up/down always, left/right only
             if observant -- works even with observant off

dump's --x/--y/--z and --radius interact:
  neither given         search around the turtle, radius 8
  --radius only         search around the turtle, that radius
  --x/--y/--z only      search AT those coords, radius 0 (exact -- assumed to be the chest)
  both given            search around those coords, that radius (an "error" margin)

anything else you type is sent to the controller as raw Lua (not proxied
to any turtle), e.g.:
  dofile("/dom-main/controller/roster.lua").report()\
"""


def main():
    p = argparse.ArgumentParser(description="Operator CLI for the turtle relay.")
    p.add_argument("--url", default=os.environ.get("RELAY_URL") or _read_config_file(".relay_url")
                                     or "http://localhost:8787")
    p.add_argument("--token", default=os.environ.get("RELAY_TOKEN") or _read_config_file(".relay_token"))
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="List known controllers.")

    sp = sub.add_parser("send", help="Send raw Lua to one turtle behind a controller.")
    sp.add_argument("controller")
    sp.add_argument("turtle")
    sp.add_argument("command", nargs="+")

    sf = sub.add_parser("send-fleet", help="Send raw Lua to every turtle behind a controller.")
    sf.add_argument("controller")
    sf.add_argument("command", nargs="+")

    rp = sub.add_parser("results", help="Recent results a controller has posted.")
    rp.add_argument("controller")
    rp.add_argument("-n", type=int, default=10)

    wp = sub.add_parser("watch", help="Live-tail a controller's results.")
    wp.add_argument("controller")

    cqp = sub.add_parser("clearqueue", help="Discard every currently-queued (not yet delivered) "
                                             "command for a controller.")
    cqp.add_argument("controller")

    wep = sub.add_parser("worldexport", help="Pull the controller's whole recorded world map to a local JSON file.")
    wep.add_argument("controller")
    wep.add_argument("outfile", nargs="?", default="world_export.json",
                      help="Local path to write the JSON to (default: world_export.json).")
    wep.add_argument("--wait-timeout", type=int, default=120,
                      help="Seconds to wait for the export to come back (default 120).")

    wwp = sub.add_parser("worldwatch", help="Live-tail newly-observed world blocks; NDJSON on stdout, "
                                             "also keeps a local JSON cache patched in place.")
    wwp.add_argument("controller")
    wwp.add_argument("jsonfile", nargs="?", default="world_export.json",
                      help="Local JSON cache to load from and keep patched (default: world_export.json -- "
                           "the same file worldexport writes, so run that first to seed it).")
    wwp.add_argument("--poll-interval", type=int, default=2,
                      help="Seconds between polls of the relay's /blocks endpoint (default 2).")

    cp = sub.add_parser("console", help="Live console for a controller.")
    cp.add_argument("controller")
    cp.add_argument("-s", "--silent", action="store_true",
                     help="Suppress per-block 'spotted' lines, valuable or not -- job progress "
                          "(vein summaries, leg/pass done, dumping inventory, dispatches, etc) still prints.")

    # Shortcuts below all accept --wait/--wait-timeout via this shared parent.
    waitp = argparse.ArgumentParser(add_help=False)
    waitp.add_argument("--wait", action="store_true",
                        help="Block and print the result once it completes.")
    waitp.add_argument("--wait-timeout", type=int, default=120,
                        help="Seconds to wait with --wait (default 120).")

    rop = sub.add_parser("roster", parents=[waitp], help="Every turtle this controller currently knows about.")
    rop.add_argument("controller")

    wbp = sub.add_parser("worldblock", parents=[waitp],
                          help="Look up the block this controller has recorded at (x, y, z).")
    wbp.add_argument("controller")
    wbp.add_argument("x", type=int)
    wbp.add_argument("y", type=int)
    wbp.add_argument("z", type=int)

    wap = sub.add_parser("whoami", parents=[waitp],
                          help="Basic info about a device -- the controller if <turtle> is omitted, that turtle if given.")
    wap.add_argument("controller")
    wap.add_argument("turtle", nargs="?", help="Omit to ask the controller about itself.")

    modp = sub.add_parser("mode", parents=[waitp],
                           help="Get or set the controller's autopilot mode (idle/passive/aggressive).")
    modp.add_argument("controller")
    modp.add_argument("value", nargs="?", choices=["idle", "passive", "aggressive"],
                       help="Omit to just report the current mode.")

    igp = sub.add_parser("ignore", parents=[waitp],
                          help="Tell the controller autopilot not to command a specific turtle.")
    igp.add_argument("controller")
    igp.add_argument("turtle")

    uigp = sub.add_parser("unignore", parents=[waitp],
                           help="Allow the controller autopilot to command a turtle again.")
    uigp.add_argument("controller")
    uigp.add_argument("turtle")

    ignp = sub.add_parser("ignored", parents=[waitp],
                           help="List turtles currently ignored by the controller autopilot.")
    ignp.add_argument("controller")

    verp = sub.add_parser("version", parents=[waitp],
                           help="Get or set the controller's manually-tracked code version.")
    verp.add_argument("controller")
    verp.add_argument("n", nargs="?", type=int, help="Omit to just report the current version.")
    verp.add_argument("--bump", action="store_true", help="Increment the current version by 1.")

    azp = sub.add_parser("addzone", parents=[waitp],
                          help="Add a mining zone. The fleet balances turtles evenly across every zone "
                               "with room, not fill-one-then-overflow. Chest locations are shared across "
                               "all zones -- see addchest/removechest/chests.")
    azp.add_argument("controller")
    azp.add_argument("minX", type=int)
    azp.add_argument("minZ", type=int)
    azp.add_argument("maxX", type=int)
    azp.add_argument("maxZ", type=int)
    azp.add_argument("y", type=int, help="Height to start mining passes from.")
    azp.add_argument("capacity", type=int,
                      help="How many non-overlapping cells to divide the zone into (one per turtle).")
    azp.add_argument("height", nargs="?", type=int,
                      help="Caps how many blocks a pass descends before stopping on its own -- targets a "
                           "specific Y-band (e.g. y=174, height=81 covers down to y=93) instead of digging "
                           "to bedrock. Omit to dig to bedrock, as before.")
    azp.add_argument("--name", help="Optional label (e.g. \"diamonds\") -- shown in `zones`, and usable in "
                                     "place of a numeric index for `removezone`. Must be unique.")

    rzp = sub.add_parser("removezone", parents=[waitp],
                          help="Remove a zone by its index or name (see `zones`).")
    rzp.add_argument("controller")
    rzp.add_argument("index", help="A zone's numeric index or its --name, if it has one.")

    zp = sub.add_parser("zones", parents=[waitp], help="List every configured mining zone.")
    zp.add_argument("controller")

    acp = sub.add_parser("addchest", parents=[waitp],
                          help="Add a chest location (or range) a full turtle can unload/refuel at. "
                               "Multiple chests may be added -- the nearest one to a given turtle is "
                               "used automatically.")
    acp.add_argument("controller")
    acp.add_argument("x", type=int)
    acp.add_argument("y", type=int)
    acp.add_argument("z", type=int)
    acp.add_argument("maxX", nargs="?", type=int,
                      help="Together with maxY/maxZ, makes this chest a range instead of an exact point -- "
                           "a chest may be found anywhere within (x,y,z)-(maxX,maxY,maxZ). Omit all three "
                           "for an exact point.")
    acp.add_argument("maxY", nargs="?", type=int)
    acp.add_argument("maxZ", nargs="?", type=int)

    rcp = sub.add_parser("removechest", parents=[waitp], help="Remove a configured chest by its index (see `chests`).")
    rcp.add_argument("controller")
    rcp.add_argument("index", type=int)

    cp = sub.add_parser("chests", parents=[waitp], help="List every configured chest location/range.")
    cp.add_argument("controller")

    ghp = sub.add_parser("gpshost", parents=[waitp],
                          help="Get or set this controller's own GPS anchor position "
                               "(it doubles as one of the >=4 GPS anchors alongside its other duties).")
    ghp.add_argument("controller")
    ghp.add_argument("x", nargs="?", type=int, help="Omit all of x/y/z to just view the current position.")
    ghp.add_argument("y", nargs="?", type=int)
    ghp.add_argument("z", nargs="?", type=int)

    gp = sub.add_parser("goto", parents=[waitp], help="Move to (x, y, z) as a background job.")
    gp.add_argument("controller")
    gp.add_argument("turtle")
    gp.add_argument("x", type=int)
    gp.add_argument("y", type=int)
    gp.add_argument("z", type=int)
    gp.add_argument("--tolerance", type=int, default=0)
    gp.add_argument("--dig", nargs="?", const="safe", choices=["safe", "all"], default=None,
                     help="Dig/attack through obstacles. Bare --dig (or --dig safe) never "
                          "digs a chest or ComputerCraft block (turtle, computer, modem, "
                          "etc), routing around it instead; --dig all digs through either "
                          "too, as a deliberate opt-in.")

    mp = sub.add_parser("mine", parents=[waitp], help="Start the vertical strip miner.")
    mp.add_argument("controller")
    mp.add_argument("turtle")
    mp.add_argument("--width-facing", choices=["north", "east", "south", "west"],
                     help="Direction the mine advances in over time, as it starts new width positions (default north).")
    mp.add_argument("--length-facing", choices=["north", "east", "south", "west", "all"],
                     help="Direction each leg digs into -- must be perpendicular to --width-facing. "
                          "\"all\" digs both perpendicular directions per width position (doubles leg coverage). "
                          "Default: auto-picked perpendicular to --width-facing.")
    mp.add_argument("--length", type=int, help="Blocks per forward/backward leg (default 10).")
    mp.add_argument("--step-down", type=int,
                     help="Blocks descended per leg step within a pass (default 5 with --observant, 2 without).")
    mp.add_argument("--height", type=int,
                     help="Cap blocks descended per pass before resetting, instead of digging to bedrock (default: no cap).")
    mp.add_argument("--width", type=int, help="Cap how many width positions to do (default: unlimited).")
    mp.add_argument("--min-fuel", type=int, help="Stop before a new pass below this fuel (default 500).")
    mp.add_argument("--column-step", type=int, help="Blocks each new width position advances along --width-facing (default 1).")
    mp.add_argument("--column-dy", type=int,
                     help="Start-height shift per new width position; alternates sign each time "
                          "(default 2 with --observant, 1 without).")
    mp.add_argument("--tidy", action=argparse.BooleanOptionalAction, default=None,
                     help="Auto-unload into a chest when full, instead of just stopping (default true).")
    mp.add_argument("--observant", action=argparse.BooleanOptionalAction, default=None,
                     help="Peek left/right on every leg step and every step-down block; also changes "
                          "step-down/column-dy's own defaults (default true).")
    mp.add_argument("--thorough", action=argparse.BooleanOptionalAction, default=None,
                     help="Chase veins of anything spotted -- up/down always, left/right only if "
                          "observant is on -- works even with observant off (default true).")

    stp = sub.add_parser("stop", parents=[waitp], help="Stop the running job (back to idle).")
    stp.add_argument("controller")
    stp.add_argument("turtle")

    jsp = sub.add_parser("jobstatus", parents=[waitp], help="What job is running / queued.")
    jsp.add_argument("controller")
    jsp.add_argument("turtle")

    pp = sub.add_parser("pos", parents=[waitp], help="Report position and surroundings.")
    pp.add_argument("controller")
    pp.add_argument("turtle")
    pp.add_argument("--full", action="store_true",
                     help="Spin to survey all 6 surrounding blocks (north/east/south/west/up/down), not just front/up/down.")

    spp = sub.add_parser("setpos", parents=[waitp],
                          help="Manually calibrate the tracked position/heading (e.g. after an F3 check).")
    spp.add_argument("controller")
    spp.add_argument("turtle")
    spp.add_argument("x", type=int)
    spp.add_argument("y", type=int)
    spp.add_argument("z", type=int)
    spp.add_argument("facing", help="Heading 0-3, or a compass name (north/east/south/west).")

    gfp = sub.add_parser("gpsfix", parents=[waitp],
                          help="Try to acquire a real GPS fix (needs a GPS network -- see the gpshost shortcut).")
    gfp.add_argument("controller")
    gfp.add_argument("turtle")

    tlp = sub.add_parser("turnleft", parents=[waitp], help="Turn left 90 degrees.")
    tlp.add_argument("controller")
    tlp.add_argument("turtle")

    trp = sub.add_parser("turnright", parents=[waitp], help="Turn right 90 degrees.")
    trp.add_argument("controller")
    trp.add_argument("turtle")

    ip = sub.add_parser("inv", parents=[waitp], help="Report inventory contents.")
    ip.add_argument("controller")
    ip.add_argument("turtle")

    hp = sub.add_parser("home", parents=[waitp], help="Go to the marked home position.")
    hp.add_argument("controller")
    hp.add_argument("turtle")
    hp.add_argument("--dig", nargs="?", const="safe", choices=["safe", "all"], default=None,
                     help="Dig/attack through obstacles. Bare --dig (or --dig safe) never "
                          "digs a chest or ComputerCraft block (turtle, computer, modem, "
                          "etc), routing around it instead; --dig all digs through either "
                          "too, as a deliberate opt-in.")

    mhp = sub.add_parser("markhome", parents=[waitp], help="Mark the current position as home.")
    mhp.add_argument("controller")
    mhp.add_argument("turtle")

    fcp = sub.add_parser("findchest", parents=[waitp], help="Search for a nearby chest.")
    fcp.add_argument("controller")
    fcp.add_argument("turtle")
    fcp.add_argument("--x", type=int, help="Search center (default: home position).")
    fcp.add_argument("--y", type=int)
    fcp.add_argument("--z", type=int)
    fcp.add_argument("--radius", type=int, default=8)

    dp = sub.add_parser("dump", parents=[waitp], help="Find a chest and empty the inventory into it.")
    dp.add_argument("controller")
    dp.add_argument("turtle")
    dp.add_argument("--x", type=int, help="Chest location, if known (default: search near the turtle).")
    dp.add_argument("--y", type=int)
    dp.add_argument("--z", type=int)
    dp.add_argument("--radius", type=int,
                     help="Search radius. Default: 8 around the turtle if no --x/--y/--z given, "
                          "0 (exact) if they are -- an explicit --radius with coordinates searches "
                          "that far around them instead of requiring an exact match.")

    args = p.parse_args()
    if not args.token:
        print("error: set RELAY_TOKEN or pass --token", file=sys.stderr)
        sys.exit(1)
    url = args.url.rstrip("/")

    if args.cmd == "list":
        status = request(f"{url}/status", args.token)
        if not status:
            print("no controllers have checked in yet")
        for tid, info in sorted(status.items(), key=lambda kv: kv[0]):
            label = info.get("label") or "(unlabeled)"
            print(f"{tid:>6}  {label:<20} last seen {info['seconds_ago']}s ago  pending={info['pending']}")

    elif args.cmd == "send":
        command = " ".join(args.command)
        wrapped = proxy_wrap(args.turtle, command)
        res = request(f"{url}/cmd?id={args.controller}", args.token, "POST", {"command": wrapped})
        print(f"queued {res['cmd_id']} on controller {args.controller} -> turtle {args.turtle}: {command}")

    elif args.cmd == "send-fleet":
        command = " ".join(args.command)
        wrapped = f'return dofile("/dom-main/controller/roster.lua").proxyAll({lua_string(command)})'
        res = request(f"{url}/cmd?id={args.controller}", args.token, "POST", {"command": wrapped})
        print(f"queued {res['cmd_id']} on controller {args.controller} (fleet-wide): {command}")

    elif args.cmd == "results":
        results = request(f"{url}/results?id={args.controller}", args.token)
        for r in results[-args.n:]:
            print_result(r)

    elif args.cmd == "watch":
        seen = 0
        print(f"watching controller {args.controller} (ctrl-c to stop)")
        try:
            while True:
                results = request(f"{url}/results?id={args.controller}", args.token)
                for r in results[seen:]:
                    print_result(r)
                seen = len(results)
                time.sleep(2)
        except KeyboardInterrupt:
            pass

    elif args.cmd == "clearqueue":
        res = request(f"{url}/clear_queue?id={args.controller}", args.token, "POST", {})
        print(f"cleared {res['cleared']} queued command(s) for controller {args.controller}")

    elif args.cmd == "worldexport":
        cmd_worldexport(url, args)

    elif args.cmd == "worldwatch":
        cmd_worldwatch(url, args)

    elif args.cmd == "console":
        stop = threading.Event()
        cursor = [0]
        HEARTBEAT_INTERVAL = 10  # seconds between mode.lua connect() heartbeats

        # A turtle's own screen is only 39 columns wide, so CraftOS's
        # print() word-wraps anything longer than that INTO the log
        # stream as genuine embedded newlines, sized to the TURTLE's
        # screen -- not this console's. dom-main/controller/roster.lua
        # tags every resulting physical line with its sender's "[Name] "
        # prefix (see that file's own comment), but each one still
        # arrives as its own separate printed line here, wrapped at a
        # width that has nothing to do with this terminal.
        #
        # This reassembles every sender's wrapped physical lines back
        # into the one logical line CraftOS originally wrapped, before
        # ever writing anything out -- so what reaches this console is
        # always one real print() call per line, left free to soft-wrap
        # (or not) at THIS terminal's own width like any normal text.
        # KNOWN_MESSAGE_PREFIXES is this repo's actual, closed set of
        # message-type prefixes (every print() in dom-main/ and lib/
        # uses exactly one of these) -- a physical line from a sender
        # that's mid-accumulation and does NOT start with one of these
        # is a wrap continuation, not a new message, and gets glued
        # directly onto what's already accumulated (no separator needed:
        # CraftOS's own wrap already left any necessary space in place,
        # same as this example's trailing space before the wrap point:
        # "vertical: spotted minecraft:stone to " + "the left"). A line
        # with no "[Name] " prefix at all is the controller's own local
        # output (scheduler:, fleet_listener:, command echoes, etc.) and
        # is accumulated under sender=None by the same rules. Controller
        # lines flush every turtle sender first, so an interleaved local
        # line can never get glued onto some turtle's still-open one.
        #
        # --silent additionally drops a fully-reassembled line if it's:
        #   - dom-main/mining/vertical.lua's routine "spotted <block>
        #     <direction>" call-out, valuable or not. The useful signal
        #     is the one-line "chased a <block> vein" summary instead.
        #   - a lib/pathfind.lua "heading to"/"arrived at" line for a
        #     short hop -- mineVein calls M.goto once per block of a
        #     vein it chases, each only a step or two, drowning out
        #     genuinely long trips the same way the "spotted" noise
        #     did. lib/pathfind.lua tags both lines with the ORIGINAL
        #     travel distance as "[dist=N]" specifically so this can be
        #     judged per-line without the console needing to correlate
        #     a heading/arrived pair itself; PATHFIND_SHORT_HOP lets a
        #     genuinely long trip's own heading/arrived pair through.
        #     "stuck"/"interrupted"/"gave up" are never tagged this way
        #     and always print regardless of distance -- a failure is
        #     worth seeing no matter how short the attempted hop was.
        #   - a raw command echo ("> ...") with no sender, since that's
        #     always this console's own submitted command, already shown
        #     via "[queued N] description" the moment it was sent. A
        #     SENDER-prefixed echo ("[Name] > ...") is a turtle's own log
        #     of what it just ran, which is the only visibility into an
        #     autopilot dispatch (see FRIENDLY_DISPATCH_PATTERNS below) --
        #     translated to a human sentence when recognized, dropped
        #     otherwise (an operator's own turtle-targeted command, same
        #     reasoning as the no-sender case).
        # This console's own connect()/disconnect() heartbeat echoes are
        # dropped unconditionally, --silent or not -- see
        # BOOKKEEPING_ECHOES below.
        #
        # /log's text arrives as an arbitrary chunk of a streamed buffer,
        # not one line at a time -- a single poll can split a physical
        # line in the middle. `pending` carries whatever trailing
        # partial line one poll leaves behind so it's completed (and
        # correctly classified as a whole) by the next.
        pending = [""]
        in_progress = {}  # sender -> its not-yet-flushed accumulated line
        LOG_SENDER_RE = re.compile(r"^\[([^\]]+)\] (.*)$")
        PATHFIND_DIST_RE = re.compile(r"^pathfind: (?:heading to|arrived at) .*\[dist=([\d.]+)\]$")
        PATHFIND_SHORT_HOP = 5.0
        KNOWN_MESSAGE_PREFIXES = (
            "vertical:", "pathfind:", "scheduler:", "fleet:", "fleet_listener:", "job:", "> ", "= ",
        )

        # This console's own heartbeat (see send_bookkeeping()/poll_loop()
        # above) round-trips through the controller's exec.lua like any
        # other command, so it echoes "> dofile(...).connect()"/
        # "disconnect()" into the very feed it's meant to be silently
        # keeping alive -- pure bookkeeping noise with no legitimate
        # reason to ever look at it, so this drops it unconditionally,
        # not just under --silent.
        BOOKKEEPING_ECHOES = frozenset({
            '> dofile("/dom-main/controller/mode.lua").connect()',
            '> dofile("/dom-main/controller/mode.lua").disconnect()',
        })
        # lib/nav.lua's M.report() prints "pos:"/"front:"/"up:"/"down:" for
        # a plain report, or "north:"/"east:"/"south:"/"west:"/"up:"/
        # "down:" for `pos --full` -- every one of these needs to be here,
        # or the missing ones get misread as wrap continuations of
        # whatever line came before them and glued straight onto it
        # (confirmed: `pos --full` glued all of pos:/north:/east:/south:/
        # west: into one garbled line before north:/east:/south:/west:
        # were added below).
        COMMAND_OUTPUT_PREFIXES = (
            "pos:", "front:", "up:", "down:", "north:", "east:", "south:", "west:",
            "inventory:", "slot ", "{", "}", "= ",
        )
        # lib/inventory.lua's M.report() ends with a bare "N/16 slots
        # empty" summary line that -- unlike every other line it prints --
        # has no stable prefix to match, so it needs its own pattern
        # rather than a COMMAND_OUTPUT_PREFIXES entry (same bug as the
        # missing north:/east:/south:/west: above: without this it reads
        # as a wrap continuation and gets glued onto the last "slot N:
        # ..." line).
        SLOTS_SUMMARY_RE = re.compile(r"^\d+/\d+ slots empty$")

        # Recognizes dom-main/controller/scheduler.lua's own fixed command
        # templates (autopilot dispatches to a turtle -- assignWork/
        # attemptRescue/dispatchToChest/refuelFromInventory) by a snippet
        # unique to each, and gives --silent a human sentence to show
        # instead of either the raw generated Lua or nothing at all. This
        # is what a scheduler dispatch to a turtle looks like on the wire
        # -- there's no separate structured "the autopilot did X" event to
        # read instead, so matching the command text is the only way to
        # tell it apart from an operator's own turtle-targeted command
        # (which the console already announced via "[queued N]
        # description (turtle X)" the moment it was submitted -- see
        # is_noisy_content's "> " handling in emit() below for why THOSE
        # stay dropped, not translated). If a scheduler command's own
        # template ever changes, update the matching pattern here too.
        FRIENDLY_DISPATCH_PATTERNS = (
            (lambda cmd: "job.loadCheckpoint()" in cmd, "Controller started a mining job on {turtle}"),
            (lambda cmd: cmd.startswith('return dofile("/lib/rescue.lua").perform('),
             "Controller sent {turtle} to rescue a stranded turtle"),
            (lambda cmd: cmd.startswith('local chestfinder = dofile("/lib/chestfinder.lua")'),
             "Controller sent {turtle} to refuel at the chest"),
            (lambda cmd: cmd.startswith('local ok, reason = dofile("/lib/fuel.lua").ensureFuel('),
             "Controller told {turtle} to refuel"),
        )

        def friendly_dispatch(turtle, inner_command):
            for matches, template in FRIENDLY_DISPATCH_PATTERNS:
                if matches(inner_command):
                    return template.format(turtle=turtle)
            return None

        def is_noisy_content(content):
            if content.startswith("vertical: spotted "):
                return True
            m = PATHFIND_DIST_RE.match(content)
            if m and float(m.group(1)) <= PATHFIND_SHORT_HOP:
                return True
            return False

        def is_wrap_continuation(content):
            if content.startswith((" ", "\t")):
                return False
            if SLOTS_SUMMARY_RE.match(content):
                return False
            return not content.startswith(KNOWN_MESSAGE_PREFIXES + COMMAND_OUTPUT_PREFIXES)

        def emit(sender, content):
            if content in BOOKKEEPING_ECHOES:
                return
            if args.silent and content.startswith("> "):
                # A bare (no sender) echo is always this console's own
                # submitted command, round-tripped through the
                # controller's exec.lua -- already announced via
                # "[queued N] description" the moment it was sent, so the
                # raw Lua adds nothing. A sender-prefixed echo is a
                # TURTLE's own log of the command it just ran, which is
                # the only place an autopilot dispatch (never announced by
                # this console -- it wasn't typed here) is visible at all;
                # translate the recognizable ones, drop the rest (an
                # operator's own turtle-targeted command, already
                # announced the same way as the bare case).
                if sender is None:
                    return
                friendly = friendly_dispatch(sender, content[2:])
                if friendly is None:
                    return
                sys.stdout.write(friendly + "\n")
                return
            if args.silent and is_noisy_content(content):
                return
            prefix = f"[{sender}] " if sender is not None else ""
            sys.stdout.write(prefix + content + "\n")

        def flush(sender):
            if sender in in_progress:
                emit(sender, in_progress.pop(sender))

        def flush_all():
            for sender in list(in_progress.keys()):
                flush(sender)

        def flush_others(current_sender):
            for sender in list(in_progress.keys()):
                if sender != current_sender:
                    flush(sender)

        def process_line(line):
            m = LOG_SENDER_RE.match(line)
            if m:
                sender, content = m.group(1), m.group(2)
            else:
                sender, content = None, line
                flush_others(sender)

            if sender in in_progress and is_wrap_continuation(content):
                in_progress[sender] += content
                return
            flush(sender)
            in_progress[sender] = content

        def filtered_write(text):
            pending[0] += text
            lines = pending[0].split("\n")
            pending[0] = lines.pop()  # last element: not yet newline-terminated
            for line in lines:
                process_line(line)

        def send_bookkeeping(command, tag=None):
            """Fire-and-forget: a missed connect/disconnect heartbeat just
            gets retried on the next tick (or never matters again, for a
            disconnect), so failures here are silently swallowed rather
            than interrupting the console session the way request()'s
            sys.exit(1) would.

            `tag` (see relay.py's own /cmd doc): both call sites below pass
            "heartbeat", so a controller that's slow or stuck to poll never
            accumulates more than the ONE most recent connect()/disconnect()
            behind it -- confirmed live, without this a controller stuck for
            hours accumulated one queued heartbeat per tick indefinitely,
            eventually burying every real command behind well over a
            thousand of them."""
            try:
                body = {"command": command}
                if tag:
                    body["tag"] = tag
                req = urllib.request.Request(
                    f"{url}/cmd?id={args.controller}",
                    data=json.dumps(body).encode("utf-8"),
                    method="POST",
                )
                req.add_header("Authorization", f"Bearer {args.token}")
                req.add_header("Content-Type", "application/json")
                with urllib.request.urlopen(req, timeout=10):
                    pass
            except Exception:
                pass

        def poll_loop():
            last_err = None
            # Starts at "now", not 0 -- the explicit connect() just below
            # (before this thread starts) already covers session start;
            # starting at 0 would make this loop's first iteration send
            # an immediate, redundant duplicate.
            last_heartbeat = time.time()
            while not stop.is_set():
                try:
                    req = urllib.request.Request(f"{url}/log?id={args.controller}&after={cursor[0]}")
                    req.add_header("Authorization", f"Bearer {args.token}")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        res = json.loads(resp.read().decode("utf-8"))
                    text = res.get("text", "")
                    if text:
                        filtered_write(text)
                        sys.stdout.flush()
                    cursor[0] = res.get("cursor", cursor[0])
                    if last_err:
                        print("\n[console: reconnected]", file=sys.stderr)
                        last_err = None
                except Exception as e:
                    if str(e) != last_err:
                        print(f"\n[console: poll error: {e}]", file=sys.stderr)
                        last_err = str(e)

                # dom-main/controller/mode.lua's connect() call is
                # idempotent, so this one call serves as both the initial
                # "an operator is here" signal and the ongoing heartbeat
                # that keeps passive mode deferring to them -- see its
                # own header comment for why this isn't persisted state.
                now = time.time()
                if now - last_heartbeat >= HEARTBEAT_INTERVAL:
                    send_bookkeeping('dofile("/dom-main/controller/mode.lua").connect()', tag="heartbeat")
                    last_heartbeat = now

                stop.wait(1)

        send_bookkeeping('dofile("/dom-main/controller/mode.lua").connect()', tag="heartbeat")

        poller = threading.Thread(target=poll_loop, daemon=True)
        poller.start()

        console_parser = build_console_parser()

        print(f"live console for controller {args.controller} -- type a command and press "
              "enter to send it (type `help` to list shortcuts like `goto <turtle> x y z "
              "--dig`; anything else is sent as raw Lua, run on the controller); ctrl-d or "
              "ctrl-c to stop")
        try:
            while True:
                try:
                    line = input().strip()
                except EOFError:
                    break
                if not line:
                    continue

                first_word = line.split(None, 1)[0]
                if first_word in ("help", "?"):
                    print(CONSOLE_HELP)
                    continue

                if first_word in SHORTCUT_NAMES:
                    try:
                        tokens = shlex.split(line)
                    except ValueError as e:
                        print(f"[error parsing command: {e}]", file=sys.stderr)
                        continue
                    try:
                        ns = console_parser.parse_args(tokens)
                    except ConsoleArgError as e:
                        print(f"[{e}]", file=sys.stderr)
                        continue
                    description, inner = build_shortcut(ns.cmd, ns)
                    turtle_name = getattr(ns, "turtle", None)
                    if turtle_name:
                        command = proxy_wrap(turtle_name, inner)
                        description = f"{description} (turtle {turtle_name})"
                    else:
                        command = inner
                else:
                    description, command = None, line

                try:
                    req = urllib.request.Request(
                        f"{url}/cmd?id={args.controller}",
                        data=json.dumps({"command": command}).encode("utf-8"),
                        method="POST",
                    )
                    req.add_header("Authorization", f"Bearer {args.token}")
                    req.add_header("Content-Type", "application/json")
                    with urllib.request.urlopen(req, timeout=10) as resp:
                        res = json.loads(resp.read().decode("utf-8"))
                    if description:
                        print(f"[queued {res['cmd_id']}] {description}")
                    else:
                        print(f"[queued {res['cmd_id']}]")
                except Exception as e:
                    print(f"[error queuing command: {e}]", file=sys.stderr)
        except KeyboardInterrupt:
            pass
        finally:
            stop.set()
            flush_all()  # don't lose a still-accumulating wrapped line at session end
            sys.stdout.flush()
            send_bookkeeping('dofile("/dom-main/controller/mode.lua").disconnect()', tag="heartbeat")

    elif args.cmd in SHORTCUT_NAMES:
        description, inner = build_shortcut(args.cmd, args)
        turtle_name = getattr(args, "turtle", None)
        if turtle_name:
            command = proxy_wrap(turtle_name, inner)
            description = f"{description} (turtle {turtle_name})"
        else:
            command = inner
        queue(url, args, description, command)


if __name__ == "__main__":
    main()

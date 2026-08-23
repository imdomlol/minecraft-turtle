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
  turtlectl.py console <controller>   -- live screen feed; type a command + enter to send it
  turtlectl.py roster <controller>    -- every turtle this controller currently knows about
  turtlectl.py worldblock <controller> <x> <y> <z>  -- block recorded at that coordinate, or None
  turtlectl.py whoami <controller> [turtle]  -- basic info about the controller, or a turtle if named
  turtlectl.py mode <controller> [idle|passive|aggressive]  -- get or set the autopilot mode
  turtlectl.py version <controller> [N] [--bump]  -- get or set the controller's code version
  turtlectl.py worksite <controller> [minX minZ maxX maxZ y chestX chestY chestZ capacity]
                         -- get (no args) or set the current mining worksite

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

Reads RELAY_URL and RELAY_TOKEN from the environment; --url/--token override.
"""
import argparse
import json
import os
import shlex
import sys
import threading
import time
import urllib.error
import urllib.request

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

    if cmd == "version":
        if getattr(ns, "bump", False):
            return "bump version", 'return dofile("/dom-main/controller/version.lua").bump()'
        if getattr(ns, "n", None) is not None:
            return f"set version to {ns.n}", f'return dofile("/dom-main/controller/version.lua").set({ns.n})'
        return "current version", 'return dofile("/dom-main/controller/version.lua").get()'

    if cmd == "worksite":
        fields = [ns.minX, ns.minZ, ns.maxX, ns.maxZ, ns.y, ns.chestX, ns.chestY, ns.chestZ, ns.capacity]
        if all(f is None for f in fields):
            return "current worksite", 'return dofile("/dom-main/controller/worksite.lua").get()'
        if any(f is None for f in fields):
            print("error: worksite needs all of minX minZ maxX maxZ y chestX chestY chestZ capacity, "
                  "or none of them (to just view it)", file=sys.stderr)
            sys.exit(1)
        args_str = ", ".join(str(f) for f in fields)
        command = f'return dofile("/dom-main/controller/worksite.lua").set({args_str})'
        description = (f"set worksite ({ns.minX},{ns.minZ})-({ns.maxX},{ns.maxZ}) y={ns.y} "
                        f"chest=({ns.chestX},{ns.chestY},{ns.chestZ}) capacity={ns.capacity}")
        return description, command

    raise ValueError(f"unknown shortcut: {cmd}")


TURTLE_SHORTCUTS = {
    "goto", "mine", "stop", "jobstatus", "pos", "setpos", "turnleft", "turnright",
    "inv", "home", "markhome", "findchest", "dump",
}
CONTROLLER_SHORTCUTS = {"roster", "worldblock", "mode", "version", "worksite"}
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

    verp = sub.add_parser("version", add_help=False)
    verp.add_argument("n", nargs="?", type=int)
    verp.add_argument("--bump", action="store_true")

    wsp = sub.add_parser("worksite", add_help=False)
    for name in ("minX", "minZ", "maxX", "maxZ", "y", "chestX", "chestY", "chestZ", "capacity"):
        wsp.add_argument(name, nargs="?", type=int)

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
  worksite [minX minZ maxX maxZ y chestX chestY chestZ capacity]
                                                get (no args) or set the current mining worksite
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
    p.add_argument("--url", default=os.environ.get("RELAY_URL", "http://localhost:8787"))
    p.add_argument("--token", default=os.environ.get("RELAY_TOKEN"))
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

    cp = sub.add_parser("console", help="Live console for a controller.")
    cp.add_argument("controller")

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

    verp = sub.add_parser("version", parents=[waitp],
                           help="Get or set the controller's manually-tracked code version.")
    verp.add_argument("controller")
    verp.add_argument("n", nargs="?", type=int, help="Omit to just report the current version.")
    verp.add_argument("--bump", action="store_true", help="Increment the current version by 1.")

    wsp = sub.add_parser("worksite", parents=[waitp],
                          help="Get or set the current mining worksite (bounds + chest location).")
    wsp.add_argument("controller")
    wsp.add_argument("minX", nargs="?", type=int, help="Omit all 9 of minX..capacity to just view the current worksite.")
    wsp.add_argument("minZ", nargs="?", type=int)
    wsp.add_argument("maxX", nargs="?", type=int)
    wsp.add_argument("maxZ", nargs="?", type=int)
    wsp.add_argument("y", nargs="?", type=int, help="Height to start mining passes from.")
    wsp.add_argument("chestX", nargs="?", type=int, help="Where a full turtle should go to unload.")
    wsp.add_argument("chestY", nargs="?", type=int)
    wsp.add_argument("chestZ", nargs="?", type=int)
    wsp.add_argument("capacity", nargs="?", type=int,
                      help="How many non-overlapping cells to divide the site into (one per turtle).")

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

    elif args.cmd == "console":
        stop = threading.Event()
        cursor = [0]
        HEARTBEAT_INTERVAL = 10  # seconds between mode.lua connect() heartbeats

        def send_bookkeeping(command):
            """Fire-and-forget: a missed connect/disconnect heartbeat just
            gets retried on the next tick (or never matters again, for a
            disconnect), so failures here are silently swallowed rather
            than interrupting the console session the way request()'s
            sys.exit(1) would."""
            try:
                req = urllib.request.Request(
                    f"{url}/cmd?id={args.controller}",
                    data=json.dumps({"command": command}).encode("utf-8"),
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
                        sys.stdout.write(text)
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
                    send_bookkeeping('dofile("/dom-main/controller/mode.lua").connect()')
                    last_heartbeat = now

                stop.wait(1)

        send_bookkeeping('dofile("/dom-main/controller/mode.lua").connect()')

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
            send_bookkeeping('dofile("/dom-main/controller/mode.lua").disconnect()')

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

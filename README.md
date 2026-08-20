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

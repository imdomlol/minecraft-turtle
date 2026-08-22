--[[----------------------------------------------------------------------
  lib/ores.lua -- explicit valuable-block overrides for
  dom-main/mining/vertical.lua's `thorough` mode.

  vertical.lua's isValuable() already treats anything with "_ore"
  anywhere in its name as worth chasing (plus "ancient_debris", which
  doesn't follow that convention) -- that alone covers the vast majority
  of vanilla and modded ores without needing a list here. This file is
  only for exceptions: names that don't contain "_ore" at all, or
  matches you'd rather never chase.

  Edit the two lists below and redeploy -- no code changes needed.
  Both use plain substring matching against the block's full registry
  name (e.g. "modid:block_name"), not exact-match and not Lua pattern
  syntax -- a short, distinctive fragment of the name is enough, and
  characters like "." or "-" are matched literally.

  EXCLUDE is checked first, so it always wins over both the "_ore" match
  and INCLUDE below -- add a name here if thorough is chasing something
  that isn't actually worth mining (e.g. a purely decorative block that
  happens to have "_ore" in its name).

  INCLUDE is checked after the "_ore" match -- add a name here if
  thorough is skipping over something you want chased that doesn't
  follow the "_ore" naming convention at all.
------------------------------------------------------------------------]]

return {
  INCLUDE = {
    -- "silentgear:blasting_ore",
  },

  EXCLUDE = {
    -- "somemod:decorative_ore_block",
  },
}

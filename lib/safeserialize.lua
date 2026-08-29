--[[----------------------------------------------------------------------
  lib/safeserialize.lua -- shared helper for every hot-path
  textutils.serializeJSON write across this codebase (lib/job.lua's
  checkpoint, lib/homelink.lua's state/blackbox, dom-main/controller/
  roster.lua's and dom-main/controller/worksite.lua's own saves, ...).

  CC:Tweaked's textutils.serializeJSON refuses to encode a table that's
  reachable via more than one path in the same structure ("Cannot
  serialize table with repeated entries"). Tonight this crashed several
  different call sites, each time because some ordinary piece of Lua code
  happened to store the SAME table object under two different keys (a
  resumed job's params.__resume sharing its columnStart table with the
  fresh checkpoint that also needed it, among others). Each individual
  case got found and patched as it came up, but the underlying HAZARD --
  any future code, anywhere, that shares one table reference two ways
  hits the exact same crash -- was never actually eliminated, which is
  exactly why it kept recurring across turtle after turtle instead of
  staying fixed. M.encode() below removes the hazard at its root instead
  of chasing individual instances of it: deep-copy the whole structure
  first, so the result NEVER has two paths to the same table object,
  regardless of what reference-sharing the input happened to contain.
------------------------------------------------------------------------]]

if _G.__SAFESERIALIZE_MODULE then return _G.__SAFESERIALIZE_MODULE end

local M = {}

-- `ancestors` only tracks the CURRENT root-to-here chain, via a
-- metatable-chained lookup (cheap -- no copying at each level), not
-- every table ever visited anywhere in the structure -- the same source
-- table reachable from two SIBLING branches (the common, legitimate case
-- behind every "repeated entries" crash so far, e.g. one shared
-- columnStart table embedded under two different keys) correctly gets
-- an independent copy at each occurrence, which is exactly what's
-- needed here. Only a genuine CYCLE (a table that is its own ancestor)
-- is caught and replaced with a placeholder string -- nothing in this
-- codebase's own data is meant to self-reference, and recursing into
-- one forever would hang the caller instead of just failing to log
-- something.
local function deepCopy(value, ancestors)
  if type(value) ~= "table" then return value end
  if ancestors[value] then return "<cycle>" end
  local nextAncestors = setmetatable({ [value] = true }, { __index = ancestors })
  local copy = {}
  for k, v in pairs(value) do
    copy[deepCopy(k, nextAncestors)] = deepCopy(v, nextAncestors)
  end
  return copy
end

-- Encodes `value` as JSON, guaranteed never to fail with "repeated
-- entries" regardless of what reference-sharing the input contains (see
-- deepCopy() above) -- still pcall-guarded on top of that, since this is
-- a hot-path logging/checkpoint helper and ANY encoding failure (this
-- one or a genuinely different one) must degrade to "didn't get
-- persisted this time", never crash the caller. Returns ok,
-- encodedOrError, matching pcall's own shape -- callers already written
-- against plain pcall(textutils.serializeJSON, ...) can drop this in
-- unchanged.
function M.encode(value)
  local ok, safeValue = pcall(deepCopy, value, {})
  if not ok then return false, safeValue end
  return pcall(textutils.serializeJSON, safeValue)
end

_G.__SAFESERIALIZE_MODULE = M
return M

-- Builds a sandbox environment for Sandbox.init. Runs on every runtime
-- zilua supports, so it only uses what Lua 5.1 and Luau have in common.
-- Argument: Sandbox.Options as a table.
local options = ...

local function copy(lib)
  local result = {}
  for name, value in pairs(lib) do
    result[name] = value
  end
  return result
end

local env = {}

-- Functions that cannot reach outside the environment. Missing ones (such as
-- unpack after 5.1, or typeof outside Luau) are simply skipped.
for _, name in ipairs({
  "assert", "error", "ipairs", "next", "pairs", "pcall", "select",
  "tonumber", "tostring", "type", "typeof", "unpack", "xpcall",
  "rawequal", "rawget", "rawlen", "setmetatable",
}) do
  env[name] = _G[name]
end
env._VERSION = _VERSION

-- Metatables of strings and userdata are shared with the host (and with
-- other sandboxes), so only table metatables are visible.
env.getmetatable = function(value)
  if type(value) == "table" then
    return getmetatable(value)
  end
  return nil
end

if options.string and string then
  env.string = copy(string)
  env.string.dump = nil
end
if options.table and table then env.table = copy(table) end
if options.math and math then env.math = copy(math) end
if options.coroutine and coroutine then env.coroutine = copy(coroutine) end
if options.utf8 and utf8 then env.utf8 = copy(utf8) end
if options.bit then
  if bit32 then env.bit32 = copy(bit32) end
  if bit then env.bit = copy(bit) end
end
if options.os_time and os then
  env.os = { time = os.time, clock = os.clock, difftime = os.difftime }
end

env._G = env
return env

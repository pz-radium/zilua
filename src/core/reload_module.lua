-- State.reloadModule: require a module again and move its new contents into
-- the table that is already loaded, so references to it see the new code.
-- Argument: the module name.
local name = ...

if type(package) ~= "table" or type(require) ~= "function" then
  error("reloadModule needs require and the package library, which this runtime does not have", 0)
end

local old = package.loaded[name]
package.loaded[name] = nil
local ok, new = pcall(require, name)
if not ok then
  -- Keep the working version.
  package.loaded[name] = old
  error(new, 0)
end

if type(old) == "table" and type(new) == "table" and old ~= new then
  for key, value in pairs(new) do
    old[key] = value
  end
  package.loaded[name] = old
end

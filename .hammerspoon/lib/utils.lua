---@class UtilityModule
local utils = {}

---@class ManagedSpace
---@field ManagedSpaceID integer `hs.spaces` id
---@field id64 integer
---@field type integer
---@field uuid string
---@field display string screen UUID

---@return ManagedSpace[]? spaces `spaces[i]` is Mission Control index `i`
---@return string? errorMessage
function utils.spaces()
  local data, err = hs.spaces.data_managedDisplaySpaces()
  if type(data) ~= "table" then
    return nil, err or "could not read managed Spaces"
  end

  ---@type ManagedSpace[]
  local spaces = {}
  for _, display in ipairs(data) do
    local uuid = display["Display Identifier"]
    if uuid == "Main" then
      uuid = hs.screen.mainScreen():getUUID()
    end
    for _, space in ipairs(display.Spaces or {}) do
      space.display = uuid
      spaces[#spaces + 1] = space
    end
  end

  return spaces
end

---@param value string
---@return string
function utils.quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

-- The source/ABI key in the filename makes dyld load rebuilds as fresh images.
---@param name string
---@return table
function utils.native(name)
  local ok, result = xpcall(function()
    local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
    local source = here .. "/" .. name .. "/" .. name .. ".m"
    local file = assert(io.open(source, "rb"), "missing " .. source)
    local hash = hs.hash.SHA256(file:read("a")):sub(1, 16)
    file:close()
    local info = hs.processInfo
    local cache = string.format("%s/Library/Caches/%s/%s", os.getenv("HOME"), info.bundleID, name)
    local binary =
      string.format("%s/%s-%s-%s.%s-%s.so", cache, name, info.arch, info.version, info.build, hash)
    if not hs.fs.attributes(binary) then
      local frameworks = info.frameworksPath
      local arguments = {
        "clang",
        "-arch",
        info.arch,
        "-O2",
        "-Wall",
        "-Wextra",
        "-Wshadow",
        "-fobjc-arc",
        "-fmodules",
        "-bundle",
        "-undefined",
        "dynamic_lookup",
        "-F" .. frameworks,
        "-I" .. frameworks .. "/LuaSkin.framework/Headers",
        source,
        "-o",
        binary,
      }
      for i, argument in ipairs(arguments) do
        arguments[i] = utils.quote(argument)
      end
      local output, ok = hs.execute(
        string.format("mkdir -p %s && %s 2>&1", utils.quote(cache), table.concat(arguments, " "))
      )
      if not ok then
        error(name .. ": native build failed:\n" .. output, 0)
      elseif output ~= "" then
        print(name .. ": native build warnings:\n" .. output)
      end
      for entry in hs.fs.dir(cache) do
        if entry:match("^" .. name .. "%-.+%.so$") and cache .. "/" .. entry ~= binary then
          os.remove(cache .. "/" .. entry)
        end
      end
    end
    local loader, message = package.loadlib(binary, "luaopen_" .. name)
    return assert(loader, message)()
  end, debug.traceback)
  if not ok then
    require("lib.logger").error(result)
    error(result, 0)
  end
  return result
end

---@return UtilityModule
return utils

---@type string
local path = (hs.processInfo.arch == "arm64" or hs.processInfo.isRosetta)
    and "/opt/homebrew/bin/yabai"
  or "/usr/local/bin/yabai"

---@class YabaiClient
local yabai = {}

---@param args string[]
---@param done fun(ok: boolean, stdout: string, stderr: string)
function yabai.run(args, done)
  local argv = { "-m" }
  for i = 1, #args do
    argv[#argv + 1] = args[i]
  end

  local task = hs.task.new(path, function(code, out, err)
    done(code == 0, out or "", err or "")
  end, argv)

  if not task or task:start() == false then
    done(false, "", "could not start yabai")
  end
end

---@class ManagedSpace
---@field ManagedSpaceID integer native CGS id (`hs.spaces.focusedSpace()`)
---@field id64 integer same id as `ManagedSpaceID` in practice
---@field type integer 0 = user, 4 = fullscreen
---@field uuid string empty for some Spaces (often the first)

---@return ManagedSpace[]? spaces 1-based; `spaces[i]` is Mission Control index `i`
---@return string? errorMessage
local function spaces()
  local data, err = hs.spaces.data_managedDisplaySpaces()
  if type(data) ~= "table" then
    return nil, err or "could not read managed Spaces"
  end

  ---@type ManagedSpace[]
  local result = {}
  for _, display in ipairs(data) do
    for _, space in ipairs(display.Spaces or {}) do
      result[#result + 1] = space
    end
  end

  return result
end
---@return YabaiClient
return yabai

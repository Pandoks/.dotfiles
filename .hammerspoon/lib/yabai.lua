---@type string
local path = (hs.processInfo.arch == "arm64" or hs.processInfo.isRosetta)
    and "/opt/homebrew/bin/yabai"
  or "/usr/local/bin/yabai"

---@class YabaiClient
local yabai = {}

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

---@param args string[]
---@param done fun(ok: boolean, stdout: string, stderr: string)
---@param timeout? number seconds; defaults to 10
function yabai.run(args, done, timeout)
  local argv = { "-m" }
  for i = 1, #args do
    argv[#argv + 1] = args[i]
  end

  local task = hs.task.new(path, nil, argv)
  if not task then
    done(false, "", "could not start yabai")
    return
  end

  local timedOut = false
  local timer = hs.timer.doAfter(timeout or 10, function()
    timedOut = true
    task:terminate()
  end)

  task:setCallback(function(code, out, err)
    timer:stop()
    done(code == 0, out or "", timedOut and "timed out" or (err or ""))
  end)

  if task:start() == false then
    timer:stop()
    done(false, "", "could not start yabai")
  end
end

---@type table<integer, fun(ok: boolean, message?: string)>
local pendingSpaceChanges = {} -- native Space ID -> completion callback

local function spaceChangedHandler()
  local focusedSpaceId = hs.spaces.focusedSpace()
  local callback = pendingSpaceChanges[focusedSpaceId]
  if not callback then
    return
  end
  pendingSpaceChanges[focusedSpaceId] = nil
  callback(true)
end

    end
  end

  return result
end
---@return YabaiClient
return yabai

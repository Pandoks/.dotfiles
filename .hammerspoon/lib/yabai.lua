local utils = require("lib.utils")

---@type string
local path = (hs.processInfo.arch == "arm64" or hs.processInfo.isRosetta)
    and "/opt/homebrew/bin/yabai"
  or "/usr/local/bin/yabai"

---@class YabaiClient
local yabai = {}

---@param ok boolean
---@param stdout? string stdout for `run`, or error message for `switchSpace`
---@param stderr? string stderr for `run`
local function report(ok, stdout, stderr)
  if ok then
    return
  end
  print("yabai error: " .. (stderr or stdout or ""))
end

---@param args string[]
---@param done? fun(ok: boolean, stdout: string, stderr: string)
---@param timeout? number seconds; defaults to 10
function yabai.run(args, done, timeout)
  done = done or report

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
yabai._pendingSpaceChanges = {} -- native Space ID -> completion callback

---@param spaceIndex integer yabai Mission Control index
---@param done? fun(ok: boolean, errorMessage: string?)
---@param timeout? number seconds; defaults to 10
function yabai.switchSpace(spaceIndex, done, timeout)
  done = done or report

  local spaceList, err = utils.spaces()
  if not spaceList then
    done(false, err)
    return
  end
  local space = spaceList[spaceIndex]
  if not space then
    done(false, "space " .. spaceIndex .. " does not exist")
    return
  end
  local spaceID = space.ManagedSpaceID
  if type(spaceID) ~= "number" then
    done(false, "invalid Space id")
    return
  end

  if hs.spaces.focusedSpace() == spaceID then
    done(true)
    return
  elseif yabai._pendingSpaceChanges[spaceID] then
    return
  end

  local timer = hs.timer.doAfter(timeout or 10, function()
    local callback = yabai._pendingSpaceChanges[spaceID]
    if not callback then
      return
    end
    yabai._pendingSpaceChanges[spaceID] = nil
    callback(false, "timed out waiting for Space " .. spaceIndex)
  end)

  yabai._pendingSpaceChanges[spaceID] = function(ok, errorMessage)
    if timer:running() then
      timer:stop()
    end
    done(ok, errorMessage)
  end

  yabai.run({ "space", "--focus", tostring(spaceIndex) }, function(ok, _, stderr)
    if not ok and yabai._pendingSpaceChanges[spaceID] then -- callback hasn't been called yet (timer hasn't timed out
      yabai._pendingSpaceChanges[spaceID] = nil
      timer:stop()
      done(false, stderr)
    end
  end, timeout)
end

yabai.spaceWatcher = hs.spaces.watcher
  .new(function()
    local focusedSpaceId = hs.spaces.focusedSpace()
    local callback = yabai._pendingSpaceChanges[focusedSpaceId]
    if not callback then
      return
    end
    yabai._pendingSpaceChanges[focusedSpaceId] = nil
    callback(true)
  end)
  :start()

---@return YabaiClient
return yabai

-- IMPORTANT: we're using callbacks here so we don't block hs event loop. (makes things really fast)

local isAppleSilicon = hs.processInfo.arch == "arm64" or hs.processInfo.isRosetta
local homebrewPrefix = isAppleSilicon and "/opt/homebrew" or "/usr/local"
local yabaiPath = homebrewPrefix .. "/bin/yabai"

local yabaiClient = {}

---@param args string[]
---@param onExit? fun(success: boolean, stdOut: string, stdErr: string)
---@return hs.task|false
function yabaiClient.run(args, onExit)
  local task = hs.task.new(yabaiPath, function(exitCode, stdOut, stdErr)
    if onExit then
      onExit(exitCode == 0, stdOut, stdErr)
    elseif exitCode ~= 0 then
      print("yabai error: " .. stdErr)
    end
  end, args)

  if not task then
    print("yabai error: could not create task")
    return false
  end

  return task:start()
end

---@param onResult fun(windows: table[]?, error: string?)
function yabaiClient.queryWindows(onResult)
  yabaiClient.run({ "-m", "query", "--windows" }, function(success, stdOut, stdErr)
    if not success then
      onResult(nil, stdErr)
      return
    end

    local decoded, windows = pcall(hs.json.decode, stdOut)
    if not decoded or type(windows) ~= "table" then
      onResult(nil, "could not decode window query")
      return
    end
    onResult(windows)
  end)
end

---@param windowId integer
---@param space integer
---@param onExit? fun(success: boolean, error: string?)
function yabaiClient.moveWindow(windowId, space, onExit)
  yabaiClient.run(
    { "-m", "window", tostring(windowId), "--space", tostring(space) },
    function(success, _, stdErr)
      if onExit then
        onExit(success, success and nil or stdErr)
      end
    end
  )
end

return yabaiClient

---@type string
local path = (hs.processInfo.arch == "arm64" or hs.processInfo.isRosetta)
    and "/opt/homebrew/bin/yabai"
  or "/usr/local/bin/yabai"

---@class YabaiClient
local yabai = {}

---@alias YabaiCallback fun(ok: boolean, stdout: string, stderr: string)
---@param args string[]
---@param done YabaiCallback
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

---@return YabaiClient
return yabai

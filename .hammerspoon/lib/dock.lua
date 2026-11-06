local logger = require("lib.logger")
local utils = require("lib.utils")

local dock = {}

-- Needs SIP's debugging restrictions off; lldb pauses the Dock about 2 s per load.
local binary =
  utils.build("dock", { "-arch", "arm64e", "-dynamiclib", "-undefined", "dynamic_lookup" })
local name = "org.hammerspoon." .. binary:match("[^/]+$")
---@type fun(err?: string)[]
local waiting = {}

local function port()
  local ok, remote = pcall(hs.ipc.remotePort, name)
  return ok and remote or nil
end

local function loaded()
  local remote = port()
  if remote then
    remote:delete()
  end
  return remote ~= nil
end

---@param err? string
local function flush(err)
  local callbacks = waiting
  waiting = {}
  if err and #callbacks == 0 then
    logger.error(err)
  end
  for _, callback in ipairs(callbacks) do
    callback(err)
  end
end

-- No app watcher sees the Dock relaunch, so a move after one loads the helper again.
local function inject()
  local app = hs.application.applicationsForBundleID("com.apple.dock")[1]
  if not app then
    flush("Dock is not running")
    return
  elseif not hs.execute("/usr/sbin/DevToolsSecurity -status"):find("currently enabled") then
    flush("Dock helper needs developer mode: run sudo DevToolsSecurity -enable")
    return
  end
  local command = string.format('expr -l c -- (void *)dlopen("%s", 2)', binary)
  dock.task = hs.task.new("/usr/bin/xcrun", function(_, output, errors)
    dock.task = nil
    flush(not loaded() and "Dock helper did not load:\n" .. errors .. output or nil)
  end, { "lldb", "--batch", "-p", tostring(app:pid()), "-o", command, "-o", "detach" })
  dock.task:start()
end

---@param window integer
---@param space integer
---@param done fun(ok: boolean, err?: string)
function dock.move(window, space, done)
  local function send(err)
    local remote = not err and port()
    if not remote then
      done(false, err or "Dock helper not loaded")
      return
    end
    local sent, response = remote:sendMessage(window .. " " .. space, 0, 0.5)
    remote:delete()
    if not sent or (response and response ~= "") then
      done(false, response)
    else
      done(true)
    end
  end
  if not dock.task and loaded() then
    send()
    return
  end
  waiting[#waiting + 1] = send
  if not dock.task then
    inject()
  end
end

if not loaded() then
  inject()
end

function dock.stop()
  if dock.task then
    dock.task:terminate()
  end
end

return dock

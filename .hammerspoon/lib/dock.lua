local logger = require("lib.logger")
local utils = require("lib.utils")

---@class DockPort
---@field isValid fun(self: DockPort): boolean
---@field send fun(self: DockPort, payload: string, timeout?: number): boolean, string
---@field delete fun(self: DockPort)

---@class DockPortNative
---@field open fun(name: string): DockPort?

local native = utils.native("port") --[[@as DockPortNative]]

local dock = {}

-- Needs SIP's debugging restrictions off; lldb pauses the Dock about 2 s per load.
local binary =
  utils.build("dock", { "-arch", "arm64e", "-dynamiclib", "-undefined", "dynamic_lookup" })
local name = "org.hammerspoon." .. binary:match("[^/]+$")
---@type DockPort?
local remote
---@type { kind: "move"|"switch", callback: fun(err?: string), done: fun(ok: boolean, err?: string), cancelled?: boolean }[]
local waiting = {}

local function disconnect()
  if remote then
    remote:delete()
    remote = nil
  end
end

---@return DockPort?
local function connect()
  if remote and remote:isValid() then
    return remote
  end
  disconnect()
  remote = native.open(name)
  return remote
end

---@param err? string
local function flush(err)
  local entries = waiting
  waiting = {}
  local pending = 0
  for _, entry in ipairs(entries) do
    if not entry.cancelled then
      pending = pending + 1
    end
  end
  if err and pending == 0 then
    logger.error(err)
  end
  for _, entry in ipairs(entries) do
    if not entry.cancelled then
      entry.callback(err)
    end
  end
end

-- No app watcher sees the Dock relaunch, so a request after one loads the helper again.
local function inject()
  local app = hs.application.applicationsForBundleID("com.apple.dock")[1]
  local status = hs.execute("/usr/sbin/DevToolsSecurity -status") --[[@as string]]
  if not app then
    flush("Dock is not running")
    return
  elseif not status:find("currently enabled") then
    flush("Dock helper needs developer mode: run sudo DevToolsSecurity -enable")
    return
  end
  local command = string.format('expr -l c -- (void *)dlopen("%s", 2)', binary)
  dock.task = hs.task.new("/usr/bin/xcrun", function(_, output, errors)
    dock.task = nil
    flush(not connect() and "Dock helper did not load:\n" .. errors .. output or nil)
  end, { "lldb", "--batch", "-p", tostring(app:pid()), "-o", command, "-o", "detach" })
  dock.task:start()
end

---@param kind "move"|"switch"
---@param payload string
---@param done fun(ok: boolean, err?: string)
---@return fun()? cancel
local function request(kind, payload, done)
  local function send(err)
    local port = not err and connect()
    if not port then
      done(false, err or "Dock helper not loaded")
      return
    end
    local sent, response = port:send(payload, 0.5)
    if not sent then
      disconnect()
      done(false, response or "Dock helper unreachable")
    elseif response and response ~= "" then
      done(false, response)
    else
      done(true)
    end
  end
  if not dock.task and connect() then
    send(nil)
    return nil
  end
  if kind == "switch" then
    for _, existing in ipairs(waiting) do
      if existing.kind == "switch" and not existing.cancelled then
        existing.cancelled = true
        existing.done(false, "superseded")
      end
    end
  end
  local entry = { kind = kind, callback = send, done = done }
  waiting[#waiting + 1] = entry
  if not dock.task then
    inject()
  end
  return function()
    entry.cancelled = true
  end
end

---@param window integer
---@param space integer
---@param done fun(ok: boolean, err?: string)
function dock.move(window, space, done)
  request("move", window .. " " .. space, done)
end

---@param space integer
---@param done fun(ok: boolean, err?: string)
---@return fun()? cancel
function dock.switch(space, done)
  return request("switch", "switch " .. space, done)
end

if not connect() then
  inject()
end

function dock.stop()
  if dock.task then
    dock.task:terminate()
  end
  disconnect()
end

return dock

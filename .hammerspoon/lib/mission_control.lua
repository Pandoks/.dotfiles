local logger = require("lib.logger")
local module = {}
local observer, pid, failure
local active, stopped = false, false
local notifications = {
  AXExposeShowAllWindows = true,
  AXExposeShowFrontWindows = true,
  AXExposeShowDesktop = true,
  AXExposeExit = false,
}

local function attach(dock)
  if observer then
    observer:stop()
    observer:callback(nil)
    observer = nil
  end
  active, pid, failure = false, nil, nil
  if not dock then
    return
  end
  local ok, err = pcall(function()
    pid = dock:pid()
    local element = assert(hs.axuielement.applicationElement(dock))
    local current = assert(hs.axuielement.observer.new(pid)) --[[@as hs.axuielement.observer]]
    observer = current
    current:callback(function(_, _, event)
      if not stopped and observer == current then
        active = notifications[event] == true
      end
    end)
    for notification in pairs(notifications) do
      current:addWatcher(element, notification)
    end
    current:start()
    -- Seed once; later reads use Dock notifications.
    local children, message = element:attributeValue("AXChildren")
    assert(type(children) == "table", message or "Dock children unavailable")
    for _, child in ipairs(children) do
      if child:attributeValue("AXIdentifier") == "mc" then
        active = true
        break
      end
    end
  end)
  if not ok then
    if observer then
      observer:stop()
      observer:callback(nil)
      observer = nil
    end
    failure = "Mission Control: " .. tostring(err)
    logger.error(failure)
  end
end

function module.isActive()
  assert(not failure, failure)
  return active
end

module.watcher = hs.application.watcher
  .new(function(_, event, app)
    if stopped or not app then
      return
    end
    if event == hs.application.watcher.terminated and app:pid() == pid then
      attach(nil)
    elseif event == hs.application.watcher.launched and app:bundleID() == "com.apple.dock" then
      attach(app)
    end
  end)
  :start() --[[@as hs.application.watcher]]
attach(hs.application.applicationsForBundleID("com.apple.dock")[1])

function module.stop()
  stopped = true
  module.watcher:stop()
  attach(nil)
end

return module

local logger = require("lib.logger")
local module = {}
module.blacklist = { AXDialog = true, AXSystemDialog = true, AXFloatingWindow = true }

---@class WindowRecord
---@field element hs.axuielement
---@field window? hs.window
---@field id? integer
---@field recent integer
---@field failed? boolean
---@field allowed table<WindowFilter, boolean>
---@field notifications table<string, boolean>

---@class WindowObserver
---@field app hs.application
---@field element? hs.axuielement
---@field observer? hs.axuielement.observer
---@field windows WindowRecord[]
---@field failed? boolean

---@class WindowFilter
---@field failed? boolean
---@field predicate? fun(window: hs.window): boolean?
---@field callbacks table<string, fun(window: hs.window, app: string, event: string, id: integer)[]>
local Filter = {}
Filter.__index = Filter

---@type table<integer, WindowObserver>, table<WindowFilter, boolean>, table<integer, boolean>
local apps, filters, launching = {}, {}, {}
local recent = 0
local order = {}
local applicationWatcher, spaceWatcher, detach
local notifications = {
  AXUIElementDestroyed = "windowDestroyed",
  AXWindowMoved = "windowMoved",
  AXWindowResized = "windowMoved",
  AXTitleChanged = "windowTitleChanged",
  AXWindowMiniaturized = "windowMinimized",
  AXWindowDeminiaturized = "windowUnminimized",
}
local wanted = { AXUIElementDestroyed = true }
for _, event in pairs(notifications) do
  module[event] = event
end
module.windowCreated, module.windowFocused = "windowCreated", "windowFocused"
module.windowHidden, module.windowUnhidden = "windowHidden", "windowUnhidden"

-- The frontmost check from the system, not from the app over Accessibility.
---@param app WindowObserver
local function frontmost(app)
  local front = hs.application.frontmostApplication()
  return front ~= nil and front:pid() == app.app:pid()
end

---@param element hs.axuielement
---@param subrole string?
local function eligible(element, subrole)
  if not module.blacklist[subrole] then
    return true
  end
  if subrole ~= "AXDialog" or element:attributeValue("AXModal") == true then
    return false
  end
  local button = element:attributeValue("AXMinimizeButton")
  return button ~= nil and button:attributeValue("AXEnabled") == true
end

---@param app WindowObserver
---@param message string
local function failure(app, message)
  local pid = app.app:pid()
  -- An app can exit while an Accessibility request is in flight.
  if not app.app:isRunning() then
    detach(pid)
    return
  end
  logger.error("Window tracking (" .. (app.app:name() or "exited app") .. "): " .. message)
end

---@param filter WindowFilter
---@param record WindowRecord
local function matches(filter, record)
  if not record.window or record.failed or filter.failed then
    return false
  end
  local ok, allowed = pcall(function()
    return eligible(record.element, record.window:subrole())
      and (not filter.predicate or filter.predicate(record.window))
  end)
  if not ok then
    filter.failed = true
    logger.error("Window filter: " .. tostring(allowed))
  end
  record.allowed[filter] = ok and allowed == true
  return record.allowed[filter]
end

---@param app WindowObserver
---@param record WindowRecord
---@param event string
local function emit(app, record, event)
  for filter in pairs(filters) do
    local allowed = event == module.windowDestroyed and record.allowed[filter]
      or (event ~= module.windowDestroyed and matches(filter, record))
    if allowed then
      local callbacks, index = filter.callbacks[event] or {}, 1
      while callbacks[index] do
        local ok, err =
          xpcall(callbacks[index], debug.traceback, record.window, app.app:name(), event, record.id)
        if ok then
          index = index + 1
        else
          table.remove(callbacks, index)
          logger.error("Window callback: " .. tostring(err))
        end
      end
    end
  end
end

-- Stops the observer and retires its published windows once.
---@param app WindowObserver
local function retire(app)
  if app.observer then
    app.observer:stop()
    app.observer = nil
  end
  for _, record in ipairs(app.windows) do
    if not record.failed then
      record.failed = true
      emit(app, record, module.windowDestroyed)
    end
  end
end

---@param app WindowObserver
---@param message string
local function disable(app, message)
  app.failed = true
  retire(app)
  failure(app, message)
end

---@param app WindowObserver
---@param record WindowRecord
local function unwatch(app, record)
  for notification in pairs(record.notifications) do
    -- Destruction can invalidate an element before its registrations are removed.
    pcall(app.observer.removeWatcher, app.observer, record.element, notification)
  end
  record.notifications = {}
end

---@param app WindowObserver
---@param record WindowRecord
local function watch(app, record)
  if record.failed or not record.window then
    return
  end
  for notification in pairs(wanted) do
    if not record.notifications[notification] then
      local ok, err = pcall(app.observer.addWatcher, app.observer, record.element, notification)
      if not ok then
        record.failed = true
        unwatch(app, record)
        emit(app, record, module.windowDestroyed)
        failure(app, notification .. ": " .. tostring(err))
        return
      end
      record.notifications[notification] = true
    end
  end
end

---@param app WindowObserver
---@param element hs.axuielement
---@return WindowRecord?
local function track(app, element)
  -- Retired mid-scan.
  if not app.observer then
    return
  end
  for _, record in ipairs(app.windows) do
    if record.element == element then
      return record.window and not record.failed and record or nil
    end
  end
  if
    element:attributeValue("AXRole") ~= "AXWindow"
    or not eligible(element, element:attributeValue("AXSubrole"))
  then
    return
  end
  local parent = element:attributeValue("AXParent")
  if parent and parent:attributeValue("AXRole") ~= "AXApplication" then
    return
  end
  local record = {
    element = element,
    recent = 0,
    allowed = {},
    notifications = {},
  }
  app.windows[#app.windows + 1] = record
  local ok, err = pcall(function()
    local window = element:asHSWindow()
    local id = window and window:id()
    if not id or id == 0 then
      error("window has no ID", 0)
    end
    record.window, record.id = window, id
    record.recent = order[id] or 0
  end)
  if not ok then
    record.failed = true
    failure(app, "window registration: " .. tostring(err))
    return
  end
  watch(app, record)
  if record.failed or not record.window then
    return
  end
  emit(app, record, module.windowCreated)
  return record
end

---@param app WindowObserver
local function snapshot(app)
  local windows, err = app.element:attributeValue("AXWindows")
  if type(windows) ~= "table" then
    error(err or "window list unavailable", 0)
  end
  for _, element in ipairs(windows) do
    track(app, element)
  end
end

---@param app WindowObserver
---@param element hs.axuielement
---@param event string
local function changed(app, element, event)
  if event == "AXFocusedWindowChanged" and not frontmost(app) then
    return
  end
  if event == "AXUIElementDestroyed" then
    for index, record in ipairs(app.windows) do
      if record.element == element then
        table.remove(app.windows, index)
        unwatch(app, record)
        if not record.failed then
          emit(app, record, module.windowDestroyed)
        end
        return
      end
    end
    return
  end
  local record = track(app, element)
  if not record then
    return
  end
  if event == "AXFocusedWindowChanged" then
    recent = recent + 1
    record.recent = recent
    emit(app, record, module.windowFocused)
  elseif notifications[event] then
    emit(app, record, notifications[event])
  end
end

---@param app WindowObserver
local function focused(app)
  if not frontmost(app) then
    return
  end
  local window = app.app:focusedWindow()
  if window then
    local element = hs.axuielement.windowElement(window) --[[@as hs.axuielement?]]
    if not element then
      error("focused window Accessibility unavailable", 0)
    end
    changed(app, element, "AXFocusedWindowChanged")
  end
end

---@param application hs.application
local function attach(application)
  local pid = application:pid()
  local kind = application:kind()
  if
    apps[pid]
    or launching[pid]
    or kind ~= 1
    or application:bundleID() == "org.hammerspoon.Hammerspoon"
  then
    return
  end
  ---@type WindowObserver
  local app = { app = application, windows = {} }
  apps[pid] = app
  local ok, err = pcall(function()
    local element = hs.axuielement.applicationElement(application) --[[@as hs.axuielement?]]
    if not element then
      error("application Accessibility unavailable", 0)
    end
    local attributes, message = element:attributeNames()
    if not attributes then
      error(message or "application Accessibility unavailable", 0)
    end
    local supportsWindows = false
    for _, name in ipairs(attributes) do
      supportsWindows = supportsWindows or name == "AXWindows"
    end
    if not supportsWindows then
      error("application does not expose AXWindows", 0)
    end
    app.element = element
    local observer = hs.axuielement.observer.new(pid) --[[@as hs.axuielement.observer]]
    app.observer = observer
    observer:callback(function(_, window, event)
      if apps[pid] ~= app or app.failed then
        return
      end
      local handled, failureMessage = xpcall(changed, debug.traceback, app, window, event)
      if not handled then
        disable(app, event .. ": " .. tostring(failureMessage))
      end
    end)
    -- Subscribe before the snapshot so initialization cannot lose an event.
    observer:addWatcher(element, "AXWindowCreated")
    observer:addWatcher(element, "AXFocusedWindowChanged")
    observer:start()
    snapshot(app)
    -- AXWindows omits background documents on inactive Spaces.
    local main = element:attributeValue("AXMainWindow")
    if main then
      track(app, main)
    end
    focused(app)
  end)
  if not ok then
    disable(app, "observer setup: " .. tostring(err))
  end
end

---@param pid integer
detach = function(pid)
  local app = apps[pid]
  if not app then
    return
  end
  apps[pid] = nil
  retire(app)
end

---@param predicate? fun(window: hs.window): boolean?
---@return WindowFilter
function module.new(predicate)
  local filter = setmetatable({ predicate = predicate, callbacks = {} }, Filter)
  filters[filter] = true
  if not applicationWatcher then
    -- Seed recency from native ordering, without another Accessibility scan.
    local ids = (hs.window --[[@as { _orderedwinids: fun(): integer[] }]])._orderedwinids()
    recent = #ids
    for index, id in ipairs(ids) do
      order[id] = recent - index + 1
    end
    local events = hs.application.watcher
    applicationWatcher = events.new(function(_, event, application)
      if not application then
        return
      end
      local pid = application:pid()
      if event == events.launching then
        launching[pid] = true
        return
      elseif event == events.terminated then
        launching[pid] = nil
        detach(pid)
        return
      elseif event == events.launched then
        launching[pid] = nil
        -- A reload can seed an app before its launch completes.
        if apps[pid] and apps[pid].failed then
          apps[pid] = nil
        end
      end
      if event == events.launched or event == events.activated then
        attach(application)
      end
      local app = apps[pid]
      if not app or not app.observer or app.failed then
        return
      end
      if event == events.activated then
        local ok, err = pcall(focused, app)
        if not ok then
          disable(app, "focused window: " .. tostring(err))
        end
      elseif event == events.hidden or event == events.unhidden then
        for _, record in ipairs(app.windows) do
          emit(app, record, event == events.hidden and module.windowHidden or module.windowUnhidden)
        end
      end
    end)
    applicationWatcher:start()
    spaceWatcher = hs.spaces.watcher.new(function()
      -- Only apps with windows on the visible Spaces can reveal windows AXWindows omitted.
      -- Plain `list()` drops windows in front of the first one titled "Dock".
      local visible = {}
      for _, info in
        ipairs(hs.window.list(true) --[[@as table[] ]])
      do
        visible[info.kCGWindowOwnerPID] = true
      end
      for pid, app in pairs(apps) do
        -- Space notifications can precede app termination callbacks.
        if not app.app:isRunning() then
          detach(pid)
        elseif visible[pid] and app.observer and not app.failed then
          local ok, err = pcall(snapshot, app)
          if not ok then
            disable(app, "window snapshot: " .. tostring(err))
          end
        end
      end
    end)
    spaceWatcher:start()
    for _, application in ipairs(hs.application.runningApplications()) do
      attach(application)
    end
    order = {}
  end
  filter:getWindows()
  return filter
end

---@param events string|string[]
---@param callback fun(window: hs.window, app: string, event: string, id: integer)
function Filter:subscribe(events, callback)
  for _, event in ipairs(type(events) == "table" and events or { events }) do
    self.callbacks[event] = self.callbacks[event] or {}
    table.insert(self.callbacks[event], callback)
    for notification, mapped in pairs(notifications) do
      if mapped == event then
        wanted[notification] = true
      end
    end
  end
  for _, app in pairs(apps) do
    if app.observer and not app.failed then
      for _, record in ipairs(app.windows) do
        watch(app, record)
      end
    end
  end
  return self
end

---@return hs.window[]
function Filter:getWindows()
  local records = {}
  if not filters[self] then
    return {}
  end
  for _, app in pairs(apps) do
    if not app.failed then
      for _, record in ipairs(app.windows) do
        if matches(self, record) then
          records[#records + 1] = record
        end
      end
    end
  end
  table.sort(records, function(left, right)
    return left.recent > right.recent or (left.recent == right.recent and left.id < right.id)
  end)
  local windows = {}
  for _, record in ipairs(records) do
    windows[#windows + 1] = record.window
  end
  return windows
end

---@param id integer
---@param pid integer
---@return hs.window?
function Filter:getWindow(id, pid)
  local app = apps[pid]
  if filters[self] and app and not app.failed then
    for _, record in ipairs(app.windows) do
      if record.id == id and matches(self, record) then
        return record.window
      end
    end
  end
end

-- Tracked windows of one app, without the Accessibility reads a predicate makes.
---@param pid integer
---@return table<integer, hs.window>
function module.windowsOf(pid)
  local app, windows = apps[pid], {}
  for _, record in ipairs(app and not app.failed and app.windows or {}) do
    if record.window and not record.failed then
      windows[record.id] = record.window
    end
  end
  return windows
end

function Filter:delete()
  filters[self] = nil
  self.callbacks = {}
  for _, app in pairs(apps) do
    for _, record in ipairs(app.windows) do
      record.allowed[self] = nil
    end
  end
  if not next(filters) then
    module.stop()
  end
end

function module.stop()
  if applicationWatcher then
    applicationWatcher:stop()
    spaceWatcher:stop()
  end
  for _, app in pairs(apps) do
    if app.observer then
      app.observer:stop()
    end
  end
  apps, filters, launching, wanted, order = {}, {}, {}, { AXUIElementDestroyed = true }, {}
  applicationWatcher, spaceWatcher = nil, nil
end

return module

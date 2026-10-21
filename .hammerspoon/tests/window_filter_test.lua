local root = assert(arg[1])
local passed = 0
local function test(name, callback)
  callback()
  passed = passed + 1
  print("PASS " .. name)
end

local function setup(options)
  options = options or {}
  local model = {
    logs = {},
    alerts = {},
    observers = {},
    reads = 0,
    attributeReads = 0,
    registrations = 0,
    conversions = 0,
    focusedReads = 0,
    runningReads = 0,
    background = options.background,
    running = not options.newApp,
    visible = true,
  }
  local windows = {}
  local app = {
    name = function()
      return "Browser"
    end,
    pid = function()
      return 42
    end,
    kind = function()
      return options.accessory and 0 or 1
    end,
    bundleID = function()
      return "test.browser"
    end,
    focusedWindow = function()
      model.focusedReads = model.focusedReads + 1
      return model.focused and model.focused.window
    end,
    isFrontmost = function()
      error("isFrontmost asks the app over Accessibility")
    end,
    isRunning = function()
      return model.running
    end,
  }
  model.app = app
  local finder = {
    pid = function()
      return 7
    end,
  }
  local element = {
    attributeNames = function()
      model.attributeReads = model.attributeReads + 1
      if options.unresponsive then
        return nil, "Messaging failed"
      end
      return { "AXWindows", "AXFocusedWindow" }
    end,
    attributeValue = function(_, name)
      if name == "AXRole" then
        return "AXApplication"
      elseif name == "AXMainWindow" then
        return options.mainOnly and model.first or nil
      end
      model.reads = model.reads + 1
      if model.snapshotError then
        return nil, "snapshot failed"
      end
      return options.mainOnly and {} or windows
    end,
  }
  model.element = element
  function model:window(id, title)
    local record = { id = id, title = title or "ordinary", notifications = {} }
    record.window = {
      id = function()
        assert(not record.destroyed, "ID read after destruction")
        return record.id
      end,
      title = function()
        assert(not record.destroyed, "title read after destruction")
        return record.title
      end,
      application = function()
        return app
      end,
      isStandard = function()
        return record.standard ~= false
      end,
      subrole = function()
        assert(not record.destroyed, "subrole read after destruction")
        return record.subrole or (record.standard == false and "AXUnknown" or "AXStandardWindow")
      end,
    }
    record.asHSWindow = function()
      model.conversions = model.conversions + 1
      return record.window
    end
    record.attributeValue = function(_, name)
      if name == "AXRole" then
        return "AXWindow"
      elseif name == "AXSubrole" then
        return record.window:subrole()
      elseif name == "AXParent" then
        return record.parent
      elseif name == "AXModal" then
        return record.modal
      elseif name == "AXMinimizeButton" and record.minimizable ~= nil then
        return {
          attributeValue = function(_, attribute)
            assert(attribute == "AXEnabled")
            return record.minimizable
          end,
        }
      elseif name == "AXFullScreen" or name == "AXFrame" then
        error("blacklist must not inspect fullscreen state or window size")
      end
    end
    windows[#windows + 1] = record
    return record
  end
  model.first = model:window(options.missingID and 0 or 100)
  if options.unknown then
    model.first.standard = false
  end
  local events =
    { launching = 0, launched = 1, activated = 2, terminated = 3, hidden = 4, unhidden = 5 }
  events.new = function(callback)
    model.appCallback = function(name, event, application)
      if event == events.launched then
        model.running = true
      elseif event == events.terminated then
        model.running = false
      end
      callback(name, event, application)
    end
    return {
      start = function() end,
      stop = function()
        model.appStopped = true
      end,
    }
  end
  local environment = setmetatable({
    hs = {
      application = {
        watcher = events,
        runningApplications = function()
          model.runningReads = model.runningReads + 1
          return model.running and { app } or {}
        end,
        frontmostApplication = function()
          return model.background and finder or app
        end,
      },
      spaces = {
        watcher = {
          new = function(callback)
            model.spaceCallback = callback
            return {
              start = function() end,
              stop = function()
                model.spaceStopped = true
              end,
            }
          end,
        },
      },
      timer = setmetatable({}, {
        __index = function()
          error("window observations must not use timers")
        end,
      }),
      window = {
        _orderedwinids = function()
          return { 200, 100 }
        end,
        list = function()
          return { { kCGWindowOwnerPID = 7 }, model.visible and { kCGWindowOwnerPID = 42 } or nil }
        end,
      },
      alert = {
        show = function(message)
          model.alerts[#model.alerts + 1] = message
        end,
      },
      axuielement = {
        applicationElement = function()
          return element
        end,
        windowElement = function(window)
          for _, record in ipairs(windows) do
            if record.window == window then
              return record
            end
          end
        end,
        observer = {
          new = function()
            if options.observerError then
              error("observer unavailable")
            end
            local observer = { registered = {} }
            model.observers[#model.observers + 1] = observer
            function observer:addWatcher(target, name)
              model.registrations = model.registrations + 1
              if name == options.unsupported then
                error("notification unsupported")
              end
              self.registered[target] = self.registered[target] or {}
              self.registered[target][name] = true
            end
            function observer:removeWatcher(target, name)
              self.registered[target][name] = nil
            end
            function observer:callback(callback)
              self.fn = callback
            end
            function observer:start()
              self.active = true
            end
            function observer:stop()
              self.active = false
            end
            return observer
          end,
        },
      },
    },
    print = function(message)
      model.logs[#model.logs + 1] = message
    end,
  }, { __index = _G })
  local logger = assert(loadfile(root .. "/logger.lua", "t", environment))()
  model.logger = logger
  environment.require = function(name)
    assert(name == "lib.logger")
    return logger
  end
  model.module = assert(loadfile(root .. "/window_filter.lua", "t", environment))()
  model.filter = model.module.new()
  function model:emit(target, event, observer)
    observer = observer or self.observers[#self.observers]
    observer.fn(observer, target, event)
  end
  return model
end

test("windowless focus does not delay observer registration", function()
  local model = setup()
  assert(#model.observers == 1 and model.observers[1].active)
  assert(#model.filter:getWindows() == 1 and #model.alerts == 0)
end)

test(
  "activation during launch waits for launch completion before accessing Accessibility",
  function()
    local options = { newApp = true, unresponsive = true }
    local model = setup(options)
    model.appCallback("Browser", 0, model.app)
    model.appCallback("Browser", 2, model.app)
    model.appCallback("Browser", 2, model.app)
    model.spaceCallback()
    assert(model.attributeReads == 0 and #model.observers == 0)
    assert(#model.logs == 0 and #model.alerts == 0)
    options.unresponsive = false
    model.appCallback("Browser", 1, model.app)
    assert(#model.observers == 1 and model.observers[1].active)
    assert(#model.filter:getWindows() == 1 and model.attributeReads == 1)
    model.appCallback("Browser", 2, model.app)
    model.appCallback("Browser", 1, model.app)
    assert(#model.observers == 1 and model.attributeReads == 1)
    assert(#model.logs == 0 and #model.alerts == 0)
  end
)

test("background launches attach when complete without waiting for activation", function()
  local model = setup({ newApp = true, background = true })
  model.appCallback("Browser", 0, model.app)
  assert(model.attributeReads == 0)
  model.appCallback("Browser", 1, model.app)
  assert(#model.observers == 1 and model.observers[1].active)
  assert(#model.filter:getWindows() == 1 and model.focusedReads == 0)
end)

test("termination during launch clears pending state before PID reuse", function()
  local model = setup({ newApp = true })
  model.appCallback("Browser", 0, model.app)
  model.appCallback("Browser", 3, model.app)
  assert(model.attributeReads == 0 and #model.observers == 0)
  model.appCallback("Browser", 2, model.app)
  assert(#model.observers == 1 and #model.filter:getWindows() == 1)
end)

test("a pending launch does not block activation of another process", function()
  local model = setup({ newApp = true })
  local other = setmetatable({
    pid = function()
      return 43
    end,
  }, { __index = model.app })
  model.appCallback("Browser", 0, model.app)
  model.appCallback("Other", 2, other)
  assert(#model.observers == 1 and model.attributeReads == 1)
  model.appCallback("Browser", 2, model.app)
  assert(#model.observers == 1 and model.attributeReads == 1)
  model.appCallback("Browser", 1, model.app)
  assert(#model.observers == 2 and model.attributeReads == 2)
end)

test("shutdown clears pending launches before starting a new filter", function()
  local model = setup({ newApp = true })
  model.appCallback("Browser", 0, model.app)
  model.module.stop()
  model.filter = model.module.new()
  model.appCallback("Browser", 2, model.app)
  assert(#model.observers == 1 and #model.filter:getWindows() == 1)
end)

test("accessory and menu-bar apps stay excluded after activation", function()
  local model = setup({ accessory = true })
  assert(#model.observers == 0 and #model.logs == 0)
  model.appCallback("Browser", 2, model.app)
  model.spaceCallback()
  assert(#model.observers == 0 and #model.filter:getWindows() == 0)
  assert(model.reads == 0 and model.focusedReads == 0 and #model.alerts == 0)
end)

test("background documents are tracked without querying their focused window", function()
  local model = setup({ background = true })
  assert(#model.filter:getWindows() == 1 and model.focusedReads == 0)
  model:emit(model:window(200), "AXWindowCreated")
  assert(#model.filter:getWindows() == 2)
  assert(#model.logs == 0 and #model.alerts == 0)
end)

test("main document windows on inactive Spaces are seeded without foreground focus", function()
  local model = setup({ background = true, mainOnly = true })
  assert(#model.filter:getWindows() == 1 and model.filter:getWindows()[1] == model.first.window)
  assert(model.focusedReads == 0 and #model.logs == 0 and #model.alerts == 0)
end)

test("background Messaging failed errors log, alert, and stop without retries", function()
  local model = setup({ background = true, unresponsive = true })
  assert(#model.logs == 1 and #model.alerts == 1 and #model.observers == 0)
  assert(model.logs[1]:find("observer setup: Messaging failed", 1, true))
  model.appCallback("Browser", 2, model.app)
  model.spaceCallback()
  assert(model.attributeReads == 1 and #model.logs == 1 and #model.alerts == 1)
end)

test("blacklisted panels are excluded before conversion or registration", function()
  local model = setup()
  local registrations = model.registrations
  for _, subrole in ipairs({ "AXDialog", "AXSystemDialog", "AXFloatingWindow" }) do
    local panel = model:window(0)
    panel.subrole = subrole
    panel.asHSWindow = function()
      error("blacklisted panel must not be converted")
    end
    model:emit(panel, "AXWindowCreated")
  end
  assert(#model.logs == 0 and #model.alerts == 0)
  assert(model.registrations == registrations and #model.filter:getWindows() == 1)
end)

test("unknown main windows are seeded on inactive Spaces without fullscreen checks", function()
  local model = setup({ unknown = true, background = true, mainOnly = true })
  assert(model.filter:getWindow(100, 42) == model.first.window)
  assert(model.focusedReads == 0 and #model.logs == 0)
end)

test(
  "minimizable top-level dialogs are tracked while modal and utility panels stay excluded",
  function()
    local model = setup()
    local events = 0
    model.filter:subscribe(model.module.windowCreated, function()
      events = events + 1
    end)
    local window = model:window(200)
    window.subrole, window.minimizable = "AXDialog", true
    model:emit(window, "AXWindowCreated")
    assert(model.filter:getWindow(200, 42) == window.window and events == 1)
    window.modal = true
    assert(model.filter:getWindow(200, 42) == nil)
    window.modal, window.minimizable = false, false
    assert(model.filter:getWindow(200, 42) == nil)
    window.minimizable = true
    assert(model.filter:getWindow(200, 42) == window.window)
    for index, subrole in ipairs({ "AXSystemDialog", "AXFloatingWindow" }) do
      local panel = model:window(200 + index)
      panel.subrole, panel.minimizable = subrole, true
      model:emit(panel, "AXWindowCreated")
      assert(model.filter:getWindow(panel.id, 42) == nil)
    end
    assert(events == 1 and #model.logs == 0)
  end
)

test("unlisted window subroles are accepted by default regardless of size", function()
  local model = setup()
  for index, subrole in ipairs({ "AXUnknown", "AXCustomWindow", "" }) do
    local window = model:window(200 + index)
    window.subrole = subrole
    model:emit(window, "AXWindowCreated")
    assert(model.filter:getWindow(window.id, 42) == window.window)
  end
end)

test("unknown windows emit focus and destruction with cached identity", function()
  local model = setup({ unknown = true })
  local focused, destroyed
  model.filter:subscribe(model.module.windowFocused, function(window)
    focused = window
  end)
  model.filter:subscribe(model.module.windowDestroyed, function(_, _, _, id)
    destroyed = id
  end)
  model:emit(model.first, "AXFocusedWindowChanged")
  assert(focused == model.first.window)
  model.first.destroyed = true
  model:emit(model.first, "AXUIElementDestroyed")
  assert(destroyed == 100 and model.filter:getWindow(100, 42) == nil)
end)

test("child windows are excluded before conversion or registration", function()
  local model = setup()
  local window = model:window(200)
  window.parent = {
    attributeValue = function()
      return "AXWindow"
    end,
  }
  window.asHSWindow = function()
    error("child window must not be converted")
  end
  local registrations = model.registrations
  model:emit(window, "AXWindowCreated")
  assert(model.filter:getWindow(200, 42) == nil and #model.logs == 0)
  assert(model.registrations == registrations)
end)

test("a tracked window is excluded if its subrole becomes blacklisted", function()
  local model = setup({ unknown = true })
  model.first.subrole = "AXDialog"
  assert(model.filter:getWindow(100, 42) == nil and #model.filter:getWindows() == 0)
  model.first.subrole = "AXCustomWindow"
  assert(model.filter:getWindow(100, 42) == model.first.window)
end)

test("cached window lookup respects process identity and filter membership", function()
  local model = setup({ unknown = true })
  assert(model.filter:getWindow(100, 43) == nil)
  model.filter.predicate = function()
    return false
  end
  assert(model.filter:getWindow(100, 42) == nil)
  model.filter:delete()
  assert(model.filter:getWindow(100, 42) == nil)
end)

test("windowsOf lists tracked windows without predicates or Accessibility reads", function()
  local options = {}
  local model = setup(options)
  local second = model:window(200)
  model:emit(second, "AXWindowCreated")
  options.unsupported = "AXUIElementDestroyed"
  local failed = model:window(300)
  model:emit(failed, "AXWindowCreated")
  assert(#model.logs == 1 and #model.alerts == 1)
  model.filter.predicate = function()
    error("predicate evaluated")
  end
  for _, record in ipairs({ model.first, second, failed }) do
    record.attributeValue = function()
      error("Accessibility read")
    end
  end
  local reads, conversions = model.reads + model.attributeReads, model.conversions
  local windows, count = model.module.windowsOf(42), 0
  for _ in pairs(windows) do
    count = count + 1
  end
  assert(count == 2 and windows[100] == model.first.window and windows[200] == second.window)
  assert(next(model.module.windowsOf(43)) == nil)
  assert(model.reads + model.attributeReads == reads and model.conversions == conversions)
  assert(#model.logs == 1)
  model.snapshotError = true
  model.spaceCallback()
  assert(#model.logs == 2 and next(model.module.windowsOf(42)) == nil)
end)

test(
  "background focus notifications do not discover windows or report readiness failures",
  function()
    local model = setup({ background = true })
    local pending = model:window(0)
    local conversions = model.conversions
    model.filter:subscribe(model.module.windowCreated, function()
      error("background focus must not emit creation")
    end)
    model:emit(pending, "AXFocusedWindowChanged")
    assert(model.conversions == conversions and #model.logs == 0 and #model.alerts == 0)
    assert(#model.filter:getWindows() == 1)
  end
)

test("desktop scroll areas in AXWindows are ignored", function()
  local model = setup()
  model:window(0).attributeValue = function()
    return "AXScrollArea"
  end
  model.spaceCallback()
  assert(#model.logs == 0 and #model.filter:getWindows() == 1)
end)

test("filters share one observer and focus updates cached order", function()
  local model = setup()
  local second = model:window(200)
  local events = 0
  model.module.new("Browser"):subscribe(model.module.windowFocused, function(window)
    assert(window == second.window)
    events = events + 1
  end)
  model:emit(second, "AXWindowCreated")
  model:emit(second, "AXFocusedWindowChanged")
  assert(#model.observers == 1 and events == 1)
  assert(model.filter:getWindows()[1] == second.window)
end)

test("background window focus changes do not emit global focus", function()
  local model = setup()
  model.background = true
  model.filter:subscribe(model.module.windowFocused, function()
    error("background focus emitted")
  end)
  model:emit(model.first, "AXFocusedWindowChanged")
  assert(#model.logs == 0)
end)

test("destroy notifications retain ID and filter membership after AX invalidation", function()
  local model = setup()
  local filter = model.module.new(function(window)
    return window:title() == "ordinary"
  end)
  local destroyed
  filter:subscribe(model.module.windowDestroyed, function(_, _, _, id)
    destroyed = id
  end)
  model.first.destroyed = true
  model:emit(model.first, "AXUIElementDestroyed")
  assert(destroyed == 100 and #filter:getWindows() == 0 and #model.logs == 0)
end)

test("missing ID fails once without polling or event-driven retries", function()
  local model = setup({ missingID = true })
  assert(#model.logs == 1 and #model.alerts == 1 and #model.filter:getWindows() == 0)
  model.first.id = 100
  model:emit(model.first, "AXWindowCreated")
  model:emit(model.first, "AXFocusedWindowChanged")
  model.spaceCallback()
  assert(#model.logs == 1 and #model.alerts == 1 and #model.filter:getWindows() == 0)
end)

test("unsupported window notification stops registration and reports once", function()
  local model = setup({ unsupported = "AXUIElementDestroyed" })
  local registrations = model.registrations
  assert(#model.logs == 1 and #model.alerts == 1 and #model.filter:getWindows() == 0)
  model:emit(model.first, "AXWindowCreated")
  model.filter:subscribe(model.module.windowFocused, function()
    error("failed window emitted")
  end)
  assert(model.registrations == registrations and #model.logs == 1)
end)

test("unsupported application notification stops the observer without retry", function()
  local model = setup({ unsupported = "AXFocusedWindowChanged" })
  assert(not model.observers[1].active and #model.logs == 1 and #model.alerts == 1)
  local registrations = model.registrations
  model.appCallback("Browser", 2, model.app)
  model.spaceCallback()
  assert(model.registrations == registrations and #model.logs == 1)
end)

test("observer creation failures log, alert, and stop without retries", function()
  local model = setup({ observerError = true })
  model.appCallback("Browser", 2, model.app)
  assert(#model.observers == 0 and #model.logs == 1 and #model.alerts == 1)
end)

test("application elements in focus notifications are not failed windows", function()
  local model = setup()
  model:emit(model.element, "AXFocusedWindowChanged")
  assert(#model.logs == 0 and #model.filter:getWindows() == 1)
end)

test("Space snapshots are event-driven and stop on their first failure", function()
  local model = setup()
  local second = model:window(200)
  local reads = model.reads
  assert(#model.filter:getWindows() == 1 and model.reads == reads)
  model.spaceCallback()
  assert(#model.filter:getWindows() == 2 and model.reads == reads + 1)
  model.snapshotError = true
  model.spaceCallback()
  assert(#model.logs == 1 and #model.alerts == 1 and not model.observers[1].active)
  model.spaceCallback()
  assert(model.reads == reads + 2 and #model.logs == 1)
  assert(second.id == 200)
end)

test("focus follows the system frontmost app without asking the app", function()
  local model = setup({ background = true })
  local focused = 0
  model.filter:subscribe(model.module.windowFocused, function()
    focused = focused + 1
  end)
  local second = model:window(200)
  model:emit(second, "AXWindowCreated")
  model.focused = second
  model:emit(second, "AXFocusedWindowChanged")
  model.appCallback("Browser", 2, model.app)
  assert(focused == 0 and model.focusedReads == 0)
  model.background = false
  model:emit(second, "AXFocusedWindowChanged")
  model.appCallback("Browser", 2, model.app)
  assert(focused == 2 and model.focusedReads == 1)
  assert(#model.logs == 0 and #model.alerts == 0)
end)

test("Space changes re-scan only apps with on-screen windows", function()
  local model = setup()
  local reads, running = model.reads, model.runningReads
  model.visible = false
  model.spaceCallback()
  assert(model.reads == reads)
  model.visible = true
  model.spaceCallback()
  assert(model.reads == reads + 1 and model.runningReads == running)
end)

test("an exited app without on-screen windows is detached on a Space change", function()
  local model = setup()
  local destroyed = 0
  model.filter:subscribe(model.module.windowDestroyed, function()
    destroyed = destroyed + 1
  end)
  local running = model.runningReads
  model.running, model.visible = false, false
  model.spaceCallback()
  assert(destroyed == 1 and #model.filter:getWindows() == 0 and model.runningReads == running)
  assert(#model.logs == 0 and #model.alerts == 0)
end)

test("exited apps are detached before Space snapshots without reading dead windows", function()
  local model = setup()
  local destroyed = 0
  model.filter:subscribe(model.module.windowDestroyed, function(_, _, _, id)
    assert(id == 100)
    destroyed = destroyed + 1
  end)
  local reads = model.reads
  model.running, model.snapshotError, model.first.destroyed = false, true, true
  model.spaceCallback()
  assert(model.reads == reads and destroyed == 1)
  assert(#model.logs == 0 and #model.alerts == 0)
  assert(not model.observers[1].active and #model.filter:getWindows() == 0)
  model.appCallback(nil, 3, model.app)
  model.spaceCallback()
  model:emit(model.first, "AXFocusedWindowChanged")
  assert(model.reads == reads and destroyed == 1 and #model.logs == 0)
end)

test("apps exiting during a Space snapshot are detached without an alert", function()
  local model = setup()
  local read = model.element.attributeValue
  model.element.attributeValue = function(element, name)
    if name == "AXWindows" then
      model.running = false
      return nil, "Messaging failed"
    end
    return read(element, name)
  end
  local destroyed = 0
  model.filter:subscribe(model.module.windowDestroyed, function()
    destroyed = destroyed + 1
  end)
  model.spaceCallback()
  assert(destroyed == 1 and #model.logs == 0 and #model.alerts == 0)
  assert(not model.observers[1].active and #model.filter:getWindows() == 0)
end)

test("Messaging failed from a running app still logs and alerts once", function()
  local model = setup()
  model.element.attributeValue = function()
    return nil, "Messaging failed"
  end
  model.spaceCallback()
  assert(#model.logs == 1 and #model.alerts == 1)
  assert(model.logs[1]:find("window snapshot: Messaging failed", 1, true))
  assert(not model.observers[1].active)
  model.spaceCallback()
  assert(#model.logs == 1 and #model.alerts == 1)
end)

test("Space cleanup handles termination notifications without an application", function()
  local model = setup()
  model.appCallback(nil, 3, nil)
  model.snapshotError = true
  model.spaceCallback()
  assert(#model.logs == 0 and #model.alerts == 0)
  assert(not model.observers[1].active and #model.filter:getWindows() == 0)
end)

test("early exit cleanup allows relaunch and ignores the old observer", function()
  local model = setup()
  local observer = model.observers[1]
  model.running, model.snapshotError = false, true
  model.spaceCallback()
  model.snapshotError = nil
  model.appCallback(nil, 3, model.app)
  model.appCallback("Browser", 1, model.app)
  assert(#model.observers == 2 and #model.filter:getWindows() == 1)
  model:emit(model.first, "AXUIElementDestroyed", observer)
  assert(#model.filter:getWindows() == 1 and #model.logs == 0 and #model.alerts == 0)
end)

test("apps exiting during observer setup are removed without an alert", function()
  local model = setup({ newApp = true })
  model.element.attributeNames = function()
    model.running = false
    return nil, "Messaging failed"
  end
  model.appCallback("Browser", 1, model.app)
  assert(#model.filter:getWindows() == 0 and #model.observers == 0)
  assert(#model.logs == 0 and #model.alerts == 0)
end)

test("apps exiting during window registration clear existing windows quietly", function()
  local model = setup()
  local second = model:window(200)
  second.asHSWindow = function()
    model.running = false
  end
  local destroyed = 0
  model.filter:subscribe(model.module.windowDestroyed, function(_, _, _, id)
    assert(id == 100)
    destroyed = destroyed + 1
  end)
  model:emit(second, "AXWindowCreated")
  assert(destroyed == 1 and #model.filter:getWindows() == 0)
  assert(not model.observers[1].active and #model.logs == 0 and #model.alerts == 0)
end)

test("app termination clears windows and rejects stale PID callbacks", function()
  local model = setup()
  local observer = model.observers[1]
  model.appCallback("Browser", 3, model.app)
  assert(not observer.active and #model.filter:getWindows() == 0)
  model:emit(model.first, "AXWindowCreated", observer)
  assert(#model.filter:getWindows() == 0)
  model.appCallback("Browser", 1, model.app)
  assert(#model.observers == 2 and #model.filter:getWindows() == 1)
  model:emit(model.first, "AXUIElementDestroyed", observer)
  assert(#model.filter:getWindows() == 1)
end)

test("subscriber failure reports without starving another subscriber", function()
  local model = setup()
  local delivered = 0
  model.filter:subscribe(model.module.windowFocused, function()
    error("consumer failed")
  end)
  model.filter:subscribe(model.module.windowFocused, function()
    delivered = delivered + 1
  end)
  model:emit(model.first, "AXFocusedWindowChanged")
  assert(delivered == 1 and #model.logs == 1 and #model.alerts == 1)
  model:emit(model.first, "AXFocusedWindowChanged")
  assert(delivered == 2 and #model.logs == 1 and #model.alerts == 1)
end)

test("failed predicates stop without repeated errors", function()
  local model = setup()
  local calls = 0
  model.filter.predicate = function()
    calls = calls + 1
    error("predicate failed")
  end
  model.filter:getWindows()
  model.filter:getWindows()
  assert(calls == 1 and #model.logs == 1 and #model.alerts == 1)
end)

test("deleting the final filter stops observers and late callbacks", function()
  local model = setup()
  model.filter:delete()
  assert(model.appStopped and model.spaceStopped and not model.observers[1].active)
  model:emit(model.first, "AXWindowCreated")
  assert(#model.filter:getWindows() == 0 and #model.logs == 0)
end)

test("explicit action failures still log and show a popup", function()
  local model = setup()
  model.logger.error("Window switcher: focus failed")
  assert(#model.logs == 1 and #model.alerts == 1)
  assert(model.alerts[1] == "Window switcher: focus failed")
end)

print("RESULT " .. passed .. " passed, 0 failed")

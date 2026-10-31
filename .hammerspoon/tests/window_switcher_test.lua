local root = assert(arg[1], "pass a lib directory")
local passed, failed = 0, 0
local function assertEqual(actual, expected, label)
  assert(
    actual == expected,
    (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
  )
end
local function near(actual, expected, label)
  assert(
    math.abs(actual - expected) < 1e-6,
    (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
  )
end
local function test(name, body)
  local ok, err = xpcall(body, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
-- hs.timer keeps a stopped timer's callback: count timers alive only through it.
local function leaked(timers)
  local here, registry = debug.getinfo(1, "S").source, {}
  local weak = setmetatable({}, { __mode = "k" })
  for i = #timers, 1, -1 do
    local timer = timers[i]
    if not timer.active then
      table.remove(timers, i)
      if debug.getinfo(timer.callback, "S").source ~= here then
        registry[#registry + 1], weak[timer] = timer.callback, true
      end
    end
  end
  local function alive()
    local count = 0
    for _ = 1, 3 do
      collectgarbage()
    end
    for _ in pairs(weak) do
      count = count + 1
    end
    return count
  end
  local held = alive()
  registry = nil
  return held - alive()
end
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for key, nested in pairs(value) do
    result[key] = copy(nested)
  end
  return result
end
local function upvalue(closure, name)
  for i = 1, 100 do
    local key, value = debug.getupvalue(closure, i)
    if key == name then
      return value
    end
    if not key then
      return nil
    end
  end
end
local function harness(options)
  options = options or {}
  local desktop = {
    now = 0,
    timers = {},
    commands = {},
    alerts = {},
    logs = {},
    windows = {},
    tracked = {},
    captures = {},
    draws = {},
    applications = {},
    unhides = 0,
    raisedPrints = 0,
  }
  for i = 1, options.count or 9 do
    desktop.windows[i] = {
      id = i,
      pid = 100 + i,
      app = "App " .. i,
      title = "Window " .. i,
      role = "AXWindow",
      subrole = "AXStandardWindow",
      ["root-window"] = true,
      ["has-focus"] = i == 1,
      ["is-minimized"] = false,
      ["is-hidden"] = false,
    }
  end
  local function timer(delay, callback, repeating)
    local scheduled =
      { at = desktop.now + delay, delay = delay, callback = callback, active = true }
    function scheduled:stop()
      self.active = false
      return self
    end
    function scheduled:start()
      self.active = true
      self.at = desktop.now + self.delay
      return self
    end
    function scheduled:setNextTrigger(value)
      self.at = desktop.now + value
      return self
    end
    scheduled.repeating = repeating
    desktop.timers[#desktop.timers + 1] = scheduled
    return scheduled
  end
  function desktop:advance(delta)
    local target = self.now + delta
    while true do
      local nextTimer
      for _, scheduled in ipairs(self.timers) do
        if
          scheduled.active
          and scheduled.at <= target
          and (not nextTimer or scheduled.at < nextTimer.at)
        then
          nextTimer = scheduled
        end
      end
      if not nextTimer then
        break
      end
      self.now = nextTimer.at
      nextTimer.active = nextTimer.repeating or false
      if nextTimer.active then
        nextTimer.at = self.now + nextTimer.delay
      end
      nextTimer.callback()
    end
    self.now = target
  end
  function desktop:commandCount(prefix)
    local count = 0
    for _, command in ipairs(self.commands) do
      if command:sub(1, #prefix) == prefix then
        count = count + 1
      end
    end
    return count
  end
  function desktop:setWindowFocus(id)
    for _, window in ipairs(self.windows) do
      window["has-focus"] = window.id == id
    end
    local callback = options.focusEvents ~= false and self.menu.windows.subscriptions.windowFocused
    if callback then
      callback({
        id = function()
          return id
        end,
      })
    end
  end
  function desktop:rows()
    local rows = {}
    for i, window in ipairs(self.windows) do
      rows[i] = {
        id = window.id,
        pid = window.pid,
        role = window.role,
        subrole = window.subrole,
        title = window.title,
        root = window["root-window"],
        minimized = window["is-minimized"],
      }
    end
    return rows
  end
  local windowManager = {}
  local function call(name, id, done, reply)
    desktop.commands[#desktop.commands + 1] = id and name .. " " .. id or name
    timer(options.replyDelay or 0.001, function()
      if not (options.intercept and options.intercept(desktop, name, done, id)) then
        reply()
      end
    end)
  end
  function windowManager.windows(done)
    call("windows", nil, done, function()
      done(true, nil, desktop:rows())
    end)
  end
  function windowManager.focus(pid, id, done)
    call("focus", id, done, function()
      local window = desktop.windows[id]
      assert(not window["is-hidden"], "focus attempted before unhide")
      if window.pid ~= pid then
        done(false, "window unavailable")
        return
      end
      timer(options.windowDelay or 0.003, function()
        desktop:setWindowFocus(id)
      end)
      done(true)
    end)
  end
  function windowManager.minimize(pid, id, minimized, done)
    call("minimize", id, done, function()
      assertEqual(desktop.windows[id].pid, pid)
      desktop.windows[id]["is-minimized"] = minimized
      done(true)
    end)
  end
  local types = { mouseMoved = 1, scrollWheel = 2, keyDown = 3, keyUp = 4, flagsChanged = 5 }
  local keys = { a = 0, tab = 48, escape = 53, left = 123, right = 124, ["return"] = 36 }
  local propertyCodes = {
    scrollWheelEventIsContinuous = 1,
    scrollWheelEventPointDeltaAxis1 = 2,
    scrollWheelEventDeltaAxis1 = 3,
  }
  local function chainObject()
    local object = {}
    for _, name in ipairs({ "level", "behaviorAsLabels", "clickActivating" }) do
      object[name] = function(self)
        return self
      end
    end
    function object:subscribe(event, callback)
      self.subscriptions = self.subscriptions or {}
      for _, name in ipairs(type(event) == "table" and event or { event }) do
        self.subscriptions[name] = callback
      end
      return self
    end
    function object:start()
      self.enabled = true
      return self
    end
    function object:stop()
      self.enabled = false
      return self
    end
    function object:isEnabled()
      return self.enabled == true
    end
    function object:show()
      self.visible = true
      return self
    end
    function object:hide()
      self.visible = false
      return self
    end
    function object:isShowing()
      return self.visible == true
    end
    function object:delete()
      self.deleted = true
      self.visible = false
    end
    function object:frame(value)
      if value then
        self.bounds = value
        return self
      end
      return self.bounds
    end
    function object:replaceElements(value)
      self.elements = value
      local images = 0
      for _, element in ipairs(value) do
        if element.type == "image" then
          images = images + 1
        end
      end
      desktop.draws[#desktop.draws + 1] = { at = desktop.now, images = images }
      return self
    end
    function object:mouseCallback(callback)
      self.callback = callback
      return self
    end
    return object
  end
  local function owner(pid)
    for _, window in ipairs(desktop.windows) do
      if window.pid == pid then
        return window
      end
    end
  end
  local function hidden(pid)
    return (owner(pid) or {})["is-hidden"]
  end
  -- `desktop.tracked`: windows lib.window_filter admitted (minimizable dialogs).
  local filter = {
    blacklist = { AXDialog = true, AXSystemDialog = true, AXFloatingWindow = true },
    new = function()
      local object = chainObject()
      object.subscriptions = {}
      function object:getWindow(id, pid)
        local window = desktop.tracked[id]
        if window and window:application():pid() == pid then
          return window
        end
      end
      function object:delete()
        self.subscriptions = {}
      end
      return object
    end,
    windowFocused = "windowFocused",
    windowDestroyed = "windowDestroyed",
    windowCreated = "windowCreated",
    windowMoved = "windowMoved",
    windowTitleChanged = "windowTitleChanged",
    windowMinimized = "windowMinimized",
    windowUnminimized = "windowUnminimized",
    windowHidden = "windowHidden",
    windowUnhidden = "windowUnhidden",
  }
  local function unhide(pid)
    desktop.unhides = desktop.unhides + 1
    if options.unhideFailure then
      return nil, "Accessibility request rejected"
    end
    local function complete()
      for _, window in ipairs(desktop.windows) do
        if window.pid == pid then
          window["is-hidden"] = false
        end
      end
      if options.unhideDelay or options.unhideSynchronous then
        desktop:applicationEvent("unhidden", pid)
      end
    end
    if not options.unhideNever then
      if options.unhideDelay then
        timer(options.unhideDelay, complete)
      else
        complete()
      end
    end
    return true
  end
  -- hs.ipc's print raises while a dead CLI is registered; hs.printf calls print.
  local function log(message)
    if desktop.printRaises then
      desktop.raisedPrints = desktop.raisedPrints + 1
      error("ipc port is no longer valid")
    end
    desktop.logs[#desktop.logs + 1] = message
  end
  local hsMock = {
    configdir = "/config",
    timer = {
      doAfter = function(delay, callback)
        return timer(delay, callback)
      end,
      doEvery = function()
        error("Window and Space switching must not use repeating polling")
      end,
      secondsSinceEpoch = function()
        return desktop.now
      end,
    },
    eventtap = {
      event = { types = types, properties = propertyCodes },
      new = function(_, callback)
        local object = chainObject()
        object.callback = callback
        return object
      end,
    },
    keycodes = { map = keys },
    canvas = { new = chainObject },
    -- `screen` is the focused Space's display; `mainScreen` can lag on another one.
    screen = {
      mainScreen = function()
        return {
          frame = function()
            return copy(
              options.mainScreen or options.screen or { x = 0, y = -1080, w = 1920, h = 1080 }
            )
          end,
        }
      end,
      find = function(uuid)
        return uuid == "focused"
            and {
              frame = function()
                return copy(options.screen or { x = 0, y = -1080, w = 1920, h = 1080 })
              end,
            }
          or nil
      end,
    },
    spaces = {
      focusedSpace = function()
        return 1
      end,
      spaceDisplay = function(space)
        assertEqual(space, 1)
        if desktop.displayMissing then
          return nil, "space not found in managed displays"
        end
        return "focused"
      end,
    },
    mouse = {
      absolutePosition = function()
        return copy(desktop.pointer or { x = 0, y = 0 })
      end,
    },
    screenRecordingState = function()
      return options.previews == true
    end,
    image = {
      imageFromPath = function(path)
        return { path = path }
      end,
      imageFromAppBundle = function(bundle)
        return options.icons and { bundle = bundle } or nil
      end,
    },
    application = {
      watcher = {
        unhidden = 1,
        terminated = 2,
        new = function(callback)
          local watcher = chainObject()
          watcher.callback = callback
          desktop.applications[#desktop.applications + 1] = watcher
          return watcher
        end,
      },
      applicationForPID = function(pid)
        local window = owner(pid)
        if not window or window.exited then
          return nil
        end
        return {
          pid = function()
            return pid
          end,
          name = function()
            return (owner(pid) or {}).app
          end,
          bundleID = function()
            return options.icons and ((owner(pid) or {}).bundle or ("test.app." .. pid)) or nil
          end,
          isHidden = function()
            return hidden(pid)
          end,
          unhide = function()
            unhide(pid)
            return not hidden(pid)
          end,
        }
      end,
    },
    window = {
      _orderedwinids = function()
        return copy(options.order or {})
      end,
      focusedWindow = function()
        for _, row in ipairs(desktop.windows) do
          if row["has-focus"] then
            return desktop:window(row)
          end
        end
      end,
    },
    axuielement = {
      applicationElement = function(app)
        return {
          setAttributeValue = function(_, attribute, value)
            assertEqual(attribute, "AXHidden")
            assertEqual(value, false)
            return unhide(app:pid())
          end,
        }
      end,
      windowElement = function(window)
        return {
          attributeValue = function(_, name)
            assert(name == "AXParent")
            return {
              attributeValue = function()
                return window.root and "AXApplication" or "AXWindow"
              end,
            }
          end,
        }
      end,
    },
    printf = function(format, ...)
      return log(string.format(format, ...))
    end,
    alert = {
      show = function(message)
        desktop.alerts[#desktop.alerts + 1] = message
      end,
    },
  }
  desktop.hs = hsMock
  local environment = setmetatable({
    hs = hsMock,
    print = log,
  }, { __index = _G })
  local modules = {
    ["lib.window_filter"] = filter,
    ["lib.previews"] = {
      capture = function(windows, done)
        local capture = { windows = copy(windows), done = done, at = desktop.now }
        desktop.captures[#desktop.captures + 1] = capture
        if desktop.captureError then
          error("capture could not start")
        end
        return function()
          capture.cancelled = true
        end
      end,
    },
    ["lib.window_manager"] = windowManager,
  }
  environment.require = function(name)
    if not modules[name] then
      modules[name] = assert(
        loadfile(root .. "/" .. name:gsub("^lib%.", ""):gsub("%.", "/") .. ".lua", "t", environment)
      )()
    end
    return modules[name]
  end
  desktop.menu = environment.require("lib.window_switcher")
  function desktop:applicationEvent(event, pid)
    for _, watcher in ipairs(self.applications) do
      if watcher.enabled then
        watcher.callback(
          nil,
          self.hs.application.watcher[event],
          self.hs.application.applicationForPID(pid)
        )
      end
    end
  end
  function desktop:window(row)
    local window = {
      root = row["root-window"],
      id = function()
        return row.id
      end,
      title = function()
        return row.title
      end,
      isStandard = function()
        return row.subrole == "AXStandardWindow"
      end,
      isMinimized = function()
        return row["is-minimized"]
      end,
      application = function()
        if row.exited then
          return nil
        end
        return {
          pid = function()
            return row.pid
          end,
          name = function()
            return row.app
          end,
          bundleID = function()
            return options.icons and (row.bundle or ("test.app." .. row.pid)) or nil
          end,
          isHidden = function()
            return row["is-hidden"]
          end,
        }
      end,
    }
    return window
  end
  function desktop:notify(event, row)
    local callback = self.menu.windows.subscriptions[event]
    if callback then
      callback(self:window(row), row.app, event, row.id)
    end
  end
  function desktop:create(id, changes)
    local row = copy(self.windows[1])
    row.id, row.pid, row.title = id, 100 + id, "New window " .. id
    row["has-focus"] = false
    for key, value in pairs(changes or {}) do
      row[key] = value
    end
    self.windows[id] = row
    self:notify("windowCreated", row)
    return row
  end
  function desktop:event(kind, key, flags, point, properties)
    return {
      getType = function()
        return types[kind]
      end,
      getKeyCode = function()
        return keys[key]
      end,
      getFlags = function()
        return flags or {}
      end,
      location = function()
        return point
      end,
      getProperty = function(_, property)
        return (properties or {})[property] or 0
      end,
    }
  end
  function desktop:key(kind, key, flags)
    return self.menu.tap.callback(self:event(kind, key, flags))
  end
  function desktop:open()
    self:key("keyDown", "tab", { cmd = true })
    self:advance(0.35)
    assert(self.menu.status().visible, "menu should be visible")
  end
  function desktop:current()
    return upvalue(self.menu.mouseTap.callback, "cycle")
  end
  function desktop:move(x, y)
    local frame = self.menu.canvas:frame()
    local point = { x = frame.x + x, y = frame.y + y }
    self.pointer = point
    local result = self.menu.mouseTap.callback(self:event("mouseMoved", nil, nil, point))
    self:advance(0)
    return result
  end
  function desktop:scroll(delta, x, y)
    local frame = self.menu.canvas:frame()
    local point = { x = frame.x + (x or 20), y = frame.y + (y or 20) }
    local result = self.menu.mouseTap.callback(
      self:event("scrollWheel", nil, nil, point, { [1] = 1, [2] = delta })
    )
    self:advance(0)
    return result
  end
  function desktop:preview(index, id, err)
    self.captures[index].done(id, not err and {
      batch = index,
      size = function()
        return { w = 230, h = 130 }
      end,
    } or nil, err)
  end
  function desktop:complete(index, missing, err)
    local capture = self.captures[index]
    for _, window in ipairs(capture.windows) do
      if window.id == missing then
        capture.done(window.id, nil, err)
      else
        self:preview(index, window.id)
      end
    end
    capture.done(nil, nil, nil)
    self:advance(0)
  end
  function desktop:release()
    self:key("flagsChanged", nil, {})
  end
  function desktop:select(index)
    local c = assert(self:current())
    local card
    for _, candidate in ipairs(c.cards) do
      if candidate.index == index then
        card = candidate
      end
    end
    assert(card, "card unavailable")
    self:move(card.x + card.w / 2, card.y + card.h / 2)
  end
  function desktop:click(x, y)
    assert(self:current())
    local id
    for i = #self.menu.canvas.elements, 1, -1 do
      local element = self.menu.canvas.elements[i]
      if element.trackMouseUp then
        local frame = element.frame
        if x >= frame.x and x < frame.x + frame.w and y >= frame.y and y < frame.y + frame.h then
          id = element.id
          break
        end
      end
    end
    if id then
      self.menu.canvas.callback(self.menu.canvas, "mouseUp", id, x, y)
    end
  end
  return desktop
end

test("visible previews are prioritized without per-window timers or polling", function()
  local desktop = harness({ previews = true, count = 7 })
  desktop:open()
  assertEqual(#desktop.captures, 1)
  assertEqual(desktop.captures[1].at, 0.2)
  assertEqual(#desktop.captures[1].windows, 7)
  assertEqual(#desktop.draws, 1)
  assertEqual(desktop.draws[1].images, 0)
  desktop:complete(1)
  assertEqual(#desktop.draws, 2)
  assertEqual(desktop.draws[2].images, 7)
  desktop:advance(10)
  assertEqual(#desktop.captures, 1, "no polling or recapture")
  assertEqual(#desktop.draws, 2)
end)

test("preview capture is skipped without permission or for quick switching", function()
  local desktop = harness()
  desktop:open()
  assertEqual(#desktop.captures, 0)
  desktop = harness({ previews = true })
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:advance(0.01)
  desktop:release()
  desktop:advance(0.5)
  assertEqual(#desktop.captures, 0)
end)

test("keyboard remains responsive while previews are pending", function()
  local desktop = harness({ previews = true })
  desktop:open()
  local selected = assert(desktop:current()).selected
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:advance(0)
  assertEqual(assert(desktop:current()).selected, selected + 1)
  assertEqual(#desktop.captures, 2)
  assertEqual(desktop.captures[1].cancelled, true)
  assertEqual(desktop.captures[2].windows[1].id, selected + 1)
  desktop:complete(1)
  assertEqual(assert(desktop:current()).selected, selected + 1)
end)

test("cancelled previews cannot redraw or seed a newer menu", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:key("keyDown", "escape", { cmd = true })
  assertEqual(desktop.captures[1].cancelled, true)
  local draws = #desktop.draws
  desktop:complete(1)
  assertEqual(#desktop.draws, draws)
  assertEqual(desktop.menu.status().visible, false)
  desktop:open()
  assertEqual(desktop.draws[#desktop.draws].images, 0)
  desktop:complete(2)
  assertEqual(desktop.draws[#desktop.draws].images, 9)
end)

test("release and shutdown cancel pending previews", function()
  for _, action in ipairs({ "release", "stop" }) do
    local desktop = harness({ previews = true })
    desktop:open()
    if action == "release" then
      desktop:release()
    else
      desktop.menu.stop()
    end
    assertEqual(desktop.captures[1].cancelled, true)
    local draws = #desktop.draws
    desktop:complete(1)
    assertEqual(#desktop.draws, draws)
    assertEqual(desktop.menu.status().visible, false)
  end
end)

test("cached previews stay visible when fresh capture fails silently", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:complete(1)
  desktop:key("keyDown", "escape", { cmd = true })
  desktop:open()
  assertEqual(desktop.draws[#desktop.draws].images, 9)
  desktop:complete(2, 1, "capture failed")
  assertEqual(assert(desktop:current()).images[1].batch, 1)
  assertEqual(assert(desktop:current()).images[2].batch, 2)
  desktop:advance(10)
  assertEqual(#desktop.captures, 2)
  assertEqual(#desktop.alerts, 0)
  assertEqual(#desktop.logs, 0)
end)

test("missing previews silently use icons for every window state", function()
  for _, state in ipairs({
    {},
    { ["is-minimized"] = true },
    { ["is-hidden"] = true },
    { ["is-minimized"] = true, ["is-hidden"] = true },
  }) do
    local desktop = harness({ previews = true, icons = true })
    for key, value in pairs(state) do
      desktop.windows[2][key] = value
    end
    desktop:open()
    local skipped = state["is-minimized"] or state["is-hidden"]
    assertEqual(#desktop.captures[1].windows, skipped and 8 or 9)
    assertEqual(desktop.captures[1].windows[1].id, skipped and 1 or 2)
    desktop:complete(1, 2, "could not capture window: 2")
    assertEqual(desktop.menu.status().selected, 2)
    assertEqual(desktop.menu.status().windows[2].preview, false)
    local icon
    for _, element in ipairs(desktop.menu.canvas.elements) do
      if element.image and element.image.bundle == "test.app.102" and element.frame.w == 52 then
        icon = element
      end
    end
    assert(icon, "missing preview must retain the app icon")
    desktop:advance(10)
    assertEqual(#desktop.captures, 1, "no polling or retries")
    assertEqual(#desktop.alerts, 0)
    assertEqual(#desktop.logs, 0)
    desktop:release()
    desktop:advance(1)
    assertEqual(desktop.windows[2]["is-minimized"], false)
    assertEqual(desktop.windows[2]["has-focus"], true)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("minimized and hidden windows reuse cached previews until restored", function()
  for state, event in pairs({
    ["is-minimized"] = "windowUnminimized",
    ["is-hidden"] = "windowUnhidden",
  }) do
    local desktop = harness({ previews = true })
    desktop:open()
    desktop:complete(1)
    desktop:key("keyDown", "escape", {})
    desktop.windows[2][state] = true
    for batch = 2, 3 do
      desktop:open()
      assertEqual(#desktop.captures[batch].windows, 8)
      for _, window in ipairs(desktop.captures[batch].windows) do
        assert(window.id ~= 2, "minimized or hidden window must use its cached preview")
      end
      desktop:complete(batch)
      assertEqual(desktop:current().images[2].batch, 1)
      assertEqual(desktop:current().images[1].batch, batch)
      for _, change in ipairs({ "windowTitleChanged", "windowMoved" }) do
        desktop:notify(change, desktop.windows[2])
        desktop:advance(0)
      end
      assertEqual(
        #desktop.captures,
        batch,
        "other events cannot recapture minimized or hidden windows"
      )
      if batch == 2 then
        desktop:key("keyDown", "escape", {})
      end
    end
    desktop.windows[2][state] = false
    desktop:notify(event, desktop.windows[2])
    desktop:advance(0)
    assertEqual(#desktop.captures[4].windows, 1)
    assertEqual(desktop.captures[4].windows[1].id, 2)
    desktop:complete(4)
    assertEqual(desktop:current().images[2].batch, 4)
    assertEqual(#desktop.alerts, 0)
    assertEqual(#desktop.logs, 0)
  end
end)

test("minimizing during capture discards stale results without preview errors", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:preview(1, 1)
  desktop.windows[2]["is-minimized"] = true
  desktop:notify("windowMinimized", desktop.windows[2])
  desktop:advance(0)
  assertEqual(desktop.captures[1].cancelled, nil)
  assertEqual(#desktop.captures[2].windows, 1)
  assertEqual(desktop.captures[2].windows[1].id, 2)
  desktop:complete(2)
  desktop:complete(1)
  assertEqual(desktop:current().images[1].batch, 1)
  assertEqual(
    desktop:current().images[2].batch,
    2,
    "late menu image cannot overwrite final capture"
  )
  assertEqual(desktop:current().images[3].batch, 1)
  assertEqual(#desktop.alerts, 0)
  assertEqual(#desktop.logs, 0)
end)

test("menus containing only minimized and hidden windows never request captures", function()
  local desktop = harness({ previews = true, icons = true, count = 100 })
  for _, window in ipairs(desktop.windows) do
    window[window.id % 2 == 0 and "is-minimized" or "is-hidden"] = true
  end
  for _ = 1, 2 do
    desktop:open()
    for _, window in ipairs(desktop.menu.status().windows) do
      assertEqual(window.preview, false)
      assert(window.minimized or window.hidden)
    end
    desktop:key("keyDown", "tab", { cmd = true })
    desktop:advance(0)
    desktop:scroll(-10000)
    desktop:advance(10)
    assertEqual(#desktop.captures, 0)
    desktop:key("keyDown", "escape", {})
  end
  assertEqual(#desktop.alerts, 0)
  assertEqual(#desktop.logs, 0)
end)

test("capture startup errors silently preserve cached images or icons without retrying", function()
  for _, cached in ipairs({ false, true }) do
    local desktop = harness({ previews = true, icons = true })
    if cached then
      desktop:open()
      desktop:complete(1)
      desktop:key("keyDown", "escape", {})
    end
    desktop.captureError = true
    desktop:open()
    assertEqual(desktop:current().capture, nil)
    for _, window in ipairs(desktop.menu.status().windows) do
      assertEqual(window.preview, cached)
    end
    local previews = 0
    for _, element in ipairs(desktop.menu.canvas.elements) do
      if element.image and (element.image.batch or element.frame.w == 52) then
        previews = previews + 1
      end
    end
    assertEqual(previews, 9)
    desktop:key("keyDown", "tab", { cmd = true })
    desktop:advance(10)
    assertEqual(#desktop.captures, cached and 2 or 1)
    assertEqual(#desktop.alerts, 0)
    assertEqual(#desktop.logs, 0)
    desktop:release()
    desktop:advance(1)
    assertEqual(desktop.windows[3]["has-focus"], true)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("reused window IDs cannot reuse another process's cached preview", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:complete(1)
  desktop:key("keyDown", "escape", { cmd = true })
  desktop.windows[1].pid = 9876
  desktop:open()
  assertEqual(assert(desktop:current()).images[1], nil)
  assertEqual(desktop.draws[#desktop.draws].images, 8)
end)

test("reused process IDs show the new application's icon", function()
  local desktop = harness({ icons = true })
  desktop:open()
  desktop:key("keyDown", "escape", {})
  desktop.windows[2].app, desktop.windows[2].bundle = "Other", "test.app.other"
  desktop:open()
  local bundles = {}
  for _, element in ipairs(desktop.menu.canvas.elements) do
    if element.image and element.image.bundle then
      bundles[element.image.bundle] = true
    end
  end
  assertEqual(bundles["test.app.102"], nil, "exited application's icon")
  assertEqual(bundles["test.app.other"], true, "new application's icon")
end)

test("destroyed windows cannot repopulate the preview cache", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:notify("windowDestroyed", desktop.windows[1])
  desktop:complete(1)
  assertEqual(assert(desktop:current()).images[1], nil)
  desktop:key("keyDown", "escape", { cmd = true })
  desktop:open()
  assertEqual(assert(desktop:current()).images[1], nil)
end)

test("progressive previews draw before the batch finishes and coalesce callbacks", function()
  local desktop = harness({ previews = true, count = 7 })
  desktop:open()
  assertEqual(desktop.captures[1].windows[1].id, 2, "selected window is captured first")
  desktop:preview(1, 2)
  desktop:preview(1, 3)
  desktop:advance(0)
  assertEqual(desktop.draws[#desktop.draws].images, 2)
  assertEqual(#desktop.draws, 2, "one render for both completions")
  assertEqual(#desktop.captures, 1)
  assert(desktop:current().capture, "batch is still running")
  desktop:complete(1)
  assertEqual(desktop.draws[#desktop.draws].images, 7)
end)

test("100 windows capture only the current viewport and reprioritize on scroll", function()
  local desktop = harness({ previews = true, count = 100 })
  desktop:open()
  local current = assert(desktop:current())
  assert(#desktop.captures[1].windows <= #current.cards + 1)
  assert(#desktop.captures[1].windows < 100)
  desktop:preview(1, 2)
  desktop:advance(0)
  desktop:scroll(-100000)
  assertEqual(desktop.captures[1].cancelled, true)
  local request = desktop.captures[2]
  local wanted = {}
  for _, card in ipairs(desktop:current().cards) do
    if card.h > 0 then
      wanted[desktop:current().windows[card.index].id] = true
    end
  end
  for _, window in ipairs(request.windows) do
    assert(wanted[window.id], "offscreen queued work survived scrolling")
    assert(window.id ~= 2, "completed selected thumbnail was captured again")
  end
  desktop:select(100)
  assertEqual(request.cancelled, true)
  assertEqual(desktop.captures[3].windows[1].id, 100)
  desktop:complete(1)
  desktop:complete(2)
  assertEqual(desktop:current().images[100], nil, "cancelled results are discarded")
  desktop:complete(3)
  assertEqual(desktop:current().images[2].batch, 1, "earlier completed thumbnail stays cached")
  assertEqual(desktop:current().images[100].batch, 3)
  desktop:advance(10)
  assertEqual(#desktop.captures, 3, "no polling")
end)

test("all 100 thumbnails remain cached while fresh work stays limited to visible cards", function()
  local desktop = harness({ previews = true, count = 100 })
  desktop:open()
  desktop:complete(1)
  desktop:key("keyDown", "left", {})
  desktop:advance(0)
  for _ = 2, 100 do
    desktop:key("keyDown", "right", {})
    desktop:advance(0)
    if desktop:current().capture then
      desktop:complete(#desktop.captures)
    end
  end
  desktop:key("keyDown", "escape", {})
  desktop:open()
  local cached = 0
  for _ in pairs(desktop:current().images) do
    cached = cached + 1
  end
  assertEqual(cached, 100)
  assert(#desktop.captures[#desktop.captures].windows < 100)
  for _, card in ipairs(desktop:current().cards) do
    assert(desktop:current().images[desktop:current().windows[card.index].id])
  end
end)

test("window events refresh visible thumbnails and state without polling", function()
  local desktop = harness({ previews = true, count = 100 })
  desktop:open()
  desktop:complete(1)
  desktop.windows[2]["is-minimized"] = true
  desktop:notify("windowMinimized", desktop.windows[2])
  desktop:advance(0)
  assertEqual(#desktop.captures, 2)
  assertEqual(#desktop.captures[2].windows, 1)
  assertEqual(desktop.captures[2].windows[1].id, 2)
  assertEqual(desktop.menu.status().windows[2].minimized, true)
  assertEqual(desktop:current().images[2].batch, 1)
  desktop:complete(2)
  assertEqual(desktop:current().images[2].batch, 2)
  desktop.windows[100].title = "Changed offscreen"
  desktop:notify("windowTitleChanged", desktop.windows[100])
  desktop:advance(0)
  assertEqual(#desktop.captures, 2)
  desktop:notify("windowMoved", desktop.windows[3])
  desktop:advance(0)
  assertEqual(#desktop.captures[3].windows, 1)
  assertEqual(desktop.captures[3].windows[1].id, 3)
  desktop:key("keyDown", "escape", {})
  desktop:notify("windowMoved", desktop.windows[2])
  desktop:advance(10)
  assertEqual(#desktop.captures, 3, "idle events never start captures")
end)

test("minimize and hide events cache one image while the menu is closed", function()
  for _, event in ipairs({ "windowMinimized", "windowHidden" }) do
    local desktop = harness({ previews = true })
    desktop.windows[2][event == "windowMinimized" and "is-minimized" or "is-hidden"] = true
    desktop:notify(event, desktop.windows[2])
    assertEqual(#desktop.captures, 1)
    assertEqual(#desktop.captures[1].windows, 1)
    assertEqual(desktop.captures[1].windows[1].id, 2)
    assertEqual(#desktop.timers, 0, "state capture starts immediately without timers")
    assertEqual(#desktop.commands, 0, "event identity needs no window query")
    desktop:complete(1)
    assertEqual(desktop.menu.status().visible, false)
    assertEqual(#desktop.draws, 0)
    desktop:advance(3600)
    assertEqual(#desktop.captures, 1)
    desktop:open()
    assertEqual(desktop:current().images[2].batch, 1)
    desktop:complete(2)
    assertEqual(desktop:current().images[2].batch, 1, "menu keeps the final snapshot")
    assertEqual(#desktop.alerts, 0)
    assertEqual(#desktop.logs, 0)
  end
end)

test("state capture survives closing the menu and is shared with the next invocation", function()
  for _, event in ipairs({ "windowMinimized", "windowHidden" }) do
    local desktop = harness({ previews = true })
    desktop:open()
    desktop:complete(1)
    desktop.windows[2][event == "windowMinimized" and "is-minimized" or "is-hidden"] = true
    desktop:notify(event, desktop.windows[2])
    desktop:advance(0)
    assertEqual(#desktop.captures, 2)
    assertEqual(desktop:current().images[2].batch, 1)
    desktop:key("keyDown", "escape", {})
    assertEqual(desktop.captures[2].cancelled, nil)
    desktop:open()
    for _, window in ipairs(desktop.captures[3].windows) do
      assert(window.id ~= 2, "menu must reuse the in-flight final capture")
    end
    desktop:complete(2)
    desktop:complete(3)
    assertEqual(desktop:current().images[2].batch, 2)
    assertEqual(#desktop.captures, 3, "final delivery cannot trigger another capture")
  end
end)

test("state capture failures preserve existing cache or icons silently", function()
  for _, cached in ipairs({ false, true }) do
    for _, startup in ipairs({ false, true }) do
      local desktop = harness({ previews = true, icons = true })
      if cached then
        desktop:open()
        desktop:complete(1)
        desktop:key("keyDown", "escape", {})
      end
      desktop.captureError = startup
      desktop.windows[2]["is-minimized"] = true
      desktop:notify("windowMinimized", desktop.windows[2])
      if not startup then
        desktop:complete(#desktop.captures, 2, "no surface")
      end
      desktop:advance(60)
      assertEqual(#desktop.captures, cached and 2 or 1)
      desktop.captureError = false
      desktop:open()
      desktop:complete(#desktop.captures)
      assertEqual(desktop.menu.status().windows[2].preview, cached)
      if cached then
        assertEqual(desktop:current().images[2].batch, 1)
      end
      assertEqual(#desktop.alerts, 0)
      assertEqual(#desktop.logs, 0)
    end
  end
end)

test("restoring or unhiding resumes fresh captures while the final snapshot is pending", function()
  for state, event in pairs({
    ["is-minimized"] = "windowUnminimized",
    ["is-hidden"] = "windowUnhidden",
  }) do
    for _, open in ipairs({ false, true }) do
      local desktop = harness({ previews = true })
      desktop.windows[2][state] = true
      desktop:notify(
        state == "is-minimized" and "windowMinimized" or "windowHidden",
        desktop.windows[2]
      )
      if open then
        desktop:open()
        desktop:complete(2)
      end
      desktop.windows[2][state] = false
      desktop:notify(event, desktop.windows[2])
      if open then
        desktop:advance(0)
      else
        desktop:open()
      end
      assertEqual(
        desktop.captures[1].cancelled,
        true,
        "restoration supersedes the pending final snapshot"
      )
      local batch = open and 3 or 2
      assertEqual(desktop.captures[batch].windows[1].id, 2)
      desktop:complete(batch)
      desktop:complete(1)
      assertEqual(
        desktop:current().images[2].batch,
        batch,
        "late final snapshot cannot replace the fresh image"
      )
      assertEqual(#desktop.alerts, 0)
      assertEqual(#desktop.logs, 0)
    end
  end
end)

test("restoring or unhiding does not recapture while the other state remains", function()
  for state, event in pairs({
    ["is-minimized"] = "windowUnminimized",
    ["is-hidden"] = "windowUnhidden",
  }) do
    local desktop = harness({ previews = true, count = 1 })
    desktop.windows[1]["is-minimized"], desktop.windows[1]["is-hidden"] = true, true
    desktop:open()
    desktop.windows[1][state] = false
    desktop:notify(event, desktop.windows[1])
    desktop:advance(0)
    assertEqual(#desktop.captures, 0)
    desktop.windows[1]["is-minimized"], desktop.windows[1]["is-hidden"] = false, false
    desktop:notify(
      state == "is-minimized" and "windowUnhidden" or "windowUnminimized",
      desktop.windows[1]
    )
    desktop:advance(0)
    assertEqual(#desktop.captures, 1)
    desktop:complete(1)
    assertEqual(desktop:current().images[1].batch, 1)
  end
end)

test("new state events supersede pending captures without accepting stale results", function()
  local desktop = harness({ previews = true })
  desktop:notify("windowMinimized", desktop.windows[2])
  desktop:notify("windowHidden", desktop.windows[2])
  assertEqual(desktop.captures[1].cancelled, true)
  desktop:complete(2)
  desktop:complete(1)
  desktop:open()
  assertEqual(desktop:current().images[2].batch, 2)
end)

test("destroyed windows cannot be cached by a late state capture", function()
  local desktop = harness({ previews = true })
  desktop:notify("windowHidden", desktop.windows[2])
  desktop:notify("windowDestroyed", desktop.windows[2])
  assertEqual(desktop.captures[1].cancelled, true)
  desktop:complete(1)
  desktop:create(2)
  desktop:open()
  assertEqual(desktop:current().images[2], nil)
end)

test("window query cancels missing or reused identities with pending state captures", function()
  for _, change in ipairs({ "missing", "reused" }) do
    local desktop = harness({ previews = true })
    desktop:notify("windowHidden", desktop.windows[2])
    if change == "missing" then
      table.remove(desktop.windows, 2)
    else
      desktop.windows[2].pid = 9999
    end
    desktop:open()
    assertEqual(desktop.captures[1].cancelled, true)
    desktop:complete(1)
    assertEqual(desktop:current().images[2], nil)
  end
end)

test("shutdown cancels pending state captures and ignores their late results", function()
  local desktop = harness({ previews = true })
  desktop:notify("windowHidden", desktop.windows[2])
  desktop:notify("windowMinimized", desktop.windows[3])
  desktop.menu.stop()
  assertEqual(desktop.captures[1].cancelled, true)
  assertEqual(desktop.captures[2].cancelled, true)
  desktop:complete(1)
  desktop:complete(2)
  assertEqual(#desktop.draws, 0)
  assertEqual(#desktop.alerts, 0)
  assertEqual(#desktop.logs, 0)
end)

test("other idle events and missing screen permission never capture", function()
  local desktop = harness({ previews = true })
  for _, event in ipairs({
    "windowMoved",
    "windowTitleChanged",
    "windowUnminimized",
    "windowUnhidden",
  }) do
    desktop:notify(event, desktop.windows[2])
  end
  assertEqual(#desktop.captures, 0)
  desktop = harness()
  desktop:notify("windowMinimized", desktop.windows[2])
  desktop:notify("windowHidden", desktop.windows[2])
  assertEqual(#desktop.captures, 0)
  assertEqual(#desktop.alerts, 0)
  assertEqual(#desktop.logs, 0)
end)

test("multiple progressive failures stay silent without retries", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:preview(1, 2, "first capture failed")
  desktop:preview(1, 3, "second capture failed")
  desktop:advance(0)
  assertEqual(#desktop.alerts, 0)
  assertEqual(#desktop.logs, 0)
  assertEqual(#desktop.captures, 1)
  desktop:advance(10)
  assertEqual(#desktop.captures, 1)
end)

test("rows balance their window counts and remain centered", function()
  for _, counts in ipairs({ { 4, 3 }, { 4, 4 }, { 5, 4 }, { 5, 4, 4 }, { 6, 6, 6 } }) do
    local total = 0
    for _, count in ipairs(counts) do
      total = total + count
    end
    local desktop = harness({ count = total })
    desktop:open()
    local current = assert(desktop:current())
    local rows = {}
    for _, card in ipairs(current.cards) do
      local row = rows[#rows]
      if not row or row.y ~= card.y then
        row = { y = card.y, count = 0, left = card.x }
        rows[#rows + 1] = row
      end
      row.count = row.count + 1
      row.right = card.x + card.w
    end
    assertEqual(#rows, #counts)
    for index, row in ipairs(rows) do
      assertEqual(row.count, counts[index], "windows in row " .. index)
      assert(math.abs(row.left - (current.frame.w - row.right)) < 1e-6, "row is not centered")
    end
  end
end)
test("keyboard reveals every window across balanced scrolling rows", function()
  for _, count in ipairs({ 49, 61, 73, 100 }) do
    local desktop = harness({ count = count })
    desktop:open()
    desktop:key("keyDown", "left", {})
    desktop:advance(0)
    for index = 1, count do
      assertEqual(desktop.menu.status().selected, index)
      local hit, frame
      for _, card in ipairs(assert(desktop:current()).cards) do
        if card.index == index then
          hit = card
        end
      end
      for _, element in ipairs(desktop.menu.canvas.elements) do
        if element.id == "window-" .. index then
          frame = element.frame
        end
      end
      assert(hit and frame and math.abs(hit.h - frame.h) < 1e-6, "selected card is clipped")
      desktop:key("keyDown", "right", {})
      desktop:advance(0)
    end
    assertEqual(desktop.menu.status().selected, 1, "wrap to first window")
    assertEqual(assert(desktop:current()).scrollOffset, 0, "first row is revealed")
    desktop:key("keyDown", "left", {})
    desktop:advance(0)
    assertEqual(desktop.menu.status().selected, count, "wrap to final window")
    assertEqual(
      assert(desktop:current()).scrollOffset,
      assert(desktop:current()).maxScroll,
      "last row is revealed"
    )
  end
end)
test("responsive grids stay bounded and pointer targets match on varied displays", function()
  for _, count in ipairs({ 1, 8, 24, 100, 250 }) do
    for _, screen in ipairs({
      { x = 0, y = 33, w = 1710, h = 1074 },
      { x = -429, y = -1440, w = 2560, h = 1440 },
      { x = 1710, y = 0, w = 3840, h = 2160 },
      { x = -3440, y = 0, w = 3440, h = 1440 },
      { x = 0, y = 0, w = 5120, h = 1440 },
      { x = 0, y = 0, w = 1280, h = 720 },
      { x = -1080, y = -1920, w = 1080, h = 1920 },
      { x = 0, y = 0, w = 1440, h = 2560 },
      { x = 0, y = 0, w = 1024, h = 600 },
      { x = -1280, y = 0, w = 1280, h = 360 },
      { x = 0, y = 0, w = 320, h = 240 },
    }) do
      local desktop = harness({ count = count, previews = true, screen = screen })
      desktop.windows[1]["is-minimized"] = true
      desktop:open()
      if desktop:current().capture then
        desktop:complete(1)
      end
      local current = assert(desktop:current())
      local frame = current.frame
      assert(frame.w <= screen.w * 0.85 and frame.h <= screen.h * 0.85, "menu exceeds display")
      near(frame.x + frame.w / 2, screen.x + screen.w / 2, "horizontal center")
      near(frame.y + frame.h / 2, screen.y + screen.h / 2, "vertical center")
      assert(current.cards[1].w >= 180 and current.cards[1].w <= 320, "unbounded preview")
      for _, element in ipairs(desktop.menu.canvas.elements) do
        if element.id == "state-1" then
          assertEqual(element.frame.w, 24, "status icon stays readable")
          assertEqual(element.frame.h, 24)
        elseif element.textSize then
          assertEqual(element.textSize, 11, "labels stay readable")
        end
      end
      for _, card in ipairs(current.cards) do
        assert(card.h > 0, "fully clipped card has a hit target")
        assert(card.x >= 16 and card.x + card.w <= frame.w - 16)
        assert(card.y >= 16 and card.y + card.h <= frame.h - 16)
      end
      local last = current.cards[#current.cards]
      desktop:select(last.index)
      assertEqual(desktop.menu.status().selected, last.index, "hover target")
      desktop:click(frame.w - 1, frame.h - 1)
      desktop:advance(0.15)
      assertEqual(desktop.windows[last.index]["has-focus"], true, "click target")
      assertEqual(#desktop.alerts, 0)
    end
  end
end)
test("width adds columns and height adds rows without oversized previews", function()
  local function grid(width, height)
    local desktop = harness({ count = 250, screen = { x = 0, y = 0, w = width, h = height } })
    desktop:open()
    return assert(desktop:current()).layout
  end
  local base = grid(2560, 1440)
  local wide = grid(5120, 1440)
  local tall = grid(2560, 2160)
  assert(wide.columns > base.columns and wide.shown > base.shown, "width must add capacity")
  assert(tall.rows > base.rows and tall.shown > base.shown, "height must add capacity")
  assert(wide.size <= 320 and tall.size <= 320)
  local previous
  for width = 640, 5120, 160 do
    local current = grid(width, 1080)
    assert(not previous or current.shown >= previous, "more width reduced capacity")
    previous = current.shown
  end
  previous = nil
  for height = 360, 2160, 90 do
    local current = grid(1920, height)
    assert(not previous or current.shown >= previous, "more height reduced capacity")
    previous = current.shown
  end
end)
test("previews shrink within bounds to avoid unnecessary scrolling", function()
  local desktop = harness({ count = 24, screen = { x = 0, y = 33, w = 1710, h = 1074 } })
  desktop:open()
  local current = assert(desktop:current())
  assertEqual(#current.cards, 24)
  assertEqual(current.maxScroll, 0)
  assert(current.cards[1].w < 246 and current.cards[1].w >= 180)
  local crowded = harness({ count = 100, screen = { x = 0, y = 33, w = 1710, h = 1074 } })
  crowded:open()
  current = assert(crowded:current())
  assert(
    current.maxScroll > 0 and current.cards[1].w >= 180,
    "scroll before previews get too small"
  )
end)
test("layout is reused for selection and recalculated when windows change", function()
  local desktop = harness({ count = 8 })
  desktop:open()
  local original = assert(desktop:current()).layout
  desktop:key("keyDown", "right", {})
  desktop:advance(0)
  assertEqual(assert(desktop:current()).layout, original, "selection must reuse layout")
  desktop:create(9)
  desktop:advance(0)
  local changed = assert(desktop:current()).layout
  assert(changed ~= original)
  assertEqual(changed.count, 9)
  desktop.windows[9].closed = true
  desktop:notify("windowDestroyed", desktop.windows[9])
  desktop:advance(0)
  assertEqual(assert(desktop:current()).layout.count, 8)
end)
test("scrolling uses screen points and reaches every row on short and tall displays", function()
  for _, screen in ipairs({
    { x = -429, y = -1440, w = 2560, h = 1440 },
    { x = 0, y = 0, w = 3840, h = 2160 },
    { x = 0, y = 0, w = 5120, h = 720 },
    { x = -1080, y = 0, w = 1080, h = 1920 },
    { x = -1280, y = 0, w = 1280, h = 360 },
    { x = 0, y = 0, w = 320, h = 240 },
  }) do
    local desktop = harness({ count = 250, screen = screen })
    desktop:open()
    local current = assert(desktop:current())
    assert(current.maxScroll > 37)
    local tracked = "window-" .. current.cards[1].index
    local before
    for _, element in ipairs(desktop.menu.canvas.elements) do
      if element.id == tracked then
        before = element.frame.y
      end
    end
    desktop:scroll(-37)
    local after
    for _, element in ipairs(desktop.menu.canvas.elements) do
      if element.id == tracked then
        after = element.frame.y
      end
    end
    near(before - after, 37, "trackpad distance stays in screen points")
    desktop:scroll(-100000)
    current = assert(desktop:current())
    desktop:move(current.frame.w - 1, current.frame.h - 1)
    assertEqual(desktop.menu.status().selected, 250, "last card remains reachable")
    desktop:click(current.frame.w - 1, current.frame.h - 1)
    desktop:advance(0.15)
    assertEqual(desktop.windows[250]["has-focus"], true)
  end
end)
test("ghost padding selects at all four container edges", function()
  local desktop = harness({ count = 6 })
  desktop:open()
  local current = assert(desktop:current())
  local points = {
    { 0, 0, 1 },
    { current.frame.w - 0.1, 0, 6 },
    { 0, current.frame.h - 0.1, 1 },
    { current.frame.w - 0.1, current.frame.h - 0.1, 6 },
  }
  for _, point in ipairs(points) do
    desktop:move(point[1], point[2])
    assertEqual(desktop.menu.status().selected, point[3])
  end
end)
test("horizontal and vertical gaps choose nearest card", function()
  local desktop = harness()
  desktop:open()
  local current = assert(desktop:current())
  local first, second, lower = current.cards[1], current.cards[2], current.cards[7]
  desktop:move(second.x - 1, second.y + 20)
  assertEqual(desktop.menu.status().selected, 2)
  desktop:move(first.x + first.w + 1, first.y + 20)
  assertEqual(desktop.menu.status().selected, 1)
  desktop:move(lower.x + 20, lower.y - 1)
  assertEqual(desktop.menu.status().selected, 7)
end)
test("empty cells in incomplete final row choose nearest visible card", function()
  local desktop = harness({ count = 7 })
  desktop:open()
  local current = assert(desktop:current())
  desktop:move(current.cards[7].x + current.cards[7].w + 20, current.frame.h - 1)
  assertEqual(desktop.menu.status().selected, 7)
end)
test("outside container never changes selection", function()
  local desktop = harness()
  desktop:open()
  local current = assert(desktop:current())
  desktop:select(2)
  for _, point in ipairs({
    { -0.1, 20 },
    { current.frame.w, 20 },
    { 20, -0.1 },
    { 20, current.frame.h },
    { -1000, -1000 },
    { current.frame.w + 1000, current.frame.h + 1000 },
  }) do
    desktop:move(point[1], point[2])
    assertEqual(desktop.menu.status().selected, 2)
  end
end)
test("stationary pointer preserves keyboard selection through redraws", function()
  local desktop = harness()
  desktop:open()
  local current = assert(desktop:current())
  local first = current.cards[1]
  desktop:move(first.x + 10, first.y + 10)
  assertEqual(desktop.menu.status().selected, 1)
  desktop:key("keyDown", "right", {})
  desktop:advance(0)
  desktop:move(first.x + 10, first.y + 10)
  assertEqual(desktop.menu.status().selected, 2)
end)
test("nearest-card ties preserve the selection", function()
  local desktop = harness()
  desktop:open()
  local current = assert(desktop:current())
  local first, second = current.cards[1], current.cards[2]
  desktop:select(2)
  desktop:move((first.x + first.w + second.x) / 2, first.y + 20)
  assertEqual(desktop.menu.status().selected, 2)
end)
test("clicking ghost padding accepts the same card as hover", function()
  local desktop = harness({ count = 6 })
  desktop:open()
  desktop:move(2, 2)
  desktop:click(2, 2)
  desktop:advance(0.15)
  assertEqual(desktop.menu.status().visible, false)
  assertEqual(desktop.windows[1]["has-focus"], true)
  assertEqual(#desktop.alerts, 0)
end)
test("scrolling clips targets and ignores fully hidden cards", function()
  local desktop = harness({ count = 100 })
  desktop:open()
  local current = assert(desktop:current())
  local lower = current.cards[current.layout.columns + 1]
  local step = lower.y - current.cards[1].y
  assertEqual(desktop:scroll(-(step - 4)), true)
  current = assert(desktop:current())
  desktop:move(1, 1)
  assertEqual(desktop.menu.status().selected, lower.index, "fully clipped first row")
  desktop:scroll(-100000)
  current = assert(desktop:current())
  local last = current.cards[#current.cards]
  desktop:move(last.x + last.w / 2, current.frame.h - 1)
  assertEqual(desktop.menu.status().selected, 100, "bottom padding")
  assertEqual(desktop:scroll(10, -1, -1), false)
end)
test("partially visible cards remain selectable", function()
  local desktop = harness({ count = 100 })
  desktop:open()
  desktop:scroll(-10)
  desktop:move(18, 17)
  assertEqual(desktop.menu.status().selected, 1)
end)
test("keyboard can reveal offscreen selection after scrolling", function()
  local desktop = harness({ count = 100 })
  desktop:open()
  desktop:scroll(-100000)
  desktop:key("keyDown", "left", {})
  desktop:advance(0)
  assertEqual(assert(desktop:current()).scrollOffset, 0)
  assertEqual(desktop.menu.status().selected, 1)
end)
test("menu opens on the focused Space's display, including a negative origin", function()
  local desktop = harness({
    count = 2,
    screen = { x = -1440, y = -900, w = 1440, h = 900 },
    mainScreen = { x = 0, y = 0, w = 1920, h = 1080 },
  })
  desktop:open()
  local frame = desktop.menu.canvas:frame()
  assert(
    frame.x >= -1440 and frame.x + frame.w <= 0 and frame.y >= -900 and frame.y + frame.h <= 0,
    "menu should be inside the focused display"
  )
  desktop:move(1, 1)
  assertEqual(desktop.menu.status().selected, 1)
  desktop:move(-1, -1)
  assertEqual(desktop.menu.status().selected, 1)
end)
test("an unresolved focused display fails once without opening the menu", function()
  local desktop = harness()
  desktop.displayMissing = true
  assertEqual(desktop:key("keyDown", "tab", { cmd = true }), true)
  desktop:release()
  desktop:advance(1)
  assertEqual(#desktop.commands, 0)
  assertEqual(desktop.menu.status().visible, false)
  assertEqual(desktop.logs[1], "Window switcher: focused display unavailable")
  assertEqual(#desktop.alerts, 1)
end)
test("cycle start failures alert even when print raises", function()
  for _, failure in ipairs({ "display", "list" }) do
    local desktop = harness({
      intercept = function(_, name, done)
        if failure == "list" and name == "windows" then
          done(false, "unavailable")
          return true
        end
      end,
    })
    desktop.displayMissing = failure == "display"
    desktop.printRaises = true
    -- Hammerspoon logs callback errors and keeps running.
    pcall(function()
      desktop:key("keyDown", "tab", { cmd = true })
      desktop:advance(1)
    end)
    assertEqual(#desktop.alerts, 1, failure)
    assertEqual(desktop.menu.isBusy(), false, failure)
    assertEqual(desktop.raisedPrints, 1, failure)
  end
end)
test("a focus failure alerts and frees the switcher even when print raises", function()
  local desktop = harness({
    intercept = function(model, name, done, id)
      if name == "focus" and id == 2 then
        model.hs.timer.doAfter(0.5, function()
          done(false, "focus rejected")
        end)
        return true
      end
    end,
  })
  desktop:open()
  desktop:release()
  desktop:open()
  desktop:select(3)
  desktop:release()
  desktop.printRaises = true
  pcall(desktop.advance, desktop, 1)
  assertEqual(#desktop.alerts, 1)
  assertEqual(desktop.raisedPrints, 1)
  assertEqual(desktop.windows[3]["has-focus"], true, "queued selection")
  assertEqual(desktop.menu.isBusy(), false)
end)
test("closed or reused window is rejected before focus", function()
  local desktop = harness()
  desktop:open()
  desktop.windows[2].pid = 9999
  desktop:release()
  desktop:advance(1)
  assertEqual(#desktop.alerts, 1)
  assertEqual(desktop:commandCount("focus"), 0)
end)
test(
  "hidden and minimized windows are restored before focus, quick switches without requerying",
  function()
    for _, quick in ipairs({ false, true }) do
      local desktop = harness()
      desktop.windows[2]["is-hidden"] = true
      desktop.windows[2]["is-minimized"] = true
      if quick then
        desktop:key("keyDown", "tab", { cmd = true })
        desktop:advance(0.05)
      else
        desktop:open()
      end
      desktop:release()
      if quick then
        assertEqual(desktop.windows[2]["is-hidden"], true, "unhiding waits until the tap returns")
      end
      desktop:advance(1)
      assertEqual(desktop.windows[2]["is-hidden"], false)
      assertEqual(desktop.windows[2]["is-minimized"], false)
      assertEqual(desktop.windows[2]["has-focus"], true)
      assertEqual(#desktop.alerts, 0)
      if quick then
        assertEqual(desktop:commandCount("windows"), 1, "the cycle's list is reused")
      end
    end
  end
)
test("a state change during the initial query makes a quick switch restore before focus", function()
  for _, early in ipairs({ false, true }) do
    local label = early and "released before the list" or "released after the list"
    local reply
    local desktop = harness({
      intercept = function(model, name, done)
        if name == "windows" and not reply then
          local rows = model:rows()
          reply = function()
            done(true, nil, rows)
          end
          return true
        end
      end,
    })
    desktop:key("keyDown", "tab", { cmd = true })
    desktop:advance(0.01)
    if early then
      desktop:release()
    end
    desktop.windows[2]["is-minimized"] = true
    desktop:notify("windowMinimized", desktop.windows[2])
    reply()
    if not early then
      desktop:release()
    end
    desktop:advance(1)
    assertEqual(desktop.windows[2]["is-minimized"], false, label)
    assertEqual(desktop.windows[2]["has-focus"], true, label)
    assertEqual(#desktop.alerts, 0, label)
  end
end)
test("hidden and minimized previews dim at full size with distinct centered icons", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:complete(1)
  desktop:key("keyDown", "escape", {})
  desktop.windows[2]["is-minimized"] = true
  desktop.windows[3]["is-hidden"] = true
  desktop.windows[4]["is-minimized"] = true
  desktop.windows[4]["is-hidden"] = true
  desktop:open()
  desktop:complete(2)
  local images, markers = {}, {}
  for _, element in ipairs(desktop.menu.canvas.elements) do
    if element.id and element.id:match("^state%-") then
      markers[element.id] = element
    elseif element.type == "image" then
      images[#images + 1] = element
    end
  end
  assertEqual(images[1].imageAlpha, 1, "normal preview stays bright")
  assertEqual(images[3].imageAlpha, 0.20, "hidden preview stays at 20% opacity")
  assertEqual(images[3].frame.w, images[1].frame.w, "hidden preview retains width")
  assertEqual(images[3].frame.h, images[1].frame.h, "hidden preview retains height")
  assertEqual(
    images[2].imageAlpha,
    images[3].imageAlpha,
    "minimized preview matches hidden opacity"
  )
  assertEqual(images[2].frame.w, images[1].frame.w, "minimized preview retains width")
  assertEqual(images[2].frame.h, images[1].frame.h, "minimized preview retains height")
  assertEqual(images[4].frame.w, images[1].frame.w, "both states retain width")
  assertEqual(images[4].frame.h, images[1].frame.h, "both states retain height")
  assertEqual(images[4].imageAlpha, images[3].imageAlpha, "hidden opacity applies to both states")
  assertEqual(markers["state-1"], nil, "normal windows have no state icon")
  assertEqual(markers["state-2"].image.path, "/config/assets/minimize.svg", "minimized icon")
  assertEqual(markers["state-3"].image.path, "/config/assets/eye-closed.svg", "hidden icon")
  assertEqual(
    markers["state-4"].image.path,
    "/config/assets/minimize.svg",
    "minimized takes priority"
  )
  for _, index in ipairs({ 2, 3, 4 }) do
    local marker, preview = markers["state-" .. index], images[index].frame
    assertEqual(marker.imageAlpha, 1, "state icon stays bright")
    near(
      marker.frame.x + marker.frame.w / 2,
      preview.x + preview.w / 2,
      "icon horizontally centered"
    )
    near(marker.frame.y + marker.frame.h / 2, preview.y + preview.h / 2, "icon vertically centered")
  end
  local status = desktop.menu.status()
  assertEqual(status.windows[2].minimized, true)
  assertEqual(status.windows[3].hidden, true)
  assertEqual(status.windows[1].minimized, false)
end)

test("Maps-style dialogs appear minimized or restored and can be selected", function()
  for _, minimized in ipairs({ true, false }) do
    local desktop = harness({ previews = true })
    local row = desktop.windows[2]
    row.app, row.subrole = "Maps", "AXDialog"
    row["is-minimized"] = minimized
    desktop.tracked[2] = desktop:window(row)
    desktop:open()
    desktop:complete(1)
    local status = desktop.menu.status()
    assertEqual(#status.windows, 9)
    assertEqual(status.windows[2].app, "Maps")
    assertEqual(status.windows[2].minimized, minimized)
    assertEqual(status.windows[2].preview, not minimized)
    desktop:release()
    desktop:advance(0.1)
    assertEqual(desktop.windows[2]["is-minimized"], false)
    assertEqual(desktop.windows[2]["has-focus"], true)
    assertEqual(desktop.menu.status().busy, false)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("a new minimizable dialog appears while the menu is open", function()
  local desktop = harness()
  desktop:open()
  local row = desktop:create(10, { subrole = "AXDialog", ["is-minimized"] = true })
  desktop.tracked[10] = desktop:window(row)
  desktop:advance(0)
  assertEqual(#desktop.menu.status().windows, 10)
  assertEqual(desktop.menu.status().windows[10].minimized, true)
  desktop:select(10)
  desktop:release()
  desktop:advance(0.1)
  assertEqual(desktop.windows[10]["has-focus"], true)
  assertEqual(#desktop.alerts, 0)
end)
test("unhide request rejection stops, logs, and alerts without focusing", function()
  local desktop = harness({ unhideFailure = true })
  desktop.windows[2]["is-hidden"] = true
  desktop:open()
  desktop:release()
  desktop:advance(1)
  assertEqual(desktop.windows[2]["has-focus"], false)
  assertEqual(desktop:commandCount("focus"), 0)
  assertEqual(#desktop.alerts, 1)
  assertEqual(#desktop.logs, 1, table.concat(desktop.logs, "; "))
end)
test("delayed unhide completes the first selection before restoring and focusing", function()
  for _, minimized in ipairs({ false, true }) do
    local desktop = harness({ unhideDelay = 0.2 })
    desktop.windows[2]["is-hidden"], desktop.windows[2]["is-minimized"] = true, minimized
    desktop:open()
    desktop:release()
    desktop:advance(0.05)
    assertEqual(desktop.menu.status().busy, true)
    assertEqual(desktop.unhides, 1)
    assertEqual(desktop:commandCount("focus"), 0)
    assertEqual(desktop:commandCount("minimize"), 0)
    desktop:advance(0.3)
    assertEqual(desktop.windows[2]["has-focus"], true)
    assertEqual(desktop.windows[2]["is-minimized"], false)
    assertEqual(desktop.menu.status().busy, false)
    assertEqual(desktop:commandCount("focus"), 1)
    assertEqual(desktop.unhides, 1)
    assertEqual(desktop.applications[1].enabled, false)
    assertEqual(#desktop.alerts, 0)
  end
end)
test("synchronous unhide notification restores exactly once", function()
  local desktop = harness({ unhideSynchronous = true })
  desktop.windows[2]["is-hidden"] = true
  desktop:open()
  desktop:release()
  desktop:advance(0.1)
  assertEqual(desktop.windows[2]["has-focus"], true)
  assertEqual(desktop:commandCount("focus"), 1)
  assertEqual(desktop.unhides, 1)
  assertEqual(#desktop.alerts, 0)
end)
test("unhide ignores other apps and callbacks from a finished operation", function()
  local desktop = harness({ unhideDelay = 0.2 })
  desktop.windows[2]["is-hidden"] = true
  desktop:open()
  desktop:release()
  desktop:advance(0.05)
  local watcher = desktop.applications[1]
  desktop:applicationEvent("unhidden", 103)
  desktop:advance(0.05)
  assertEqual(desktop:commandCount("focus"), 0)
  desktop:advance(0.3)
  assertEqual(desktop:commandCount("focus"), 1)
  watcher.callback(
    nil,
    desktop.hs.application.watcher.unhidden,
    desktop.hs.application.applicationForPID(102)
  )
  desktop:advance(0.1)
  assertEqual(desktop:commandCount("focus"), 1)
  assertEqual(#desktop.alerts, 0)
end)
test("unhide timeout stops its watcher without polling or retries", function()
  local desktop = harness({ unhideNever = true })
  desktop.windows[2]["is-hidden"] = true
  desktop:open()
  desktop:release()
  desktop:advance(0.05)
  local count = #desktop.commands
  local watcher = desktop.applications[1]
  desktop:advance(2)
  assertEqual(#desktop.commands, count, "waiting does not query or retry")
  assertEqual(#desktop.alerts, 0)
  desktop:advance(2)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(desktop.unhides, 1)
  assertEqual(watcher.enabled, false)
  assertEqual(desktop:commandCount("focus"), 0)
  assertEqual(#desktop.alerts, 1)
  watcher.callback(
    nil,
    desktop.hs.application.watcher.unhidden,
    desktop.hs.application.applicationForPID(102)
  )
  desktop:advance(0.1)
  assertEqual(desktop:commandCount("focus"), 0)
  assertEqual(#desktop.alerts, 1)
end)
test("app exit during unhide ends the operation immediately", function()
  local desktop = harness({ unhideNever = true })
  desktop.windows[2]["is-hidden"] = true
  desktop:open()
  desktop:release()
  desktop:advance(0.05)
  desktop:applicationEvent("terminated", 102)
  desktop:advance(0.01)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(desktop.applications[1].enabled, false)
  assertEqual(desktop:commandCount("focus"), 0)
  assertEqual(#desktop.alerts, 1)
end)
test("shutdown discards pending unhide notifications", function()
  local desktop = harness({ unhideNever = true })
  desktop.windows[2]["is-hidden"] = true
  desktop:open()
  desktop:release()
  desktop:advance(0.05)
  local watcher = desktop.applications[1]
  desktop.menu.stop()
  assertEqual(watcher.enabled, false)
  watcher.callback(
    nil,
    desktop.hs.application.watcher.unhidden,
    desktop.hs.application.applicationForPID(102)
  )
  desktop:advance(4)
  assertEqual(desktop:commandCount("focus"), 0)
  assertEqual(#desktop.alerts, 0)
end)
test("rapid selections serialize and keep the last request", function()
  local desktop = harness({ windowDelay = 0.6 })
  desktop:open()
  desktop:release()
  desktop:open()
  assertEqual(desktop.menu.status().busy, true, "first focus is still pending")
  desktop:select(3)
  desktop:release()
  desktop:advance(1)
  assertEqual(desktop.windows[3]["has-focus"], true)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(#desktop.alerts, 0)
end)
test("quick Cmd-Tab release before list arrives focuses once and passes later keys", function()
  local desktop = harness()
  desktop:key("keyDown", "tab", { cmd = true })
  assertEqual(desktop.menu.isBusy(), true, "busy before the menu shows, so Space focus stays out")
  desktop:release()
  for _, key in ipairs({ "a", "right", "escape" }) do
    assertEqual(desktop:key("keyDown", key, {}), false, key)
    assertEqual(desktop:key("keyUp", key, {}), false, key)
  end
  desktop:advance(1)
  assertEqual(desktop.windows[2]["has-focus"], true)
  assertEqual(desktop.menu.status().visible, false)
  assertEqual(desktop:commandCount("focus"), 1)
end)
test("Cmd-Tab before a released list arrives starts a new cycle", function()
  local desktop = harness()
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:release()
  desktop:open()
  assertEqual(desktop.menu.status().selected, 2)
  desktop:release()
  desktop:advance(1)
  assertEqual(desktop.windows[2]["has-focus"], true)
  assertEqual(desktop:commandCount("focus"), 1)
  assertEqual(#desktop.alerts, 0)
end)
test("missing focus notification times out without requerying windows", function()
  local desktop = harness({ focusEvents = false })
  desktop:open()
  desktop:release()
  desktop:advance(0.1)
  assertEqual(desktop.menu.status().busy, true)
  local count = #desktop.commands
  desktop:advance(4)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(#desktop.alerts, 1)
  assertEqual(#desktop.commands, count)
  assertEqual(desktop:commandCount("focus"), 1)
end)
test("the focus reply confirms focus in-process without a notification", function()
  local desktop = harness({
    focusEvents = false,
    intercept = function(model, name, done, id)
      if name == "focus" then
        model:setWindowFocus(id)
        done(true)
        return true
      end
    end,
  })
  desktop:open()
  desktop:release()
  desktop:advance(0.01)
  assertEqual(desktop.windows[2]["has-focus"], true)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(#desktop.alerts, 0)
end)
test("a focus event before the windowManager reply completes the job once", function()
  local reply
  local desktop = harness({
    intercept = function(model, name, done, id)
      if name == "focus" then
        model:setWindowFocus(id)
        reply = done
        return true
      end
    end,
  })
  desktop:open()
  desktop:release()
  desktop:advance(0.01)
  assertEqual(desktop.windows[2]["has-focus"], true)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(#desktop.commands, 3, "menu list, revalidation, and focus")
  reply(true)
  desktop:setWindowFocus(2)
  desktop:advance(4)
  assertEqual(#desktop.commands, 3)
  assertEqual(desktop:commandCount("focus"), 1)
  assertEqual(#desktop.alerts, 0)
end)
test("failed focus command logs immediately and is not retried", function()
  local desktop = harness({
    intercept = function(_, name, done)
      if name == "focus" then
        done(false, "focus rejected")
        return true
      end
    end,
  })
  desktop:open()
  desktop:release()
  desktop:advance(0.02)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(desktop:commandCount("focus"), 1)
  assert(desktop.logs[1]:find("focus rejected", 1, true))
  desktop:advance(4)
  assertEqual(desktop:commandCount("focus"), 1)
end)
test("failed revalidation stops before switching or focusing", function()
  local desktop = harness({
    intercept = function(model, name, done)
      if name == "windows" and model:commandCount("windows") == 2 then
        done(false, "unavailable")
        return true
      end
    end,
  })
  desktop:open()
  desktop:release()
  desktop:advance(1)
  assertEqual(#desktop.alerts, 1)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(desktop:commandCount("focus"), 0)
end)
test("stopping before revalidation replies prevents focus", function()
  local desktop = harness()
  desktop:open()
  desktop:release()
  desktop.menu.stop()
  desktop:advance(1)
  assertEqual(desktop:commandCount("focus"), 0)
end)
test("cancel never focuses and stops drawing", function()
  local desktop = harness()
  desktop:open()
  desktop:key("keyDown", "escape", {})
  desktop:advance(1)
  assertEqual(desktop.menu.status().visible, false)
  assertEqual(desktop:commandCount("focus"), 0)
  assertEqual(desktop.menu.mouseTap:isEnabled(), false)
end)
test("cancelled menus and finished focus jobs release their timers", function()
  local desktop = harness()
  desktop:open()
  desktop:key("keyDown", "escape", {})
  desktop:open()
  desktop:release()
  desktop:advance(5)
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:advance(0.05)
  desktop:release()
  desktop:advance(5)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(leaked(desktop.timers), 0)
end)
test("stopping during a focus job prevents late window focus", function()
  local desktop = harness({ replyDelay = 0.1 })
  desktop.windows[2]["is-minimized"] = true
  desktop:open()
  desktop:release()
  desktop:advance(0.15)
  assertEqual(desktop:commandCount("minimize"), 1)
  desktop.menu.stop()
  desktop:advance(2)
  assertEqual(desktop:commandCount("focus"), 0)
  assertEqual(#desktop.alerts, 0)
end)
test("Dock selection shares Cmd-Tab recency without starting its focus sequence", function()
  local desktop = harness()
  desktop:open()
  desktop:release()
  desktop:advance(0.2)
  assertEqual(desktop.windows[2]["has-focus"], true)
  local count = #desktop.commands
  assertEqual(desktop.menu.mostRecent({ desktop.windows[3], desktop.windows[2] }).id, 2)
  assertEqual(desktop.menu.mostRecent({}), nil)
  assertEqual(#desktop.commands, count)
  assertEqual(desktop.menu.status().busy, false)
  assertEqual(#desktop.alerts, 0)
end)

test("new windows appear while the menu is open without changing selection", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:complete(1)
  local before = desktop.menu.status()
  desktop:create(10)
  desktop:advance(0.01)
  local after = desktop.menu.status()
  assertEqual(#after.windows, #before.windows + 1)
  assertEqual(after.windows[10].id, 10)
  assertEqual(after.selected, before.selected)
  assertEqual(desktop.draws[#desktop.draws].images, 9, "existing previews stay visible")
  assertEqual(#desktop.captures, 2)
  assertEqual(#desktop.captures[2].windows, 1, "only the new window is captured")
  desktop:complete(2)
  assertEqual(desktop.draws[#desktop.draws].images, 10)
  assertEqual(desktop:commandCount("windows"), 1, "creation needs no query or polling")
end)

test("creation during the initial query survives a stale reply", function()
  local reply
  local desktop = harness({
    intercept = function(model, name, done)
      if name == "windows" and not reply then
        local rows = model:rows()
        reply = function()
          done(true, nil, rows)
        end
        return true
      end
    end,
  })
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:advance(0.01)
  desktop:create(10)
  reply()
  desktop:advance(0.3)
  assertEqual(#desktop.menu.status().windows, 10)
  assertEqual(desktop.menu.status().windows[10].id, 10)
end)

test("creation before the menu delay keeps the quick-switch path", function()
  local desktop = harness({ previews = true })
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:advance(0.01)
  desktop:create(10)
  desktop:advance(0.01)
  assertEqual(#desktop.menu.status().windows, 10)
  assertEqual(desktop.menu.status().visible, false)
  assertEqual(#desktop.captures, 0)
  desktop:release()
  desktop:advance(0.5)
  assertEqual(desktop.windows[2]["has-focus"], true)
  assertEqual(#desktop.captures, 0)
end)

test("duplicate creation events never duplicate cards or preview captures", function()
  local desktop = harness({ previews = true })
  desktop:open()
  local row = desktop:create(10)
  desktop:notify("windowCreated", row)
  desktop:advance(0.01)
  assertEqual(#desktop.menu.status().windows, 10)
  assertEqual(#desktop.captures, 2)
  assertEqual(desktop.captures[1].cancelled, true)
  assertEqual(#desktop.captures[2].windows, 10)
  desktop:notify("windowCreated", row)
  desktop:advance(0.01)
  assertEqual(#desktop.captures, 2)
end)

test("keyboard wraps onto windows created while the menu is open", function()
  local desktop = harness({ count = 6 })
  desktop:open()
  desktop:create(7)
  desktop:advance(0)
  desktop:key("keyDown", "left", {})
  desktop:key("keyDown", "left", {})
  assertEqual(desktop.menu.status().selected, 7)
end)

test("ineligible or vanished new windows stay excluded", function()
  local desktop = harness()
  desktop:open()
  for _, changes in ipairs({
    { exited = true },
    { title = "Picture-in-Picture" },
    { title = "PiP" },
    { app = "Hammerspoon" },
    { ["root-window"] = false },
  }) do
    desktop:create(10, changes)
  end
  desktop:advance(0.01)
  assertEqual(#desktop.menu.status().windows, 9)
end)

test("new hidden and minimized windows retain their states", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:complete(1)
  desktop:create(10, { ["is-hidden"] = true, ["is-minimized"] = true })
  desktop:advance(0.01)
  local row = assert(desktop.menu.status().windows[10], "new window missing")
  assertEqual(row.hidden, true)
  assertEqual(row.minimized, true)
  assertEqual(row.preview, false)
  assertEqual(#desktop.captures, 1)
end)

test("closing a window updates the menu and preserves the selected identity", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:complete(1)
  desktop:notify("windowDestroyed", desktop.windows[1])
  desktop:advance(0)
  assertEqual(#desktop.menu.status().windows, 8)
  assertEqual(desktop.menu.status().selected, 2)
  assertEqual(assert(desktop:current()).images[1], nil)
  desktop:notify("windowDestroyed", desktop.windows[2])
  desktop:advance(0)
  assertEqual(desktop.menu.status().selected, 3)
end)

test("windows entering Picture-in-Picture leave the menu and rejoin when leaving it", function()
  local desktop = harness()
  desktop.windows[3].title = "Picture-in-Picture"
  desktop:open()
  assertEqual(#desktop.menu.status().windows, 8)
  assertEqual(desktop.menu.status().selected, 2)
  desktop.windows[2].title = "PiP"
  desktop:notify("windowTitleChanged", desktop.windows[2])
  desktop.windows[3].title = "Window 3"
  desktop:notify("windowTitleChanged", desktop.windows[3])
  desktop:advance(0)
  local ids = {}
  for _, window in ipairs(desktop.menu.status().windows) do
    ids[#ids + 1] = window.id
  end
  assertEqual(table.concat(ids, " "), "1 4 5 6 7 8 9 3")
  assertEqual(desktop.menu.status().selected, 4)
  desktop:release()
  desktop:advance(0.1)
  assertEqual(desktop.windows[4]["has-focus"], true)
  assertEqual(#desktop.alerts, 0)
end)

test("closing the final window cancels the menu and pending previews", function()
  local desktop = harness({ previews = true, count = 1 })
  desktop:open()
  desktop:notify("windowDestroyed", desktop.windows[1])
  desktop:advance(0)
  assertEqual(desktop.menu.status().visible, false)
  assertEqual(desktop.captures[1].cancelled, true)
  desktop:release()
  desktop:complete(1)
  assertEqual(desktop:commandCount("focus"), 0)
end)

test("destruction during the initial query cannot resurrect a closed window", function()
  local reply
  local desktop = harness({
    count = 2,
    intercept = function(model, name, done)
      if name == "windows" and not reply then
        local rows = model:rows()
        reply = function()
          done(true, nil, rows)
        end
        return true
      end
    end,
  })
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:advance(0.01)
  desktop:notify("windowDestroyed", desktop.windows[2])
  reply()
  desktop:advance(0.3)
  assertEqual(#desktop.menu.status().windows, 1)
  assertEqual(desktop.menu.status().selected, 1)
end)

test("creation and destruction during the initial query leave no ghost card", function()
  local desktop = harness({ replyDelay = 0.1 })
  desktop:key("keyDown", "tab", { cmd = true })
  local row = desktop:create(10)
  desktop:notify("windowDestroyed", row)
  desktop:advance(0.3)
  assertEqual(#desktop.menu.status().windows, 9)
end)

test("reused IDs reject old captures even when the PID is unchanged", function()
  local desktop = harness({ previews = true })
  desktop:open()
  desktop:notify("windowDestroyed", desktop.windows[1])
  desktop:create(1)
  desktop:advance(0.01)
  assertEqual(#desktop.menu.status().windows, 9)
  assertEqual(#desktop.captures, 2)
  desktop:complete(2)
  assertEqual(assert(desktop:current()).images[1].batch, 2)
  desktop:complete(1)
  assertEqual(assert(desktop:current()).images[1].batch, 2)
  assertEqual(desktop.menu.status().selected, 2)
end)

test("reused IDs during the initial query replace the stale process", function()
  local reply
  local desktop = harness({
    intercept = function(model, name, done)
      if name == "windows" and not reply then
        local rows = model:rows()
        reply = function()
          done(true, nil, rows)
        end
        return true
      end
    end,
  })
  desktop:key("keyDown", "tab", { cmd = true })
  desktop:advance(0.01)
  desktop:notify("windowDestroyed", desktop.windows[2])
  desktop:create(2, { pid = 999 })
  reply()
  desktop:advance(0.3)
  assertEqual(#desktop.menu.status().windows, 9)
  local found
  for _, window in ipairs(assert(desktop:current()).windows) do
    if window.id == 2 then
      found = window
    end
  end
  assertEqual(found.pid, 999)
end)

test("the focused window leads the menu, then focus history, then startup order", function()
  local desktop = harness({ order = { 1, 5, 3 } })
  local function order()
    local ids = {}
    for index, window in ipairs(desktop.menu.status().windows) do
      ids[index] = window.id
    end
    return table.concat(ids, " ")
  end
  -- Real focus timestamps are far above the startup ranks.
  desktop:advance(1000)
  desktop:setWindowFocus(2)
  desktop:open()
  assertEqual(order(), "2 1 5 3 4 6 7 8 9")
  assertEqual(desktop.menu.status().selected, 1)
  desktop:release()
  desktop:advance(1)
  assertEqual(desktop.windows[1]["has-focus"], true)
  desktop:open()
  assertEqual(order(), "1 2 5 3 4 6 7 8 9")
end)

test(
  "unlisted window types appear and switch without fullscreen flags or screen-sized bounds",
  function()
    for _, subrole in ipairs({ "AXUnknown", "AXCustomWindow", "" }) do
      local desktop = harness()
      desktop.windows[2].subrole = subrole
      desktop:open()
      assertEqual(#desktop.menu.status().windows, 9)
      assertEqual(desktop.menu.status().selected, 2)
      desktop:release()
      desktop:advance(0.1)
      assertEqual(desktop.windows[2]["has-focus"], true)
      assertEqual(#desktop.alerts, 0)
    end
  end
)

test(
  "initial window list applies explicit exclusions and still requires real top-level windows",
  function()
    for _, changes in ipairs({
      { subrole = "AXDialog" },
      { subrole = "AXSystemDialog" },
      { subrole = "AXFloatingWindow" },
      { title = "Picture-in-Picture" },
      { title = "PiP" },
      { app = "Hammerspoon" },
      { role = "AXScrollArea" },
      { ["root-window"] = false },
      { exited = true },
    }) do
      local desktop = harness()
      for key, value in pairs(changes) do
        desktop.windows[2][key] = value
      end
      desktop:open()
      assertEqual(#desktop.menu.status().windows, 8)
    end
  end
)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)

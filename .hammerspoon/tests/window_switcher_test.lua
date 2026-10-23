-- Run with Lua 5.4: lua test_switcher.lua /path/to/lib
-- The production modules run unchanged in an isolated Hammerspoon/windowManager model.
local root = assert(arg[1], "pass a lib directory")
local passed, failed = 0, 0
local function eq(actual, expected, label)
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
local function test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    passed = passed + 1
    print("PASS " .. name)
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n" .. err)
  end
end
-- hs.timer keeps a callback until its timer is collected: a stopped timer its own callback reaches leaks.
local function leaked(timers)
  local count, here = 0, debug.getinfo(1, "S").source
  for _, t in ipairs(timers) do
    for i = 1, math.huge do
      local name, value = debug.getupvalue(t.callback, i)
      if not name or t.active or debug.getinfo(t.callback, "S").source == here then
        break
      end
      local held = value == t
      if type(value) == "table" and name ~= "_ENV" then
        for _, field in pairs(value) do
          held = held or field == t
        end
      end
      if held then
        count = count + 1
        break
      end
    end
  end
  return count
end
local function copy(value)
  if type(value) ~= "table" then
    return value
  end
  local result = {}
  for k, v in pairs(value) do
    result[k] = copy(v)
  end
  return result
end
local function upvalue(fn, name)
  for i = 1, 100 do
    local key, value = debug.getupvalue(fn, i)
    if key == name then
      return value
    end
    if not key then
      return nil
    end
  end
end
local function harness(options)
  local opts = options or {}
  local h = {
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
  }
  for i = 1, opts.count or 9 do
    h.windows[i] = {
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
    local t = { at = h.now + delay, delay = delay, callback = callback, active = true }
    function t:stop()
      self.active = false
      return self
    end
    function t:start()
      self.active = true
      self.at = h.now + self.delay
      return self
    end
    function t:setNextTrigger(value)
      self.at = h.now + value
      return self
    end
    t.repeating = repeating
    h.timers[#h.timers + 1] = t
    return t
  end
  function h:advance(delta)
    local target = self.now + delta
    while true do
      local nextTimer
      for _, t in ipairs(self.timers) do
        if t.active and t.at <= target and (not nextTimer or t.at < nextTimer.at) then
          nextTimer = t
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
  function h:commandCount(prefix)
    local count = 0
    for _, command in ipairs(self.commands) do
      if command:sub(1, #prefix) == prefix then
        count = count + 1
      end
    end
    return count
  end
  function h:setWindowFocus(id)
    for _, w in ipairs(self.windows) do
      w["has-focus"] = w.id == id
    end
    local callback = opts.focusEvents ~= false and self.menu.windows.subscriptions.windowFocused
    if callback then
      callback({
        id = function()
          return id
        end,
      })
    end
  end
  -- Native rows: app name and focus/hidden state come from hs.application and hs.window.
  function h:rows()
    local rows = {}
    for i, w in ipairs(self.windows) do
      rows[i] = {
        id = w.id,
        pid = w.pid,
        role = w.role,
        subrole = w.subrole,
        title = w.title,
        root = w["root-window"],
        minimized = w["is-minimized"],
      }
    end
    return rows
  end
  -- lib.window_manager replies on a later run-loop turn; `intercept` can answer instead.
  local windowManager = {}
  local function call(name, id, done, reply)
    h.commands[#h.commands + 1] = id and name .. " " .. id or name
    timer(opts.replyDelay or 0.001, function()
      if not (opts.intercept and opts.intercept(h, name, done, id)) then
        reply()
      end
    end)
  end
  function windowManager.windows(done)
    call("windows", nil, done, function()
      done(true, nil, h:rows())
    end)
  end
  function windowManager.focus(pid, id, done)
    call("focus", id, done, function()
      local w = h.windows[id]
      assert(not w["is-hidden"], "focus attempted before unhide")
      if w.pid ~= pid then
        done(false, "window unavailable")
        return
      end
      timer(opts.windowDelay or 0.003, function()
        h:setWindowFocus(id)
      end)
      done(true)
    end)
  end
  function windowManager.minimize(pid, id, minimized, done)
    call("minimize", id, done, function()
      eq(h.windows[id].pid, pid)
      h.windows[id]["is-minimized"] = minimized
      done(true)
    end)
  end
  local types = { mouseMoved = 1, scrollWheel = 2, keyDown = 3, keyUp = 4, flagsChanged = 5 }
  local keys = { a = 0, tab = 48, escape = 53, left = 123, right = 124, ["return"] = 36 }
  local props = {
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
      h.draws[#h.draws + 1] = { at = h.now, images = images }
      return self
    end
    function object:mouseCallback(fn)
      self.callback = fn
      return self
    end
    return object
  end
  local function owner(pid)
    for _, window in ipairs(h.windows) do
      if window.pid == pid then
        return window
      end
    end
  end
  local function hidden(pid)
    return (owner(pid) or {})["is-hidden"]
  end
  -- lib.window_filter, after admission: `h.tracked` holds the admitted minimizable dialogs.
  local filter = {
    blacklist = { AXDialog = true, AXSystemDialog = true, AXFloatingWindow = true },
    new = function()
      local object = chainObject()
      object.subscriptions = {}
      function object:getWindow(id, pid)
        local window = h.tracked[id]
        if window and window:application():pid() == pid then
          return window
        end
      end
      -- Like Filter:delete, which drops every callback.
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
    h.unhides = h.unhides + 1
    if opts.unhideFailure then
      return nil, "Accessibility request rejected"
    end
    local function complete()
      for _, window in ipairs(h.windows) do
        if window.pid == pid then
          window["is-hidden"] = false
        end
      end
      if opts.unhideDelay or opts.unhideSynchronous then
        h:applicationEvent("unhidden", pid)
      end
    end
    if not opts.unhideNever then
      if opts.unhideDelay then
        timer(opts.unhideDelay, complete)
      else
        complete()
      end
    end
    return true
  end
  local hsMock = {
    configdir = "/config",
    timer = {
      doAfter = function(d, f)
        return timer(d, f)
      end,
      doEvery = function()
        error("Window and Space switching must not use repeating polling")
      end,
      secondsSinceEpoch = function()
        return h.now
      end,
    },
    eventtap = {
      event = { types = types, properties = props },
      new = function(_, fn)
        local obj = chainObject()
        obj.callback = fn
        return obj
      end,
    },
    keycodes = { map = keys },
    canvas = { new = chainObject },
    -- `screen` is the focused Space's display; `mainScreen` can lag on another one.
    screen = {
      mainScreen = function()
        return {
          frame = function()
            return copy(opts.mainScreen or opts.screen or { x = 0, y = -1080, w = 1920, h = 1080 })
          end,
        }
      end,
      find = function(uuid)
        return uuid == "focused"
            and {
              frame = function()
                return copy(opts.screen or { x = 0, y = -1080, w = 1920, h = 1080 })
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
        eq(space, 1)
        if h.displayMissing then
          return nil, "space not found in managed displays"
        end
        return "focused"
      end,
    },
    mouse = {
      absolutePosition = function()
        return copy(h.pointer or { x = 0, y = 0 })
      end,
    },
    screenRecordingState = function()
      return opts.previews == true
    end,
    image = {
      imageFromPath = function(path)
        return { path = path }
      end,
      imageFromAppBundle = function(bundle)
        return opts.icons and { bundle = bundle } or nil
      end,
    },
    application = {
      watcher = {
        unhidden = 1,
        terminated = 2,
        new = function(callback)
          local watcher = chainObject()
          watcher.callback = callback
          h.applications[#h.applications + 1] = watcher
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
            return opts.icons and ((owner(pid) or {}).bundle or ("test.app." .. pid)) or nil
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
        return copy(opts.order or {})
      end,
      focusedWindow = function()
        for _, row in ipairs(h.windows) do
          if row["has-focus"] then
            return h:window(row)
          end
        end
      end,
    },
    axuielement = {
      applicationElement = function(app)
        return {
          setAttributeValue = function(_, attribute, value)
            eq(attribute, "AXHidden")
            eq(value, false)
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
    printf = function(fmt, ...)
      h.logs[#h.logs + 1] = string.format(fmt, ...)
    end,
    alert = {
      show = function(message)
        h.alerts[#h.alerts + 1] = message
      end,
    },
  }
  h.hs = hsMock
  local env = setmetatable({
    hs = hsMock,
    print = function(message)
      h.logs[#h.logs + 1] = message
    end,
  }, { __index = _G })
  local modules = {
    ["lib.window_filter"] = filter,
    ["lib.previews"] = {
      capture = function(windows, done)
        local capture = { windows = copy(windows), done = done, at = h.now }
        h.captures[#h.captures + 1] = capture
        if h.captureError then
          error("capture could not start")
        end
        return function()
          capture.cancelled = true
        end
      end,
    },
    ["lib.window_manager"] = windowManager,
  }
  env.require = function(name)
    if not modules[name] then
      modules[name] = assert(
        loadfile(root .. "/" .. name:gsub("^lib%.", ""):gsub("%.", "/") .. ".lua", "t", env)
      )()
    end
    return modules[name]
  end
  h.menu = env.require("lib.window_switcher")
  function h:applicationEvent(event, pid)
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
  function h:window(row)
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
            return opts.icons and (row.bundle or ("test.app." .. row.pid)) or nil
          end,
          isHidden = function()
            return row["is-hidden"]
          end,
        }
      end,
    }
    return window
  end
  -- Delivers an event for a window lib.window_filter has already admitted.
  function h:notify(event, row)
    local callback = self.menu.windows.subscriptions[event]
    if callback then
      callback(self:window(row), row.app, event, row.id)
    end
  end
  function h:create(id, changes)
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
  function h:event(kind, key, flags, point, properties)
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
      getProperty = function(_, p)
        return (properties or {})[p] or 0
      end,
    }
  end
  function h:key(kind, key, flags)
    return self.menu.tap.callback(self:event(kind, key, flags))
  end
  function h:open()
    self:key("keyDown", "tab", { cmd = true })
    self:advance(0.35)
    assert(self.menu.status().visible, "menu should be visible")
  end
  function h:current()
    return upvalue(self.menu.mouseTap.callback, "cycle")
  end
  function h:move(x, y)
    local frame = self.menu.canvas:frame()
    local p = { x = frame.x + x, y = frame.y + y }
    self.pointer = p
    local result = self.menu.mouseTap.callback(self:event("mouseMoved", nil, nil, p))
    self:advance(0)
    return result
  end
  function h:scroll(delta, x, y)
    local frame = self.menu.canvas:frame()
    local p = { x = frame.x + (x or 20), y = frame.y + (y or 20) }
    local result =
      self.menu.mouseTap.callback(self:event("scrollWheel", nil, nil, p, { [1] = 1, [2] = delta }))
    self:advance(0)
    return result
  end
  function h:preview(index, id, err)
    self.captures[index].done(id, not err and {
      batch = index,
      size = function()
        return { w = 230, h = 130 }
      end,
    } or nil, err)
  end
  function h:complete(index, missing, err)
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
  function h:release()
    self:key("flagsChanged", nil, {})
  end
  function h:select(index)
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
  function h:click(x, y)
    assert(self:current())
    local id
    for i = #self.menu.canvas.elements, 1, -1 do
      local e = self.menu.canvas.elements[i]
      if e.trackMouseUp then
        local f = e.frame
        if x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h then
          id = e.id
          break
        end
      end
    end
    if id then
      self.menu.canvas.callback(self.menu.canvas, "mouseUp", id, x, y)
    end
  end
  return h
end

test("visible previews are prioritized without per-window timers or polling", function()
  local h = harness({ previews = true, count = 7 })
  h:open()
  eq(#h.captures, 1)
  eq(h.captures[1].at, 0.2)
  eq(#h.captures[1].windows, 7)
  eq(#h.draws, 1)
  eq(h.draws[1].images, 0)
  h:complete(1)
  eq(#h.draws, 2)
  eq(h.draws[2].images, 7)
  h:advance(10)
  eq(#h.captures, 1, "no polling or recapture")
  eq(#h.draws, 2)
end)

test("preview capture is skipped without permission or for quick switching", function()
  local h = harness()
  h:open()
  eq(#h.captures, 0)
  h = harness({ previews = true })
  h:key("keyDown", "tab", { cmd = true })
  h:advance(0.01)
  h:release()
  h:advance(0.5)
  eq(#h.captures, 0)
end)

test("keyboard remains responsive while previews are pending", function()
  local h = harness({ previews = true })
  h:open()
  local selected = assert(h:current()).selected
  h:key("keyDown", "tab", { cmd = true })
  h:advance(0)
  eq(assert(h:current()).selected, selected + 1)
  eq(#h.captures, 2)
  eq(h.captures[1].cancelled, true)
  eq(h.captures[2].windows[1].id, selected + 1)
  h:complete(1)
  eq(assert(h:current()).selected, selected + 1)
end)

test("cancelled previews cannot redraw or seed a newer menu", function()
  local h = harness({ previews = true })
  h:open()
  h:key("keyDown", "escape", { cmd = true })
  eq(h.captures[1].cancelled, true)
  local draws = #h.draws
  h:complete(1)
  eq(#h.draws, draws)
  eq(h.menu.status().visible, false)
  h:open()
  eq(h.draws[#h.draws].images, 0)
  h:complete(2)
  eq(h.draws[#h.draws].images, 9)
end)

test("release and shutdown cancel pending previews", function()
  for _, action in ipairs({ "release", "stop" }) do
    local h = harness({ previews = true })
    h:open()
    if action == "release" then
      h:release()
    else
      h.menu.stop()
    end
    eq(h.captures[1].cancelled, true)
    local draws = #h.draws
    h:complete(1)
    eq(#h.draws, draws)
    eq(h.menu.status().visible, false)
  end
end)

test("cached previews stay visible when fresh capture fails silently", function()
  local h = harness({ previews = true })
  h:open()
  h:complete(1)
  h:key("keyDown", "escape", { cmd = true })
  h:open()
  eq(h.draws[#h.draws].images, 9)
  h:complete(2, 1, "capture failed")
  eq(assert(h:current()).images[1].batch, 1)
  eq(assert(h:current()).images[2].batch, 2)
  h:advance(10)
  eq(#h.captures, 2)
  eq(#h.alerts, 0)
  eq(#h.logs, 0)
end)

test("missing previews silently use icons for every window state", function()
  for _, state in ipairs({
    {},
    { ["is-minimized"] = true },
    { ["is-hidden"] = true },
    { ["is-minimized"] = true, ["is-hidden"] = true },
  }) do
    local h = harness({ previews = true, icons = true })
    for key, value in pairs(state) do
      h.windows[2][key] = value
    end
    h:open()
    local skipped = state["is-minimized"] or state["is-hidden"]
    eq(#h.captures[1].windows, skipped and 8 or 9)
    eq(h.captures[1].windows[1].id, skipped and 1 or 2)
    h:complete(1, 2, "could not capture window: 2")
    eq(h.menu.status().selected, 2)
    eq(h.menu.status().windows[2].preview, false)
    local icon
    for _, element in ipairs(h.menu.canvas.elements) do
      if element.image and element.image.bundle == "test.app.102" and element.frame.w == 52 then
        icon = element
      end
    end
    assert(icon, "missing preview must retain the app icon")
    h:advance(10)
    eq(#h.captures, 1, "no polling or retries")
    eq(#h.alerts, 0)
    eq(#h.logs, 0)
    h:release()
    h:advance(1)
    eq(h.windows[2]["is-minimized"], false)
    eq(h.windows[2]["has-focus"], true)
    eq(#h.alerts, 0)
  end
end)

test("minimized and hidden windows reuse cached previews until restored", function()
  for state, event in pairs({
    ["is-minimized"] = "windowUnminimized",
    ["is-hidden"] = "windowUnhidden",
  }) do
    local h = harness({ previews = true })
    h:open()
    h:complete(1)
    h:key("keyDown", "escape", {})
    h.windows[2][state] = true
    for batch = 2, 3 do
      h:open()
      eq(#h.captures[batch].windows, 8)
      for _, window in ipairs(h.captures[batch].windows) do
        assert(window.id ~= 2, "minimized or hidden window must use its cached preview")
      end
      h:complete(batch)
      eq(h:current().images[2].batch, 1)
      eq(h:current().images[1].batch, batch)
      for _, change in ipairs({ "windowTitleChanged", "windowMoved" }) do
        h:notify(change, h.windows[2])
        h:advance(0)
      end
      eq(#h.captures, batch, "other events cannot recapture minimized or hidden windows")
      if batch == 2 then
        h:key("keyDown", "escape", {})
      end
    end
    h.windows[2][state] = false
    h:notify(event, h.windows[2])
    h:advance(0)
    eq(#h.captures[4].windows, 1)
    eq(h.captures[4].windows[1].id, 2)
    h:complete(4)
    eq(h:current().images[2].batch, 4)
    eq(#h.alerts, 0)
    eq(#h.logs, 0)
  end
end)

test("minimizing during capture discards stale results without preview errors", function()
  local h = harness({ previews = true })
  h:open()
  h:preview(1, 1)
  h.windows[2]["is-minimized"] = true
  h:notify("windowMinimized", h.windows[2])
  h:advance(0)
  eq(h.captures[1].cancelled, nil)
  eq(#h.captures[2].windows, 1)
  eq(h.captures[2].windows[1].id, 2)
  h:complete(2)
  h:complete(1)
  eq(h:current().images[1].batch, 1)
  eq(h:current().images[2].batch, 2, "late menu image cannot overwrite final capture")
  eq(h:current().images[3].batch, 1)
  eq(#h.alerts, 0)
  eq(#h.logs, 0)
end)

test("menus containing only minimized and hidden windows never request captures", function()
  local h = harness({ previews = true, icons = true, count = 100 })
  for _, window in ipairs(h.windows) do
    window[window.id % 2 == 0 and "is-minimized" or "is-hidden"] = true
  end
  for _ = 1, 2 do
    h:open()
    for _, window in ipairs(h.menu.status().windows) do
      eq(window.preview, false)
      assert(window.minimized or window.hidden)
    end
    h:key("keyDown", "tab", { cmd = true })
    h:advance(0)
    h:scroll(-10000)
    h:advance(10)
    eq(#h.captures, 0)
    h:key("keyDown", "escape", {})
  end
  eq(#h.alerts, 0)
  eq(#h.logs, 0)
end)

test("capture startup errors silently preserve cached images or icons without retrying", function()
  for _, cached in ipairs({ false, true }) do
    local h = harness({ previews = true, icons = true })
    if cached then
      h:open()
      h:complete(1)
      h:key("keyDown", "escape", {})
    end
    h.captureError = true
    h:open()
    eq(h:current().capture, nil)
    for _, window in ipairs(h.menu.status().windows) do
      eq(window.preview, cached)
    end
    local previews = 0
    for _, element in ipairs(h.menu.canvas.elements) do
      if element.image and (element.image.batch or element.frame.w == 52) then
        previews = previews + 1
      end
    end
    eq(previews, 9)
    h:key("keyDown", "tab", { cmd = true })
    h:advance(10)
    eq(#h.captures, cached and 2 or 1)
    eq(#h.alerts, 0)
    eq(#h.logs, 0)
    h:release()
    h:advance(1)
    eq(h.windows[3]["has-focus"], true)
    eq(#h.alerts, 0)
  end
end)

test("reused window IDs cannot reuse another process's cached preview", function()
  local h = harness({ previews = true })
  h:open()
  h:complete(1)
  h:key("keyDown", "escape", { cmd = true })
  h.windows[1].pid = 9876
  h:open()
  eq(assert(h:current()).images[1], nil)
  eq(h.draws[#h.draws].images, 8)
end)

test("reused process IDs show the new application's icon", function()
  local h = harness({ icons = true })
  h:open()
  h:key("keyDown", "escape", {})
  h.windows[2].app, h.windows[2].bundle = "Other", "test.app.other"
  h:open()
  local bundles = {}
  for _, element in ipairs(h.menu.canvas.elements) do
    if element.image and element.image.bundle then
      bundles[element.image.bundle] = true
    end
  end
  eq(bundles["test.app.102"], nil, "exited application's icon")
  eq(bundles["test.app.other"], true, "new application's icon")
end)

test("destroyed windows cannot repopulate the preview cache", function()
  local h = harness({ previews = true })
  h:open()
  h:notify("windowDestroyed", h.windows[1])
  h:complete(1)
  eq(assert(h:current()).images[1], nil)
  h:key("keyDown", "escape", { cmd = true })
  h:open()
  eq(assert(h:current()).images[1], nil)
end)

test("progressive previews draw before the batch finishes and coalesce callbacks", function()
  local h = harness({ previews = true, count = 7 })
  h:open()
  eq(h.captures[1].windows[1].id, 2, "selected window is captured first")
  h:preview(1, 2)
  h:preview(1, 3)
  h:advance(0)
  eq(h.draws[#h.draws].images, 2)
  eq(#h.draws, 2, "one render for both completions")
  eq(#h.captures, 1)
  assert(h:current().capture, "batch is still running")
  h:complete(1)
  eq(h.draws[#h.draws].images, 7)
end)

test("100 windows capture only the current viewport and reprioritize on scroll", function()
  local h = harness({ previews = true, count = 100 })
  h:open()
  local current = assert(h:current())
  assert(#h.captures[1].windows <= #current.cards + 1)
  assert(#h.captures[1].windows < 100)
  h:preview(1, 2)
  h:advance(0)
  h:scroll(-100000)
  eq(h.captures[1].cancelled, true)
  local request = h.captures[2]
  local wanted = {}
  for _, card in ipairs(h:current().cards) do
    if card.h > 0 then
      wanted[h:current().windows[card.index].id] = true
    end
  end
  for _, window in ipairs(request.windows) do
    assert(wanted[window.id], "offscreen queued work survived scrolling")
    assert(window.id ~= 2, "completed selected thumbnail was captured again")
  end
  h:select(100)
  eq(request.cancelled, true)
  eq(h.captures[3].windows[1].id, 100)
  h:complete(1)
  h:complete(2)
  eq(h:current().images[100], nil, "cancelled results are discarded")
  h:complete(3)
  eq(h:current().images[2].batch, 1, "earlier completed thumbnail stays cached")
  eq(h:current().images[100].batch, 3)
  h:advance(10)
  eq(#h.captures, 3, "no polling")
end)

test("all 100 thumbnails remain cached while fresh work stays limited to visible cards", function()
  local h = harness({ previews = true, count = 100 })
  h:open()
  h:complete(1)
  h:key("keyDown", "left", {})
  h:advance(0)
  for _ = 2, 100 do
    h:key("keyDown", "right", {})
    h:advance(0)
    if h:current().capture then
      h:complete(#h.captures)
    end
  end
  h:key("keyDown", "escape", {})
  h:open()
  local cached = 0
  for _ in pairs(h:current().images) do
    cached = cached + 1
  end
  eq(cached, 100)
  assert(#h.captures[#h.captures].windows < 100)
  for _, card in ipairs(h:current().cards) do
    assert(h:current().images[h:current().windows[card.index].id])
  end
end)

test("window events refresh visible thumbnails and state without polling", function()
  local h = harness({ previews = true, count = 100 })
  h:open()
  h:complete(1)
  h.windows[2]["is-minimized"] = true
  h:notify("windowMinimized", h.windows[2])
  h:advance(0)
  eq(#h.captures, 2)
  eq(#h.captures[2].windows, 1)
  eq(h.captures[2].windows[1].id, 2)
  eq(h.menu.status().windows[2].minimized, true)
  eq(h:current().images[2].batch, 1)
  h:complete(2)
  eq(h:current().images[2].batch, 2)
  h.windows[100].title = "Changed offscreen"
  h:notify("windowTitleChanged", h.windows[100])
  h:advance(0)
  eq(#h.captures, 2)
  h:notify("windowMoved", h.windows[3])
  h:advance(0)
  eq(#h.captures[3].windows, 1)
  eq(h.captures[3].windows[1].id, 3)
  h:key("keyDown", "escape", {})
  h:notify("windowMoved", h.windows[2])
  h:advance(10)
  eq(#h.captures, 3, "idle events never start captures")
end)

test("minimize and hide events cache one image while the menu is closed", function()
  for _, event in ipairs({ "windowMinimized", "windowHidden" }) do
    local h = harness({ previews = true })
    h.windows[2][event == "windowMinimized" and "is-minimized" or "is-hidden"] = true
    h:notify(event, h.windows[2])
    eq(#h.captures, 1)
    eq(#h.captures[1].windows, 1)
    eq(h.captures[1].windows[1].id, 2)
    eq(#h.timers, 0, "state capture starts immediately without timers")
    eq(#h.commands, 0, "event identity needs no window query")
    h:complete(1)
    eq(h.menu.status().visible, false)
    eq(#h.draws, 0)
    h:advance(3600)
    eq(#h.captures, 1)
    h:open()
    eq(h:current().images[2].batch, 1)
    h:complete(2)
    eq(h:current().images[2].batch, 1, "menu keeps the final snapshot")
    eq(#h.alerts, 0)
    eq(#h.logs, 0)
  end
end)

test("state capture survives closing the menu and is shared with the next invocation", function()
  for _, event in ipairs({ "windowMinimized", "windowHidden" }) do
    local h = harness({ previews = true })
    h:open()
    h:complete(1)
    h.windows[2][event == "windowMinimized" and "is-minimized" or "is-hidden"] = true
    h:notify(event, h.windows[2])
    h:advance(0)
    eq(#h.captures, 2)
    eq(h:current().images[2].batch, 1)
    h:key("keyDown", "escape", {})
    eq(h.captures[2].cancelled, nil)
    h:open()
    for _, window in ipairs(h.captures[3].windows) do
      assert(window.id ~= 2, "menu must reuse the in-flight final capture")
    end
    h:complete(2)
    h:complete(3)
    eq(h:current().images[2].batch, 2)
    eq(#h.captures, 3, "final delivery cannot trigger another capture")
  end
end)

test("state capture failures preserve existing cache or icons silently", function()
  for _, cached in ipairs({ false, true }) do
    for _, startup in ipairs({ false, true }) do
      local h = harness({ previews = true, icons = true })
      if cached then
        h:open()
        h:complete(1)
        h:key("keyDown", "escape", {})
      end
      h.captureError = startup
      h.windows[2]["is-minimized"] = true
      h:notify("windowMinimized", h.windows[2])
      if not startup then
        h:complete(#h.captures, 2, "no surface")
      end
      h:advance(60)
      eq(#h.captures, cached and 2 or 1)
      h.captureError = false
      h:open()
      h:complete(#h.captures)
      eq(h.menu.status().windows[2].preview, cached)
      if cached then
        eq(h:current().images[2].batch, 1)
      end
      eq(#h.alerts, 0)
      eq(#h.logs, 0)
    end
  end
end)

test("restoring or unhiding resumes fresh captures while the final snapshot is pending", function()
  for state, event in pairs({
    ["is-minimized"] = "windowUnminimized",
    ["is-hidden"] = "windowUnhidden",
  }) do
    for _, open in ipairs({ false, true }) do
      local h = harness({ previews = true })
      h.windows[2][state] = true
      h:notify(state == "is-minimized" and "windowMinimized" or "windowHidden", h.windows[2])
      if open then
        h:open()
        h:complete(2)
      end
      h.windows[2][state] = false
      h:notify(event, h.windows[2])
      if open then
        h:advance(0)
      else
        h:open()
      end
      eq(h.captures[1].cancelled, true, "restoration supersedes the pending final snapshot")
      local batch = open and 3 or 2
      eq(h.captures[batch].windows[1].id, 2)
      h:complete(batch)
      h:complete(1)
      eq(h:current().images[2].batch, batch, "late final snapshot cannot replace the fresh image")
      eq(#h.alerts, 0)
      eq(#h.logs, 0)
    end
  end
end)

test("restoring or unhiding does not recapture while the other state remains", function()
  for state, event in pairs({
    ["is-minimized"] = "windowUnminimized",
    ["is-hidden"] = "windowUnhidden",
  }) do
    local h = harness({ previews = true, count = 1 })
    h.windows[1]["is-minimized"], h.windows[1]["is-hidden"] = true, true
    h:open()
    h.windows[1][state] = false
    h:notify(event, h.windows[1])
    h:advance(0)
    eq(#h.captures, 0)
    h.windows[1]["is-minimized"], h.windows[1]["is-hidden"] = false, false
    h:notify(state == "is-minimized" and "windowUnhidden" or "windowUnminimized", h.windows[1])
    h:advance(0)
    eq(#h.captures, 1)
    h:complete(1)
    eq(h:current().images[1].batch, 1)
  end
end)

test("new state events supersede pending captures without accepting stale results", function()
  local h = harness({ previews = true })
  h:notify("windowMinimized", h.windows[2])
  h:notify("windowHidden", h.windows[2])
  eq(h.captures[1].cancelled, true)
  h:complete(2)
  h:complete(1)
  h:open()
  eq(h:current().images[2].batch, 2)
end)

test("destroyed windows cannot be cached by a late state capture", function()
  local h = harness({ previews = true })
  h:notify("windowHidden", h.windows[2])
  h:notify("windowDestroyed", h.windows[2])
  eq(h.captures[1].cancelled, true)
  h:complete(1)
  h:create(2)
  h:open()
  eq(h:current().images[2], nil)
end)

test("window query cancels missing or reused identities with pending state captures", function()
  for _, change in ipairs({ "missing", "reused" }) do
    local h = harness({ previews = true })
    h:notify("windowHidden", h.windows[2])
    if change == "missing" then
      table.remove(h.windows, 2)
    else
      h.windows[2].pid = 9999
    end
    h:open()
    eq(h.captures[1].cancelled, true)
    h:complete(1)
    eq(h:current().images[2], nil)
  end
end)

test("shutdown cancels pending state captures and ignores their late results", function()
  local h = harness({ previews = true })
  h:notify("windowHidden", h.windows[2])
  h:notify("windowMinimized", h.windows[3])
  h.menu.stop()
  eq(h.captures[1].cancelled, true)
  eq(h.captures[2].cancelled, true)
  h:complete(1)
  h:complete(2)
  eq(#h.draws, 0)
  eq(#h.alerts, 0)
  eq(#h.logs, 0)
end)

test("other idle events and missing screen permission never capture", function()
  local h = harness({ previews = true })
  for _, event in ipairs({
    "windowMoved",
    "windowTitleChanged",
    "windowUnminimized",
    "windowUnhidden",
  }) do
    h:notify(event, h.windows[2])
  end
  eq(#h.captures, 0)
  h = harness()
  h:notify("windowMinimized", h.windows[2])
  h:notify("windowHidden", h.windows[2])
  eq(#h.captures, 0)
  eq(#h.alerts, 0)
  eq(#h.logs, 0)
end)

test("multiple progressive failures stay silent without retries", function()
  local h = harness({ previews = true })
  h:open()
  h:preview(1, 2, "first capture failed")
  h:preview(1, 3, "second capture failed")
  h:advance(0)
  eq(#h.alerts, 0)
  eq(#h.logs, 0)
  eq(#h.captures, 1)
  h:advance(10)
  eq(#h.captures, 1)
end)

test("rows balance their window counts and remain centered", function()
  for _, counts in ipairs({ { 4, 3 }, { 4, 4 }, { 5, 4 }, { 5, 4, 4 }, { 6, 6, 6 } }) do
    local total = 0
    for _, count in ipairs(counts) do
      total = total + count
    end
    local h = harness({ count = total })
    h:open()
    local c = assert(h:current())
    local rows = {}
    for _, card in ipairs(c.cards) do
      local row = rows[#rows]
      if not row or row.y ~= card.y then
        row = { y = card.y, count = 0, left = card.x }
        rows[#rows + 1] = row
      end
      row.count = row.count + 1
      row.right = card.x + card.w
    end
    eq(#rows, #counts)
    for index, row in ipairs(rows) do
      eq(row.count, counts[index], "windows in row " .. index)
      assert(math.abs(row.left - (c.frame.w - row.right)) < 1e-6, "row is not centered")
    end
  end
end)
test("keyboard reveals every window across balanced scrolling rows", function()
  for _, count in ipairs({ 49, 61, 73, 100 }) do
    local h = harness({ count = count })
    h:open()
    h:key("keyDown", "left", {})
    h:advance(0)
    for index = 1, count do
      eq(h.menu.status().selected, index)
      local hit, frame
      for _, card in ipairs(assert(h:current()).cards) do
        if card.index == index then
          hit = card
        end
      end
      for _, element in ipairs(h.menu.canvas.elements) do
        if element.id == "window-" .. index then
          frame = element.frame
        end
      end
      assert(hit and frame and math.abs(hit.h - frame.h) < 1e-6, "selected card is clipped")
      h:key("keyDown", "right", {})
      h:advance(0)
    end
    eq(h.menu.status().selected, 1, "wrap to first window")
    eq(assert(h:current()).scrollOffset, 0, "first row is revealed")
    h:key("keyDown", "left", {})
    h:advance(0)
    eq(h.menu.status().selected, count, "wrap to final window")
    eq(assert(h:current()).scrollOffset, assert(h:current()).maxScroll, "last row is revealed")
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
      local h = harness({ count = count, previews = true, screen = screen })
      h.windows[1]["is-minimized"] = true
      h:open()
      if h:current().capture then
        h:complete(1)
      end
      local current = assert(h:current())
      local frame = current.frame
      assert(frame.w <= screen.w * 0.85 and frame.h <= screen.h * 0.85, "menu exceeds display")
      near(frame.x + frame.w / 2, screen.x + screen.w / 2, "horizontal center")
      near(frame.y + frame.h / 2, screen.y + screen.h / 2, "vertical center")
      assert(current.cards[1].w >= 180 and current.cards[1].w <= 320, "unbounded preview")
      for _, element in ipairs(h.menu.canvas.elements) do
        if element.id == "state-1" then
          eq(element.frame.w, 24, "status icon stays readable")
          eq(element.frame.h, 24)
        elseif element.textSize then
          eq(element.textSize, 11, "labels stay readable")
        end
      end
      for _, card in ipairs(current.cards) do
        assert(card.h > 0, "fully clipped card has a hit target")
        assert(card.x >= 16 and card.x + card.w <= frame.w - 16)
        assert(card.y >= 16 and card.y + card.h <= frame.h - 16)
      end
      local last = current.cards[#current.cards]
      h:select(last.index)
      eq(h.menu.status().selected, last.index, "hover target")
      h:click(frame.w - 1, frame.h - 1)
      h:advance(0.15)
      eq(h.windows[last.index]["has-focus"], true, "click target")
      eq(#h.alerts, 0)
    end
  end
end)
test("width adds columns and height adds rows without oversized previews", function()
  local function grid(width, height)
    local h = harness({ count = 250, screen = { x = 0, y = 0, w = width, h = height } })
    h:open()
    return assert(h:current()).layout
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
  local h = harness({ count = 24, screen = { x = 0, y = 33, w = 1710, h = 1074 } })
  h:open()
  local current = assert(h:current())
  eq(#current.cards, 24)
  eq(current.maxScroll, 0)
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
  local h = harness({ count = 8 })
  h:open()
  local original = assert(h:current()).layout
  h:key("keyDown", "right", {})
  h:advance(0)
  eq(assert(h:current()).layout, original, "selection must reuse layout")
  h:create(9)
  h:advance(0)
  local changed = assert(h:current()).layout
  assert(changed ~= original)
  eq(changed.count, 9)
  h.windows[9].closed = true
  h:notify("windowDestroyed", h.windows[9])
  h:advance(0)
  eq(assert(h:current()).layout.count, 8)
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
    local h = harness({ count = 250, screen = screen })
    h:open()
    local current = assert(h:current())
    assert(current.maxScroll > 37)
    local tracked = "window-" .. current.cards[1].index
    local before
    for _, element in ipairs(h.menu.canvas.elements) do
      if element.id == tracked then
        before = element.frame.y
      end
    end
    h:scroll(-37)
    local after
    for _, element in ipairs(h.menu.canvas.elements) do
      if element.id == tracked then
        after = element.frame.y
      end
    end
    near(before - after, 37, "trackpad distance stays in screen points")
    h:scroll(-100000)
    current = assert(h:current())
    h:move(current.frame.w - 1, current.frame.h - 1)
    eq(h.menu.status().selected, 250, "last card remains reachable")
    h:click(current.frame.w - 1, current.frame.h - 1)
    h:advance(0.15)
    eq(h.windows[250]["has-focus"], true)
  end
end)
test("ghost padding selects at all four container edges", function()
  local h = harness({ count = 6 })
  h:open()
  local c = assert(h:current())
  local points = {
    { 0, 0, 1 },
    { c.frame.w - 0.1, 0, 6 },
    { 0, c.frame.h - 0.1, 1 },
    { c.frame.w - 0.1, c.frame.h - 0.1, 6 },
  }
  for _, p in ipairs(points) do
    h:move(p[1], p[2])
    eq(h.menu.status().selected, p[3])
  end
end)
test("horizontal and vertical gaps choose nearest card", function()
  local h = harness()
  h:open()
  local c = assert(h:current())
  local a, b, lower = c.cards[1], c.cards[2], c.cards[7]
  h:move(b.x - 1, b.y + 20)
  eq(h.menu.status().selected, 2)
  h:move(a.x + a.w + 1, a.y + 20)
  eq(h.menu.status().selected, 1)
  h:move(lower.x + 20, lower.y - 1)
  eq(h.menu.status().selected, 7)
end)
test("empty cells in incomplete final row choose nearest visible card", function()
  local h = harness({ count = 7 })
  h:open()
  local c = assert(h:current())
  h:move(c.cards[7].x + c.cards[7].w + 20, c.frame.h - 1)
  eq(h.menu.status().selected, 7)
end)
test("outside container never changes selection", function()
  local h = harness()
  h:open()
  local c = assert(h:current())
  h:select(2)
  for _, p in ipairs({
    { -0.1, 20 },
    { c.frame.w, 20 },
    { 20, -0.1 },
    { 20, c.frame.h },
    { -1000, -1000 },
    { c.frame.w + 1000, c.frame.h + 1000 },
  }) do
    h:move(p[1], p[2])
    eq(h.menu.status().selected, 2)
  end
end)
test("stationary pointer preserves keyboard selection through redraws", function()
  local h = harness()
  h:open()
  local c = assert(h:current())
  local a = c.cards[1]
  h:move(a.x + 10, a.y + 10)
  eq(h.menu.status().selected, 1)
  h:key("keyDown", "right", {})
  h:advance(0)
  h:move(a.x + 10, a.y + 10)
  eq(h.menu.status().selected, 2)
end)
test("nearest-card ties preserve the selection", function()
  local h = harness()
  h:open()
  local c = assert(h:current())
  local a, b = c.cards[1], c.cards[2]
  h:select(2)
  h:move((a.x + a.w + b.x) / 2, a.y + 20)
  eq(h.menu.status().selected, 2)
end)
test("clicking ghost padding accepts the same card as hover", function()
  local h = harness({ count = 6 })
  h:open()
  h:move(2, 2)
  h:click(2, 2)
  h:advance(0.15)
  eq(h.menu.status().visible, false)
  eq(h.windows[1]["has-focus"], true)
  eq(#h.alerts, 0)
end)
test("scrolling clips targets and ignores fully hidden cards", function()
  local h = harness({ count = 100 })
  h:open()
  local c = assert(h:current())
  local lower = c.cards[c.layout.columns + 1]
  local step = lower.y - c.cards[1].y
  eq(h:scroll(-(step - 4)), true)
  c = assert(h:current())
  h:move(1, 1)
  eq(h.menu.status().selected, lower.index, "fully clipped first row")
  h:scroll(-100000)
  c = assert(h:current())
  local last = c.cards[#c.cards]
  h:move(last.x + last.w / 2, c.frame.h - 1)
  eq(h.menu.status().selected, 100, "bottom padding")
  eq(h:scroll(10, -1, -1), false)
end)
test("partially visible cards remain selectable", function()
  local h = harness({ count = 100 })
  h:open()
  h:scroll(-10)
  h:move(18, 17)
  eq(h.menu.status().selected, 1)
end)
test("keyboard can reveal offscreen selection after scrolling", function()
  local h = harness({ count = 100 })
  h:open()
  h:scroll(-100000)
  h:key("keyDown", "left", {})
  h:advance(0)
  eq(assert(h:current()).scrollOffset, 0)
  eq(h.menu.status().selected, 1)
end)
test("menu opens on the focused Space's display, including a negative origin", function()
  local h = harness({
    count = 2,
    screen = { x = -1440, y = -900, w = 1440, h = 900 },
    mainScreen = { x = 0, y = 0, w = 1920, h = 1080 },
  })
  h:open()
  local frame = h.menu.canvas:frame()
  assert(
    frame.x >= -1440 and frame.x + frame.w <= 0 and frame.y >= -900 and frame.y + frame.h <= 0,
    "menu should be inside the focused display"
  )
  h:move(1, 1)
  eq(h.menu.status().selected, 1)
  h:move(-1, -1)
  eq(h.menu.status().selected, 1)
end)
test("an unresolved focused display fails once without opening the menu", function()
  local h = harness()
  h.displayMissing = true
  eq(h:key("keyDown", "tab", { cmd = true }), true)
  h:release()
  h:advance(1)
  eq(#h.commands, 0)
  eq(h.menu.status().visible, false)
  eq(h.logs[1], "Window switcher: focused display unavailable")
  eq(#h.alerts, 1)
end)
test("closed or reused window is rejected before focus", function()
  local h = harness()
  h:open()
  h.windows[2].pid = 9999
  h:release()
  h:advance(1)
  eq(#h.alerts, 1)
  eq(h:commandCount("focus"), 0)
end)
test("hidden and minimized windows are restored before focus", function()
  local h = harness()
  h.windows[2]["is-hidden"] = true
  h.windows[2]["is-minimized"] = true
  h:open()
  h:release()
  h:advance(1)
  eq(h.windows[2]["is-hidden"], false)
  eq(h.windows[2]["is-minimized"], false)
  eq(h.windows[2]["has-focus"], true)
  eq(#h.alerts, 0)
end)
test("hidden and minimized previews dim at full size with distinct centered icons", function()
  local h = harness({ previews = true })
  h:open()
  h:complete(1)
  h:key("keyDown", "escape", {})
  h.windows[2]["is-minimized"] = true
  h.windows[3]["is-hidden"] = true
  h.windows[4]["is-minimized"] = true
  h.windows[4]["is-hidden"] = true
  h:open()
  h:complete(2)
  local images, markers = {}, {}
  for _, element in ipairs(h.menu.canvas.elements) do
    if element.id and element.id:match("^state%-") then
      markers[element.id] = element
    elseif element.type == "image" then
      images[#images + 1] = element
    end
  end
  eq(images[1].imageAlpha, 1, "normal preview stays bright")
  eq(images[3].imageAlpha, 0.20, "hidden preview stays at 20% opacity")
  eq(images[3].frame.w, images[1].frame.w, "hidden preview retains width")
  eq(images[3].frame.h, images[1].frame.h, "hidden preview retains height")
  eq(images[2].imageAlpha, images[3].imageAlpha, "minimized preview matches hidden opacity")
  eq(images[2].frame.w, images[1].frame.w, "minimized preview retains width")
  eq(images[2].frame.h, images[1].frame.h, "minimized preview retains height")
  eq(images[4].frame.w, images[1].frame.w, "both states retain width")
  eq(images[4].frame.h, images[1].frame.h, "both states retain height")
  eq(images[4].imageAlpha, images[3].imageAlpha, "hidden opacity applies to both states")
  eq(markers["state-1"], nil, "normal windows have no state icon")
  eq(markers["state-2"].image.path, "/config/assets/minimize.svg", "minimized icon")
  eq(markers["state-3"].image.path, "/config/assets/eye-closed.svg", "hidden icon")
  eq(markers["state-4"].image.path, "/config/assets/minimize.svg", "minimized takes priority")
  for _, index in ipairs({ 2, 3, 4 }) do
    local marker, preview = markers["state-" .. index], images[index].frame
    eq(marker.imageAlpha, 1, "state icon stays bright")
    near(
      marker.frame.x + marker.frame.w / 2,
      preview.x + preview.w / 2,
      "icon horizontally centered"
    )
    near(marker.frame.y + marker.frame.h / 2, preview.y + preview.h / 2, "icon vertically centered")
  end
  local status = h.menu.status()
  eq(status.windows[2].minimized, true)
  eq(status.windows[3].hidden, true)
  eq(status.windows[1].minimized, false)
end)

test("Maps-style dialogs appear minimized or restored and can be selected", function()
  for _, minimized in ipairs({ true, false }) do
    local h = harness({ previews = true })
    local row = h.windows[2]
    row.app, row.subrole = "Maps", "AXDialog"
    row["is-minimized"] = minimized
    h.tracked[2] = h:window(row)
    h:open()
    h:complete(1)
    local status = h.menu.status()
    eq(#status.windows, 9)
    eq(status.windows[2].app, "Maps")
    eq(status.windows[2].minimized, minimized)
    eq(status.windows[2].preview, not minimized)
    h:release()
    h:advance(0.1)
    eq(h.windows[2]["is-minimized"], false)
    eq(h.windows[2]["has-focus"], true)
    eq(h.menu.status().busy, false)
    eq(#h.alerts, 0)
  end
end)

test("a new minimizable dialog appears while the menu is open", function()
  local h = harness()
  h:open()
  local row = h:create(10, { subrole = "AXDialog", ["is-minimized"] = true })
  h.tracked[10] = h:window(row)
  h:advance(0)
  eq(#h.menu.status().windows, 10)
  eq(h.menu.status().windows[10].minimized, true)
  h:select(10)
  h:release()
  h:advance(0.1)
  eq(h.windows[10]["has-focus"], true)
  eq(#h.alerts, 0)
end)
test("unhide request rejection stops, logs, and alerts without focusing", function()
  local h = harness({ unhideFailure = true })
  h.windows[2]["is-hidden"] = true
  h:open()
  h:release()
  h:advance(1)
  eq(h.windows[2]["has-focus"], false)
  eq(h:commandCount("focus"), 0)
  eq(#h.alerts, 1)
  eq(#h.logs, 1, table.concat(h.logs, "; "))
end)
test("delayed unhide completes the first selection before restoring and focusing", function()
  for _, minimized in ipairs({ false, true }) do
    local h = harness({ unhideDelay = 0.2 })
    h.windows[2]["is-hidden"], h.windows[2]["is-minimized"] = true, minimized
    h:open()
    h:release()
    h:advance(0.05)
    eq(h.menu.status().busy, true)
    eq(h.unhides, 1)
    eq(h:commandCount("focus"), 0)
    eq(h:commandCount("minimize"), 0)
    h:advance(0.3)
    eq(h.windows[2]["has-focus"], true)
    eq(h.windows[2]["is-minimized"], false)
    eq(h.menu.status().busy, false)
    eq(h:commandCount("focus"), 1)
    eq(h.unhides, 1)
    eq(h.applications[1].enabled, false)
    eq(#h.alerts, 0)
  end
end)
test("synchronous unhide notification restores exactly once", function()
  local h = harness({ unhideSynchronous = true })
  h.windows[2]["is-hidden"] = true
  h:open()
  h:release()
  h:advance(0.1)
  eq(h.windows[2]["has-focus"], true)
  eq(h:commandCount("focus"), 1)
  eq(h.unhides, 1)
  eq(#h.alerts, 0)
end)
test("unhide ignores other apps and callbacks from a finished operation", function()
  local h = harness({ unhideDelay = 0.2 })
  h.windows[2]["is-hidden"] = true
  h:open()
  h:release()
  h:advance(0.05)
  local watcher = h.applications[1]
  h:applicationEvent("unhidden", 103)
  h:advance(0.05)
  eq(h:commandCount("focus"), 0)
  h:advance(0.3)
  eq(h:commandCount("focus"), 1)
  watcher.callback(nil, h.hs.application.watcher.unhidden, h.hs.application.applicationForPID(102))
  h:advance(0.1)
  eq(h:commandCount("focus"), 1)
  eq(#h.alerts, 0)
end)
test("unhide timeout stops its watcher without polling or retries", function()
  local h = harness({ unhideNever = true })
  h.windows[2]["is-hidden"] = true
  h:open()
  h:release()
  h:advance(0.05)
  local count = #h.commands
  local watcher = h.applications[1]
  h:advance(2)
  eq(#h.commands, count, "waiting does not query or retry")
  eq(#h.alerts, 0)
  h:advance(2)
  eq(h.menu.status().busy, false)
  eq(h.unhides, 1)
  eq(watcher.enabled, false)
  eq(h:commandCount("focus"), 0)
  eq(#h.alerts, 1)
  watcher.callback(nil, h.hs.application.watcher.unhidden, h.hs.application.applicationForPID(102))
  h:advance(0.1)
  eq(h:commandCount("focus"), 0)
  eq(#h.alerts, 1)
end)
test("app exit during unhide ends the operation immediately", function()
  local h = harness({ unhideNever = true })
  h.windows[2]["is-hidden"] = true
  h:open()
  h:release()
  h:advance(0.05)
  h:applicationEvent("terminated", 102)
  h:advance(0.01)
  eq(h.menu.status().busy, false)
  eq(h.applications[1].enabled, false)
  eq(h:commandCount("focus"), 0)
  eq(#h.alerts, 1)
end)
test("shutdown discards pending unhide notifications", function()
  local h = harness({ unhideNever = true })
  h.windows[2]["is-hidden"] = true
  h:open()
  h:release()
  h:advance(0.05)
  local watcher = h.applications[1]
  h.menu.stop()
  eq(watcher.enabled, false)
  watcher.callback(nil, h.hs.application.watcher.unhidden, h.hs.application.applicationForPID(102))
  h:advance(4)
  eq(h:commandCount("focus"), 0)
  eq(#h.alerts, 0)
end)
test("rapid selections serialize and keep the last request", function()
  local h = harness({ windowDelay = 0.6 })
  h:open()
  h:release()
  h:open()
  eq(h.menu.status().busy, true, "first focus is still pending")
  h:select(3)
  h:release()
  h:advance(1)
  eq(h.windows[3]["has-focus"], true)
  eq(h.menu.status().busy, false)
  eq(#h.alerts, 0)
end)
test("quick Cmd-Tab release before list arrives focuses once and passes later keys", function()
  local h = harness()
  h:key("keyDown", "tab", { cmd = true })
  eq(h.menu.isBusy(), true, "busy before the menu shows, so Space focus stays out")
  h:release()
  for _, key in ipairs({ "a", "right", "escape" }) do
    eq(h:key("keyDown", key, {}), false, key)
    eq(h:key("keyUp", key, {}), false, key)
  end
  h:advance(1)
  eq(h.windows[2]["has-focus"], true)
  eq(h.menu.status().visible, false)
  eq(h:commandCount("focus"), 1)
end)
test("Cmd-Tab before a released list arrives starts a new cycle", function()
  local h = harness()
  h:key("keyDown", "tab", { cmd = true })
  h:release()
  h:open()
  eq(h.menu.status().selected, 2)
  h:release()
  h:advance(1)
  eq(h.windows[2]["has-focus"], true)
  eq(h:commandCount("focus"), 1)
  eq(#h.alerts, 0)
end)
test("missing focus notification times out without requerying windows", function()
  local h = harness({ focusEvents = false })
  h:open()
  h:release()
  h:advance(0.1)
  eq(h.menu.status().busy, true)
  local count = #h.commands
  h:advance(4)
  eq(h.menu.status().busy, false)
  eq(#h.alerts, 1)
  eq(#h.commands, count)
  eq(h:commandCount("focus"), 1)
end)
test("the focus reply confirms focus in-process without a notification", function()
  local h = harness({
    focusEvents = false,
    intercept = function(model, name, done, id)
      if name == "focus" then
        model:setWindowFocus(id)
        done(true)
        return true
      end
    end,
  })
  h:open()
  h:release()
  h:advance(0.01)
  eq(h.windows[2]["has-focus"], true)
  eq(h.menu.status().busy, false)
  eq(#h.alerts, 0)
end)
test("a focus event before the windowManager reply completes the job once", function()
  local reply
  local h = harness({
    intercept = function(model, name, done, id)
      if name == "focus" then
        model:setWindowFocus(id)
        reply = done
        return true
      end
    end,
  })
  h:open()
  h:release()
  h:advance(0.01)
  eq(h.windows[2]["has-focus"], true)
  eq(h.menu.status().busy, false)
  eq(#h.commands, 3, "menu list, revalidation, and focus")
  reply(true)
  h:setWindowFocus(2)
  h:advance(4)
  eq(#h.commands, 3)
  eq(h:commandCount("focus"), 1)
  eq(#h.alerts, 0)
end)
test("failed focus command logs immediately and is not retried", function()
  local h = harness({
    intercept = function(_, name, done)
      if name == "focus" then
        done(false, "focus rejected")
        return true
      end
    end,
  })
  h:open()
  h:release()
  h:advance(0.02)
  eq(h.menu.status().busy, false)
  eq(h:commandCount("focus"), 1)
  assert(h.logs[1]:find("focus rejected", 1, true))
  h:advance(4)
  eq(h:commandCount("focus"), 1)
end)
test("failed revalidation stops before switching or focusing", function()
  local h = harness({
    intercept = function(model, name, done)
      if name == "windows" and model:commandCount("windows") == 2 then
        done(false, "unavailable")
        return true
      end
    end,
  })
  h:open()
  h:release()
  h:advance(1)
  eq(#h.alerts, 1)
  eq(h.menu.status().busy, false)
  eq(h:commandCount("focus"), 0)
end)
test("stopping before revalidation replies prevents focus", function()
  local h = harness()
  h:open()
  h:release()
  h.menu.stop()
  h:advance(1)
  eq(h:commandCount("focus"), 0)
end)
test("cancel never focuses and stops drawing", function()
  local h = harness()
  h:open()
  h:key("keyDown", "escape", {})
  h:advance(1)
  eq(h.menu.status().visible, false)
  eq(h:commandCount("focus"), 0)
  eq(h.menu.mouseTap:isEnabled(), false)
end)
test("cancelled menus and finished focus jobs release their timers", function()
  local h = harness()
  h:open()
  h:key("keyDown", "escape", {})
  h:open()
  h:release()
  h:advance(5)
  eq(h.menu.status().busy, false)
  eq(leaked(h.timers), 0)
end)
test("stopping during a focus job prevents late window focus", function()
  local h = harness({ replyDelay = 0.1 })
  h.windows[2]["is-minimized"] = true
  h:open()
  h:release()
  h:advance(0.15)
  eq(h:commandCount("minimize"), 1)
  h.menu.stop()
  h:advance(2)
  eq(h:commandCount("focus"), 0)
  eq(#h.alerts, 0)
end)
test("Dock selection shares Cmd-Tab recency without starting its focus sequence", function()
  local h = harness()
  h:open()
  h:release()
  h:advance(0.2)
  eq(h.windows[2]["has-focus"], true)
  local count = #h.commands
  eq(h.menu.mostRecent({ h.windows[3], h.windows[2] }).id, 2)
  eq(h.menu.mostRecent({}), nil)
  eq(#h.commands, count)
  eq(h.menu.status().busy, false)
  eq(#h.alerts, 0)
end)

test("new windows appear while the menu is open without changing selection", function()
  local h = harness({ previews = true })
  h:open()
  h:complete(1)
  local before = h.menu.status()
  h:create(10)
  h:advance(0.01)
  local after = h.menu.status()
  eq(#after.windows, #before.windows + 1)
  eq(after.windows[10].id, 10)
  eq(after.selected, before.selected)
  eq(h.draws[#h.draws].images, 9, "existing previews stay visible")
  eq(#h.captures, 2)
  eq(#h.captures[2].windows, 1, "only the new window is captured")
  h:complete(2)
  eq(h.draws[#h.draws].images, 10)
  eq(h:commandCount("windows"), 1, "creation needs no query or polling")
end)

test("creation during the initial query survives a stale reply", function()
  local reply
  local h = harness({
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
  h:key("keyDown", "tab", { cmd = true })
  h:advance(0.01)
  h:create(10)
  reply()
  h:advance(0.3)
  eq(#h.menu.status().windows, 10)
  eq(h.menu.status().windows[10].id, 10)
end)

test("creation before the menu delay keeps the quick-switch path", function()
  local h = harness({ previews = true })
  h:key("keyDown", "tab", { cmd = true })
  h:advance(0.01)
  h:create(10)
  h:advance(0.01)
  eq(#h.menu.status().windows, 10)
  eq(h.menu.status().visible, false)
  eq(#h.captures, 0)
  h:release()
  h:advance(0.5)
  eq(h.windows[2]["has-focus"], true)
  eq(#h.captures, 0)
end)

test("duplicate creation events never duplicate cards or preview captures", function()
  local h = harness({ previews = true })
  h:open()
  local row = h:create(10)
  h:notify("windowCreated", row)
  h:advance(0.01)
  eq(#h.menu.status().windows, 10)
  eq(#h.captures, 2)
  eq(h.captures[1].cancelled, true)
  eq(#h.captures[2].windows, 10)
  h:notify("windowCreated", row)
  h:advance(0.01)
  eq(#h.captures, 2)
end)

test("keyboard wraps onto windows created while the menu is open", function()
  local h = harness({ count = 6 })
  h:open()
  h:create(7)
  h:advance(0)
  h:key("keyDown", "left", {})
  h:key("keyDown", "left", {})
  eq(h.menu.status().selected, 7)
end)

test("ineligible or vanished new windows stay excluded", function()
  local h = harness()
  h:open()
  for _, changes in ipairs({
    { exited = true },
    { title = "Picture-in-Picture" },
    { title = "PiP" },
    { app = "Hammerspoon" },
    { ["root-window"] = false },
  }) do
    h:create(10, changes)
  end
  h:advance(0.01)
  eq(#h.menu.status().windows, 9)
end)

test("new hidden and minimized windows retain their states", function()
  local h = harness({ previews = true })
  h:open()
  h:complete(1)
  h:create(10, { ["is-hidden"] = true, ["is-minimized"] = true })
  h:advance(0.01)
  local row = assert(h.menu.status().windows[10], "new window missing")
  eq(row.hidden, true)
  eq(row.minimized, true)
  eq(row.preview, false)
  eq(#h.captures, 1)
end)

test("closing a window updates the menu and preserves the selected identity", function()
  local h = harness({ previews = true })
  h:open()
  h:complete(1)
  h:notify("windowDestroyed", h.windows[1])
  h:advance(0)
  eq(#h.menu.status().windows, 8)
  eq(h.menu.status().selected, 2)
  eq(assert(h:current()).images[1], nil)
  h:notify("windowDestroyed", h.windows[2])
  h:advance(0)
  eq(h.menu.status().selected, 3)
end)

test("windows entering Picture-in-Picture leave the menu and rejoin when leaving it", function()
  local h = harness()
  h.windows[3].title = "Picture-in-Picture"
  h:open()
  eq(#h.menu.status().windows, 8)
  eq(h.menu.status().selected, 2)
  h.windows[2].title = "PiP"
  h:notify("windowTitleChanged", h.windows[2])
  h.windows[3].title = "Window 3"
  h:notify("windowTitleChanged", h.windows[3])
  h:advance(0)
  local ids = {}
  for _, window in ipairs(h.menu.status().windows) do
    ids[#ids + 1] = window.id
  end
  eq(table.concat(ids, " "), "1 4 5 6 7 8 9 3")
  eq(h.menu.status().selected, 4)
  h:release()
  h:advance(0.1)
  eq(h.windows[4]["has-focus"], true)
  eq(#h.alerts, 0)
end)

test("closing the final window cancels the menu and pending previews", function()
  local h = harness({ previews = true, count = 1 })
  h:open()
  h:notify("windowDestroyed", h.windows[1])
  h:advance(0)
  eq(h.menu.status().visible, false)
  eq(h.captures[1].cancelled, true)
  h:release()
  h:complete(1)
  eq(h:commandCount("focus"), 0)
end)

test("destruction during the initial query cannot resurrect a closed window", function()
  local reply
  local h = harness({
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
  h:key("keyDown", "tab", { cmd = true })
  h:advance(0.01)
  h:notify("windowDestroyed", h.windows[2])
  reply()
  h:advance(0.3)
  eq(#h.menu.status().windows, 1)
  eq(h.menu.status().selected, 1)
end)

test("creation and destruction during the initial query leave no ghost card", function()
  local h = harness({ replyDelay = 0.1 })
  h:key("keyDown", "tab", { cmd = true })
  local row = h:create(10)
  h:notify("windowDestroyed", row)
  h:advance(0.3)
  eq(#h.menu.status().windows, 9)
end)

test("reused IDs reject old captures even when the PID is unchanged", function()
  local h = harness({ previews = true })
  h:open()
  h:notify("windowDestroyed", h.windows[1])
  h:create(1)
  h:advance(0.01)
  eq(#h.menu.status().windows, 9)
  eq(#h.captures, 2)
  h:complete(2)
  eq(assert(h:current()).images[1].batch, 2)
  h:complete(1)
  eq(assert(h:current()).images[1].batch, 2)
  eq(h.menu.status().selected, 2)
end)

test("reused IDs during the initial query replace the stale process", function()
  local reply
  local h = harness({
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
  h:key("keyDown", "tab", { cmd = true })
  h:advance(0.01)
  h:notify("windowDestroyed", h.windows[2])
  h:create(2, { pid = 999 })
  reply()
  h:advance(0.3)
  eq(#h.menu.status().windows, 9)
  local found
  for _, window in ipairs(assert(h:current()).windows) do
    if window.id == 2 then
      found = window
    end
  end
  eq(found.pid, 999)
end)

test("the focused window leads the menu, then focus history, then startup order", function()
  local h = harness({ order = { 1, 5, 3 } })
  local function order()
    local ids = {}
    for index, window in ipairs(h.menu.status().windows) do
      ids[index] = window.id
    end
    return table.concat(ids, " ")
  end
  -- Real focus timestamps are far above the startup ranks.
  h:advance(1000)
  h:setWindowFocus(2)
  h:open()
  eq(order(), "2 1 5 3 4 6 7 8 9")
  eq(h.menu.status().selected, 1)
  h:release()
  h:advance(1)
  eq(h.windows[1]["has-focus"], true)
  h:open()
  eq(order(), "1 2 5 3 4 6 7 8 9")
end)

test(
  "unlisted window types appear and switch without fullscreen flags or screen-sized bounds",
  function()
    for _, subrole in ipairs({ "AXUnknown", "AXCustomWindow", "" }) do
      local h = harness()
      h.windows[2].subrole = subrole
      h:open()
      eq(#h.menu.status().windows, 9)
      eq(h.menu.status().selected, 2)
      h:release()
      h:advance(0.1)
      eq(h.windows[2]["has-focus"], true)
      eq(#h.alerts, 0)
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
      local h = harness()
      for key, value in pairs(changes) do
        h.windows[2][key] = value
      end
      h:open()
      eq(#h.menu.status().windows, 8)
    end
  end
)

print(string.format("RESULT %d passed, %d failed", passed, failed))
os.exit(failed > 0 and 1 or 0)

local root = assert(arg[1])
local passed = 0
local function assertEqual(actual, expected)
  assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function clone(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, item in pairs(value) do
    copy[key] = clone(item)
  end
  return copy
end
local function outside(point, frame)
  return point.x < frame.x - 8
    or point.x >= frame.x + frame.w + 8
    or point.y < frame.y - 8
    or point.y >= frame.y + frame.h + 8
end
local function test(name, body)
  body()
  passed = passed + 1
  print("PASS " .. name)
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
local function harness(options)
  options = options or {}
  local desktop = {
    now = 0,
    space = 101,
    focused = 1,
    timers = {},
    writes = {},
    clicks = {},
    mouse = { x = 17, y = 23 },
    lists = 0,
    logs = {},
    alerts = {},
    busy = false,
    recent = {},
    visible = {},
    accessibilityReads = {},
    displayReads = 0,
    shows = {},
  }
  local spaces = options.spaces
    or { { ManagedSpaceID = 101 }, { ManagedSpaceID = 202 }, { ManagedSpaceID = 303 } }
  desktop.space = options.space or desktop.space
  local function display(id)
    return options.displays and options.displays[id] or "display"
  end
  -- utils.spaces() reports each Space's screen UUID.
  for _, space in ipairs(spaces) do
    space.display = display(space.ManagedSpaceID)
  end
  -- Full frames of side-by-side displays.
  local screens = {
    display = { x = 0, y = 0, w = 1000, h = 800 },
    left = { x = 0, y = 0, w = 1000, h = 800 },
    right = { x = 1000, y = 0, w = 1000, h = 800 },
    middle = { x = 2000, y = 0, w = 1000, h = 800 },
  }
  -- Counts Accessibility calls by window ID, "app", or "focused".
  local function read(key)
    desktop.accessibilityReads[key] = (desktop.accessibilityReads[key] or 0) + 1
  end
  -- Current Spaces of other displays.
  for _, id in ipairs(options.visible or {}) do
    desktop.visible[id] = true
  end
  desktop.rows = {}
  function desktop:row(id)
    for _, row in ipairs(self.rows) do
      if row.id == id then
        return row
      end
    end
  end
  function desktop:add(row)
    -- Windows default to their Space's display.
    local screen = screens[display(row.space)] or screens.display
    row.frame = row.frame or { x = screen.x + 20, y = screen.y + 20, w = 300, h = 200 }
    self.rows[#self.rows + 1] = row
  end
  -- Space 0 is sticky. Rows stack front to back within a layer; PiP floats at layer 3.
  for _, row in ipairs({
    {
      id = 50,
      pid = 500,
      app = "Browser",
      title = "Picture in Picture",
      space = 0,
      layer = 3,
      frame = { x = 400, y = 350, w = 180, h = 180 },
    },
    { id = 1, pid = 101, app = "Editor", title = "Source", space = 101 },
    { id = 2, pid = 102, app = "Terminal", title = "Shell", space = 202 },
    { id = 3, pid = 103, app = "Browser", title = "Docs", space = 202 },
    -- Full-screen overlay above the Dock and wallpaper below windows.
    {
      id = 90,
      pid = 900,
      app = "Overlay",
      space = 0,
      layer = 25,
      untracked = true,
      frame = screens.display,
    },
    {
      id = 91,
      pid = 910,
      app = "Dock",
      space = 0,
      layer = -2147483624,
      untracked = true,
      frame = screens.display,
    },
  }) do
    desktop:add(row)
  end
  local function timer(delay, callback, repeatTimer)
    local scheduled = {
      at = desktop.now + delay,
      active = true,
      delay = delay,
      callback = callback,
      repeating = repeatTimer,
    }
    function scheduled:stop()
      self.active = false
    end
    function scheduled:setNextTrigger(seconds)
      self.at = desktop.now + seconds
    end
    desktop.timers[#desktop.timers + 1] = scheduled
    return scheduled
  end
  function desktop:advance(delay, limit)
    local count = 0
    local untilTime = self.now + delay
    while true do
      local nextTimer
      for _, candidate in ipairs(self.timers) do
        if
          candidate.active
          and candidate.at <= untilTime
          and (not nextTimer or candidate.at < nextTimer.at)
        then
          nextTimer = candidate
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
      count = count + 1
      if count == limit then
        return
      end
    end
    self.now = untilTime
  end
  local function window(id)
    local row = desktop:row(id)
    if not row then
      return nil
    end
    local methods = {
      isStandard = function()
        return true
      end,
      isMinimized = function()
        return row.minimized == true
      end,
      title = function()
        return row.title
      end,
      id = function()
        return row.id
      end,
      frame = function()
        return clone(row.frame)
      end,
      application = function()
        return {
          name = function()
            return row.app
          end,
          pid = function()
            return row.pid
          end,
        }
      end,
    }
    for name, method in pairs(methods) do
      if name ~= "id" then
        methods[name] = function()
          read(row.id)
          return method()
        end
      end
    end
    return methods
  end
  function desktop:app(pid)
    return {
      pid = function()
        return pid
      end,
      focusedWindow = function()
        read("app")
        local row = self:row(self.focused)
        return row and row.pid == pid and window(row.id) or nil
      end,
    }
  end
  function desktop:focus(id)
    local row = self:row(id)
    -- Focusing a window on another Space switches to it before notifications arrive.
    local moved = row and row.space ~= 0 and row.space ~= self.space
    if moved then
      self.space = row.space
    end
    self.focused = id
    if moved and self.spaceCallback then
      self.spaceCallback()
    end
    if self.focusCallback then
      self.focusCallback(window(id))
    end
  end
  function desktop:activate(id, pid)
    self.focused = id
    self.appCallback(nil, 1, self:app(pid or self:row(id).pid))
  end
  -- The Space a display shows: an override, the focused Space, or another display's visible one.
  function desktop:current(uuid)
    if self.shows[uuid] then
      return self.shows[uuid]
    elseif display(self.space) == uuid then
      return self.space
    end
    for id in pairs(self.visible) do
      if display(id) == uuid then
        return id
      end
    end
  end
  -- Shows a Space on its display without moving focus there.
  function desktop:show(id)
    for other in pairs(self.visible) do
      if display(other) == display(id) then
        self.visible[other] = nil
      end
    end
    self.visible[id] = true
    if self.spaceCallback then
      self.spaceCallback()
    end
  end
  -- Focus moves to the Space shown on another display.
  function desktop:shift(id)
    self.visible[self.space] = true
    self.visible[id] = nil
    self.space = id
  end
  function desktop:arrive(id, notify)
    self.space = id
    self.focused = 50
    if notify and self.spaceCallback then
      self.spaceCallback()
    end
  end
  local function object()
    return {
      start = function(self)
        self.enabled = true
        self.starts = (self.starts or 0) + 1
        return self
      end,
      stop = function(self)
        self.enabled = false
      end,
      delete = function(self)
        self.enabled = false
      end,
      isEnabled = function(self)
        return self.enabled
      end,
      subscribe = function(self, _, callback)
        desktop.focusCallback = callback
        return self
      end,
    }
  end
  -- lib.window_manager: the newest Space request supersedes a pending one; each replies once.
  local windowManager, pending = { native = {} }, nil
  function windowManager.space(index, done)
    desktop.writes[#desktop.writes + 1] = { "space", index }
    local id = spaces[index].ManagedSpaceID
    if pending then
      local old = pending
      pending = nil
      old.timer:stop()
      old.done(false, "superseded")
    end
    if options.spaceError then
      done(false, "display unavailable")
      return
    elseif desktop:current(display(id)) == id then
      done(true)
      return
    end
    local request = { done = done }
    pending = request
    request.timer = timer(0.001, function()
      pending = nil
      local function move()
        if options.away then
          -- The target is shown on its display; focus stays on the other one.
          desktop:show(id)
          if options.away == "pip" then
            desktop:focus(50)
          end
          return
        end
        desktop:arrive(id, options.notify == nil)
        if options.notify == "app" then
          desktop:activate(desktop.focused)
        elseif options.notify == "window" then
          desktop:focus(desktop.focused)
        end
      end
      if options.lateArrival then
        -- Focus can report the new Space just after its display does.
        timer(0.001, move)
      elseif not options.noArrival then
        move()
      end
      if desktop.beforeReply then
        desktop.beforeReply()
      end
      if not desktop.noReply then
        done(true)
      end
      -- Events queued behind the reply, before the next run-loop turn.
      if desktop.onReply then
        desktop.onReply()
      end
      if desktop.afterReply then
        timer(0.005, desktop.afterReply)
      end
    end)
  end
  function windowManager.native.focus(pid, id, done)
    desktop.writes[#desktop.writes + 1] = { "focus", id, pid }
    timer(0.004, function()
      local row = desktop:row(id)
      if options.focusError or not row or row.pid ~= pid then
        if done then
          done(false, "window unavailable")
        end
        return
      end
      if options.syncFocus then
        -- Focus can finish before the reply.
        desktop:focus(id)
      else
        timer(0.015, function()
          desktop:focus(id)
        end)
      end
      if done then
        done(true)
      end
    end)
  end
  local filter = {
    new = object,
    windowFocused = 1,
    windowsOf = function(pid)
      local windows, ids = {}, {}
      for _, row in ipairs(desktop.rows) do
        if row.pid == pid and not row.untracked then
          windows[row.id] = window(row.id)
          ids[#ids + 1] = row.id
        end
      end
      -- Hash order is unspecified; iterate from the highest ID so callers must sort.
      table.sort(ids, function(a, b)
        return a > b
      end)
      return setmetatable(windows, {
        __pairs = function(tracked)
          local i = 0
          return function()
            i = i + 1
            return ids[i], tracked[ids[i]]
          end
        end,
      })
    end,
  }
  local hs = {
    application = {
      -- The desktop (no focused window) belongs to Finder.
      frontmostApplication = function()
        local row = desktop:row(desktop.focused)
        return {
          bundleID = function()
            return row and row.app or "com.apple.finder"
          end,
        }
      end,
      watcher = {
        activated = 1,
        deactivated = 2,
        new = function(callback)
          desktop.appCallback = callback
          return object()
        end,
      },
    },
    timer = {
      doAfter = function(delay, callback)
        return timer(delay, callback)
      end,
      doEvery = function()
        error("Space focus must not use repeating polling")
      end,
      secondsSinceEpoch = function()
        return desktop.now
      end,
    },
    spaces = {
      focusedSpace = function()
        return desktop.space
      end,
      spaceDisplay = function(id)
        desktop.displayReads = desktop.displayReads + 1
        return display(id)
      end,
      -- Each display's current Space.
      data_managedDisplaySpaces = function()
        local out, seen = {}, {}
        for _, space in ipairs(spaces) do
          if not seen[space.display] then
            seen[space.display] = true
            out[#out + 1] = {
              ["Display Identifier"] = space.display,
              ["Current Space"] = { ManagedSpaceID = desktop:current(space.display) or -1 },
            }
          end
        end
        return out
      end,
      watcher = {
        new = function(callback)
          desktop.spaceCallback = callback
          return object()
        end,
      },
    },
    screen = {
      find = function(name)
        local frame = screens[name]
        return frame
          and {
            frame = function()
              return clone(frame)
            end,
            fullFrame = function()
              return clone(frame)
            end,
          }
      end,
    },
    mouse = {
      absolutePosition = function()
        return clone(desktop.mouse)
      end,
    },
    geometry = {
      new = function(point)
        return {
          inside = function(_, rect)
            return point.x >= rect.x
              and point.y >= rect.y
              and point.x <= rect.x + rect.w
              and point.y <= rect.y + rect.h
          end,
        }
      end,
    },
    window = {
      focusedWindow = function()
        read("focused")
        return window(desktop.focused)
      end,
      -- On-screen, front to back. Without `all`, only those behind the first titled "Dock".
      list = function(all)
        desktop.lists = desktop.lists + 1
        if desktop.listing then
          local callback = desktop.listing
          desktop.listing = nil
          callback()
        end
        local rows, order = {}, {}
        for index, row in ipairs(desktop.rows) do
          local shown = row.space == 0 or desktop:current(display(row.space)) == row.space
          if shown and not row.minimized and not row.hidden then
            rows[#rows + 1], order[row] = row, index
          end
        end
        table.sort(rows, function(a, b)
          local left, right = a.layer or 0, b.layer or 0
          return left > right or (left == right and order[a] < order[b])
        end)
        local entries = {}
        for i, row in ipairs(rows) do
          local frame = row.frame
          entries[i] = {
            kCGWindowNumber = row.id,
            kCGWindowOwnerPID = row.pid,
            kCGWindowOwnerName = row.app,
            kCGWindowName = not options.noTitles and row.title or nil,
            kCGWindowLayer = row.layer or 0,
            kCGWindowBounds = { X = frame.x, Y = frame.y, Width = frame.w, Height = frame.h },
          }
        end
        for i, entry in ipairs(entries) do
          if not all and entry.kCGWindowName == "Dock" then
            return { table.unpack(entries, i + 1) }
          end
        end
        return entries
      end,
    },
    printf = function(format, ...)
      desktop.logs[#desktop.logs + 1] = string.format(format, ...)
    end,
    keycodes = { map = { left = 123, right = 124, a = 0 } },
    eventtap = {
      new = function(types, callback)
        if types[1] == 5 then
          desktop.keyCallback = callback
        else
          desktop.inputCallback = callback
        end
        return object()
      end,
      event = {
        types = {
          leftMouseDown = 1,
          leftMouseUp = 2,
          rightMouseDown = 3,
          mouseMoved = 4,
          keyDown = 5,
          keyUp = 6,
        },
        properties = { eventSourceUserData = 1, mouseEventClickState = 2 },
        newMouseEvent = function(kind, point, modifiers)
          assertEqual(next(modifiers), nil)
          local event = { properties = {} }
          function event:setProperty(key, value)
            self.properties[key] = value
            return self
          end
          function event:post()
            desktop.mouse = clone(point)
            if kind == 1 and desktop.beforeClick then
              -- Another click already queued ahead of this one reaches the tap first.
              local callback = desktop.beforeClick
              desktop.beforeClick = nil
              callback()
            end
            -- The tap sees clicks, not pointer moves.
            local dropped = kind ~= 4
              and desktop.inputCallback({
                getProperty = function(_, key)
                  return self.properties[key] or 0
                end,
                getType = function()
                  return kind
                end,
              })
            if dropped then
              desktop.dropped = (desktop.dropped or 0) + 1
            elseif kind == 2 then
              desktop.clicks[#desktop.clicks + 1] = point
              local onDesktop = desktop.focused == nil
              timer(0.01, function()
                local moved
                for id in pairs(desktop.visible) do
                  local screen = screens[display(id)]
                  if
                    display(id) ~= display(desktop.space)
                    and point.x >= screen.x
                    and point.x < screen.x + screen.w
                  then
                    moved = id
                    break
                  end
                end
                if moved and not desktop.lateShift and not desktop.resteal then
                  desktop:shift(moved)
                end
                if onDesktop then
                  desktop.focused = nil
                elseif desktop.resteal then
                  -- PiP on the other display takes focus right back.
                  desktop.resteal = nil
                  desktop:focus(50)
                else
                  desktop:focus(nil)
                end
                -- Finder can activate before its display takes focus.
                if moved and desktop.lateShift then
                  desktop:shift(moved)
                end
              end)
            end
          end
          return event
        end,
      },
    },
  }
  local environment = setmetatable({
    hs = hs,
    print = function(message)
      desktop.logs[#desktop.logs + 1] = message
    end,
    package = {
      loaded = {
        ["lib.window_switcher"] = not options.noSwitcher and {
          isBusy = function()
            return desktop.busy
          end,
          mostRecent = function(windows)
            local target
            for _, candidate in ipairs(windows) do
              if
                not target
                or (desktop.recent[candidate.id] or 0) > (desktop.recent[target.id] or 0)
              then
                target = candidate
              end
            end
            return target
          end,
        } or nil,
      },
    },
    require = function(name)
      if name == "lib.window_filter" then
        return filter
      elseif name == "lib.logger" then
        return {
          error = function(message)
            desktop.logs[#desktop.logs + 1] = message
            desktop.alerts[#desktop.alerts + 1] = message
          end,
        }
      elseif name == "lib.window_manager" then
        return windowManager
      elseif name == "lib.mission_control" then
        return {
          isActive = function()
            if desktop.beforeMissionControl then
              local callback = desktop.beforeMissionControl
              desktop.beforeMissionControl = nil
              callback()
            end
            return desktop.missionControl or false
          end,
        }
      else
        return {
          spaces = function()
            return spaces
          end,
        }
      end
    end,
  }, { __index = _G })
  desktop.module = assert(loadfile(root .. "/space_focus.lua", "t", environment))()
  function desktop:loadShortcuts()
    self.hotkeys = {}
    hs.hotkey = {
      bind = function(modifiers, key, callback)
        self.hotkeys[table.concat(modifiers, "+") .. ":" .. key] = callback
      end,
    }
    local prior = environment.require
    environment.require = function(name)
      if name == "lib.space_focus" then
        return self.module
      elseif name == "lib.tiling" then
        return { manage = function() end }
      else
        return prior(name)
      end
    end
    assert(loadfile(root .. "/../windows.lua", "t", environment))()
  end
  function desktop:countFocus(id)
    local count = 0
    for _, command in ipairs(self.writes) do
      if command[1] == "focus" and (not id or command[2] == id) then
        count = count + 1
      end
    end
    return count
  end
  function desktop:click()
    return self.inputCallback({
      getProperty = function()
        return 0
      end,
      getType = function()
        return 1
      end,
    })
  end
  function desktop:key(kind, key, flags)
    return self.keyCallback({
      getType = function()
        return hs.eventtap.event.types[kind]
      end,
      getKeyCode = function()
        return hs.keycodes.map[key]
      end,
      getFlags = function()
        return flags or {}
      end,
    })
  end
  return desktop
end

test("numbered Space moves focus from PiP to the Space's window", function()
  local desktop = harness()
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.space, 202)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(desktop:countFocus(), 1)
end)
test("focus notification completes restoration synchronously", function()
  local desktop = harness()
  desktop.module.switchSpace(2)
  desktop:advance(0.021)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop.module.status().busy, false)
end)
test("a focus reply completes restoration when focus changed first", function()
  local desktop = harness({ syncFocus = true })
  desktop.focusCallback = nil
  desktop.module.switchSpace(2)
  desktop:advance(0.006)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop.module.status().busy, false)
  assertEqual(desktop.module.status().last.ok, true)
end)
test("missing focus notification logs timeout without retrying", function()
  local desktop = harness()
  desktop.focusCallback = nil
  desktop.module.switchSpace(2)
  desktop:advance(0.1)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop.module.status().busy, true)
  local lists = desktop.lists
  desktop:advance(1)
  assertEqual(desktop.module.status().busy, false)
  assertEqual(desktop.lists, lists)
  assertEqual(desktop:countFocus(), 1)
  assert(desktop.logs[1]:find("timed out", 1, true))
end)
test("last normal window on the destination is remembered", function()
  local desktop = harness()
  desktop.space = 202
  desktop:focus(3)
  desktop:advance(0.05)
  desktop.space = 101
  desktop:focus(1)
  desktop:advance(0.05)
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 3)
end)
test("the frontmost eligible window is focused when none is remembered", function()
  local desktop = harness()
  -- Send Shell (2) behind Docs (3).
  for i, row in ipairs(desktop.rows) do
    if row.id == 2 then
      desktop:add(table.remove(desktop.rows, i))
      break
    end
  end
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 3)
  assertEqual(desktop:countFocus(), 1)
end)
test("same-Space shortcut removes PiP focus too", function()
  local desktop = harness()
  desktop:focus(50)
  desktop.module.switchSpace(1)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 1)
end)
test("PID reuse cannot satisfy the remembered identity", function()
  local desktop = harness()
  desktop.space = 202
  desktop:focus(3)
  desktop:advance(0.05)
  desktop.space = 101
  desktop:focus(1)
  desktop:advance(0.05)
  desktop:row(3).pid = 999
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 2)
end)
test("PiP, Hammerspoon, hidden and minimized windows are excluded", function()
  local desktop = harness()
  desktop:row(2).hidden = true
  desktop:row(3).minimized = true
  desktop:add({ id = 4, pid = 104, app = "Hammerspoon", title = "Console", space = 202 })
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop.focused, nil)
end)
test("minimized and hidden windows are never candidates, even when remembered", function()
  for _, state in ipairs({ "minimized", "hidden" }) do
    local desktop = harness()
    desktop.space = 202
    desktop:focus(3)
    desktop:advance(0.05)
    desktop.space = 101
    desktop:focus(1)
    desktop:advance(0.05)
    desktop:row(3)[state] = true
    desktop.module.switchSpace(2)
    desktop:advance(0.3)
    assertEqual(desktop.focused, 2)
    assertEqual(desktop:countFocus(), 1)
  end
end)
test("untracked on-screen windows are never candidates but still cover the desktop", function()
  local desktop = harness()
  desktop:row(2).untracked = true
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 3)
  assertEqual(desktop:countFocus(), 1)
  desktop = harness()
  desktop:row(2).untracked, desktop:row(3).untracked = true, true
  desktop:row(2).frame = { x = 300, y = 250, w = 400, h = 300 }
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.clicks, 1)
  for _, id in ipairs({ 2, 3, 50 }) do
    assert(outside(desktop.clicks[1], desktop:row(id).frame))
  end
end)
test("layer-3 windows are never candidates, while a focused PiP is seen and avoided", function()
  for _, space in ipairs({ 202, 303 }) do
    local desktop = harness()
    desktop:add({
      id = 51,
      pid = 510,
      app = "Player",
      title = "Lecture",
      space = 0,
      layer = 3,
      frame = { x = 300, y = 330, w = 120, h = 120 },
    })
    desktop:arrive(space, true)
    desktop:advance(0.3)
    if space == 202 then
      assertEqual(desktop.focused, 2)
      assertEqual(desktop:countFocus(), 1)
      assertEqual(#desktop.clicks, 0)
    else
      assertEqual(desktop:countFocus(), 0)
      assertEqual(#desktop.clicks, 1)
      assert(outside(desktop.clicks[1], desktop:row(50).frame))
      assert(outside(desktop.clicks[1], desktop:row(51).frame))
    end
  end
end)
test("windows on the other display's visible Space are excluded", function()
  local desktop =
    harness({ displays = { [101] = "left", [202] = "right", [303] = "left" }, visible = { 202 } })
  -- Shell and Docs stay on-screen, centered on the right display.
  desktop.module.switchSpace(3)
  desktop:advance(0.3)
  assertEqual(desktop.space, 303)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.clicks, 1)
end)
test("a window titled Dock behind the destination does not stop focus restoration", function()
  local desktop = harness()
  desktop:add({ id = 4, pid = 104, app = "Finder", title = "Dock", space = 202 })
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop:countFocus(), 1)
end)
test("an unavailable Space display fails once with a popup", function()
  local desktop = harness({ displays = { [202] = "gone" } })
  desktop.module.switchSpace(2)
  desktop:advance(2)
  assertEqual(desktop.module.status().last.ok, false)
  assertEqual(desktop.module.status().last.error, "Space display unavailable")
  assertEqual(desktop.lists, 0)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.clicks, 0)
  assertEqual(desktop.module.status().busy, false)
  assertEqual(#desktop.alerts, 1)
  assertEqual(desktop.logs[1], "Space focus: Space display unavailable")
end)
test("empty Space focuses uncovered desktop without returning to another Space", function()
  local desktop = harness()
  -- A shown Dock is no cover.
  desktop:add({
    id = 92,
    pid = 910,
    app = "Dock",
    title = "Dock",
    space = 0,
    layer = 20,
    untracked = true,
    frame = { x = 0, y = 0, w = 1000, h = 800 },
  })
  desktop.module.switchSpace(3)
  desktop:advance(0.3)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(desktop.mouse.x, 17)
  assertEqual(desktop.mouse.y, 23)
  assert(outside(desktop.clicks[1], desktop:row(50).frame))
end)
test("no desktop click is issued through a covering window", function()
  local desktop = harness()
  desktop:row(50).frame = { x = 0, y = 0, w = 1000, h = 800 }
  desktop.module.switchSpace(3)
  desktop:advance(0.3)
  assertEqual(#desktop.clicks, 0)
  assertEqual(desktop.module.status().last.ok, false)
end)
test("a Space change from outside the shortcuts moves focus from PiP", function()
  local desktop = harness()
  desktop:arrive(202, true)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 2)
end)
test("normal focus from an external Space change is preserved", function()
  local desktop = harness()
  desktop.space = 202
  desktop.focused = 3
  desktop.spaceCallback()
  desktop:advance(0.3)
  assertEqual(desktop.focused, 3)
  assertEqual(desktop:countFocus(), 0)
end)
test("late PiP focus notification is still corrected", function()
  local desktop = harness()
  desktop.space = 202
  desktop.focused = 3
  desktop.spaceCallback()
  desktop:advance(0.05)
  desktop:focus(50)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 2)
end)
test("already-visible monitor switch works without a Space event", function()
  local desktop = harness({ displays = { [101] = "left", [202] = "right" }, visible = { 202 } })
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop:countFocus(), 1)
  assertEqual(#desktop.alerts, 0)
  assertEqual(desktop.module.status().last.ok, true)
end)
test("a Space change before the deferred focus cannot pull focus back", function()
  local desktop = harness()
  desktop:arrive(202, true)
  desktop:arrive(303, true)
  desktop:advance(0.4)
  assertEqual(desktop.space, 303)
  assertEqual(desktop:countFocus(), 0)
end)

test("a new Alt-number dispatches before the previous Space replies", function()
  local desktop = harness()
  desktop:loadShortcuts()
  desktop.hotkeys["alt:2"]()
  desktop.hotkeys["alt:3"]()
  assertEqual(#desktop.writes, 2)
  assertEqual(desktop.writes[2][2], 3)
  assertEqual(desktop.space, 101)
  desktop:advance(0.3)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(desktop.module.status().busy, false)
  assertEqual(#desktop.logs, 0)
  assertEqual(#desktop.alerts, 0)
end)

test(
  "rapid Alt-number presses dispatch every switch but retain only the latest callback",
  function()
    local desktop = harness()
    desktop:loadShortcuts()
    desktop.hotkeys["alt:2"]()
    desktop:advance(0.005)
    desktop.hotkeys["alt:1"]()
    desktop.hotkeys["alt:2"]()
    desktop:advance(0.2)
    assertEqual(desktop.space, 202)
    assertEqual(desktop.focused, 2)
    local count = 0
    for _, command in ipairs(desktop.writes) do
      if command[1] == "space" then
        count = count + 1
        assertEqual(command[2], ({ 2, 1, 2 })[count])
      else
        assertEqual(command[2], 2)
      end
    end
    assertEqual(count, 3)
    assertEqual(desktop.module.status().busy, false)
    assertEqual(#desktop.logs, 0)
  end
)

test("a Space change during a synchronous check cannot dispatch stale focus", function()
  for _, deferred in ipairs({ false, true }) do
    local desktop = harness()
    desktop.module.switchSpace(2)
    if deferred then
      -- Arrival only; the focus action waits for the next run-loop turn.
      desktop:advance(0.3, 1)
    end
    desktop.beforeMissionControl = function()
      desktop:arrive(101, false)
    end
    desktop:advance(0.3)
    assertEqual(desktop.space, 101)
    assertEqual(desktop:countFocus(), 0)
    assertEqual(desktop.module.status().busy, false)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("mouse input and shutdown cancel the current job without undoing sent commands", function()
  for _, stop in ipairs({ false, true }) do
    local desktop = harness()
    desktop.module.switchSpace(2)
    desktop:advance(0.005, 1)
    desktop.module.switchSpace(3)
    if stop then
      desktop.module.stop()
    else
      desktop:click()
    end
    desktop:advance(0.15)
    assertEqual(desktop.space, 303)
    assertEqual(desktop:countFocus(), 0)
    assertEqual(#desktop.clicks, 0)
    assertEqual(#desktop.writes, 2)
    assertEqual(desktop.module.status().busy, false)
    assertEqual(desktop.module.status().active, not stop)
    assertEqual(desktop.module.status().last.error, stop and "stopped" or "superseded")
  end
end)

test("rapid relative shortcuts advance from the pending destination", function()
  local desktop = harness()
  desktop.module.switchSpace("next")
  desktop.module.switchSpace("next")
  desktop:advance(0.3)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(desktop:countFocus(), 0)
end)
test("finished and superseded jobs release their timers", function()
  local desktop = harness()
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  desktop.module.switchSpace(3)
  desktop.module.switchSpace(1)
  desktop:advance(2)
  assertEqual(desktop.module.status().busy, false)
  assertEqual(leaked(desktop.timers), 0)
end)
test("invalid request does not leave the controller busy", function()
  local desktop = harness()
  desktop.module.switchSpace(2)
  desktop.module.switchSpace(99)
  assertEqual(#desktop.alerts, 1)
  desktop:advance(0.3)
  assertEqual(desktop.module.status().busy, false)
end)
test("clicking PiP intentionally is not undone", function()
  local desktop = harness()
  desktop.space = 202
  desktop.focused = 3
  desktop.spaceCallback()
  desktop:advance(0.05)
  desktop:click()
  desktop:focus(50)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 50)
  assertEqual(desktop:countFocus(), 0)
end)
test("mouse intent cancels a pending correction", function()
  local desktop = harness()
  desktop:arrive(202, true)
  desktop:click()
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.clicks, 0)
end)
test("Cmd-Tab exact-window operation takes priority", function()
  local desktop = harness()
  desktop.busy = true
  desktop:arrive(202, true)
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 0)
end)
test("idle controller takes no periodic window snapshots", function()
  local desktop = harness()
  desktop:advance(30)
  assertEqual(desktop.lists, 0)
end)
test("actual numbered and Ctrl-arrow bindings use PiP-safe focus", function()
  local desktop = harness()
  desktop:loadShortcuts()
  desktop.hotkeys["alt:2"]()
  desktop:advance(0.3)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop.hotkeys["ctrl:left"], nil)
  assertEqual(desktop:key("keyDown", "left", { ctrl = true }), true)
  assertEqual(desktop:key("keyUp", "left", {}), true)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 1)
  assertEqual(desktop:key("keyDown", "right", { ctrl = true }), true)
  assertEqual(desktop:key("keyUp", "right", { ctrl = true }), true)
  desktop:advance(0.3)
  assertEqual(desktop.focused, 2)
end)
test("failed focus stops immediately and is never retried", function()
  local desktop = harness({ focusError = true })
  desktop.module.switchSpace(2)
  desktop:advance(0.07)
  assertEqual(desktop.module.status().busy, false)
  assertEqual(desktop.module.status().last.ok, false)
  assertEqual(desktop:countFocus(), 1)
  assertEqual(desktop.logs[1], "Space focus: window unavailable")
  local lists = desktop.lists
  desktop:advance(30)
  assertEqual(desktop.lists, lists)
  assertEqual(desktop:countFocus(), 1)
end)
test("relative navigation stops at both display boundaries", function()
  local desktop = harness({ displays = { [101] = "left", [202] = "right", [303] = "right" } })
  desktop.module.switchSpace("next")
  assertEqual(#desktop.writes, 0)
  desktop.space = 202
  desktop.module.switchSpace("prev")
  assertEqual(#desktop.writes, 0)
  desktop.module.switchSpace("next")
  desktop:advance(0.3)
  assertEqual(desktop.space, 303)
  local before = #desktop.writes
  desktop.module.switchSpace("next")
  assertEqual(#desktop.writes, before)
end)
test("Spaces 9 and 10 never navigate into Spaces 8 or 11", function()
  local spaces, displays = {}, {}
  for i = 1, 11 do
    spaces[i] = { ManagedSpaceID = i * 100 }
    displays[i * 100] = i < 9 and "left" or i < 11 and "middle" or "right"
  end
  local desktop = harness({ spaces = spaces, displays = displays, space = 1000 })
  desktop.module.switchSpace("prev")
  desktop:advance(0.3)
  assertEqual(desktop.space, 900)
  local before = #desktop.writes
  for _ = 1, 10 do
    desktop.module.switchSpace("prev")
  end
  assertEqual(#desktop.writes, before)
  assertEqual(desktop.space, 900)
  desktop.module.switchSpace("next")
  desktop:advance(0.3)
  assertEqual(desktop.space, 1000)
  before = #desktop.writes
  for _ = 1, 10 do
    desktop.module.switchSpace("next")
  end
  assertEqual(#desktop.writes, before)
end)
test("rapid presses at an edge preserve the pending focus restoration", function()
  local desktop = harness({ displays = { [101] = "left", [202] = "left", [303] = "right" } })
  desktop.module.switchSpace("next")
  for _ = 1, 10 do
    desktop.module.switchSpace("next")
  end
  desktop:advance(0.3)
  assertEqual(desktop.space, 202)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop:countFocus(), 1)
  assertEqual(desktop.module.status().busy, false)
end)
test("numbered shortcuts still select a Space on another display", function()
  local desktop = harness({ displays = { [101] = "left", [202] = "right", [303] = "right" } })
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  assertEqual(desktop.space, 202)
  assertEqual(desktop.focused, 2)
end)
-- Left display: 101 (Editor, PiP); right display: 202 (Shell, Docs) shown, 303 empty.
local function away(mode)
  return harness({
    displays = { [101] = "left", [202] = "right", [303] = "right" },
    visible = { 202 },
    away = mode,
  })
end
test("an empty Space on another display takes focus once windowManager replies", function()
  local desktop = away(true)
  -- The display can show the Space before windowManager replies; restoration waits for the reply.
  desktop.beforeReply = function()
    assertEqual(desktop.lists, 0)
  end
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 1)
  assert(desktop.clicks[1].x >= 1000)
  assertEqual(#desktop.alerts, 0)
end)
test("PiP focus on the other display after the Space appears goes to the new desktop", function()
  local desktop = away("pip")
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(#desktop.alerts, 0)
end)
test("PiP focus after focus reaches the new Space is still left for its desktop", function()
  local desktop = away(true)
  desktop.module.switchSpace(3)
  -- The display takes focus, then PiP on the other display takes it back.
  desktop.beforeReply = function()
    desktop:shift(303)
    desktop.focused = 50
  end
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop.module.status().last.ok, true)
end)
test("from the other display's desktop, an empty Space there still takes focus", function()
  local desktop = away(true)
  desktop.focused = nil
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop.module.status().last.ok, true)
end)
test("a Space switch on a display without the PiP recovers focus the PiP took", function()
  local desktop = harness({
    displays = { [101] = "left", [202] = "right", [303] = "right" },
    visible = { 101 },
    noArrival = true,
  })
  desktop.space, desktop.focused = 202, 2
  -- The right display shows 303, then focus lands on the left display's PiP.
  desktop.beforeReply = function()
    desktop.space, desktop.visible = 101, { [303] = true }
  end
  desktop.afterReply = function()
    desktop:focus(50)
  end
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 1)
  assert(desktop.clicks[1].x >= 1000)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(#desktop.alerts, 0)
end)
test("a same-display Space shown before focus follows waits instead of clicking", function()
  local desktop = harness({
    displays = { [101] = "left", [202] = "right", [303] = "right" },
    visible = { 101 },
    noArrival = true,
  })
  desktop.space, desktop.focused = 202, 2
  desktop.beforeReply = function()
    desktop.shows.right = 303
  end
  -- Focus follows just after the reply, to the new desktop.
  desktop.afterReply = function()
    desktop.shows.right = nil
    desktop.space, desktop.focused = 303, nil
    desktop.spaceCallback()
  end
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(#desktop.clicks, 0)
  assertEqual(desktop.module.status().last.ok, true)
end)
test(
  "a Space notification after the reply, with focus still on the other display, is ignored",
  function()
    local desktop = away(true)
    desktop.onReply = function()
      desktop.spaceCallback()
    end
    desktop.module.switchSpace(3)
    desktop:advance(2)
    assertEqual(desktop.space, 303)
    assertEqual(#desktop.clicks, 1)
    assertEqual(desktop:countFocus(), 0)
    assertEqual(desktop.module.status().last.ok, true)
  end
)
test("PiP retaking focus from the other display after the switch is undone", function()
  local desktop = away(true)
  desktop.module.switchSpace(3)
  desktop:advance(0.1)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.module.status().busy, false)
  -- The left display's PiP takes focus back, within the transition.
  desktop.visible[303], desktop.visible[101], desktop.space = true, nil, 101
  desktop:focus(50)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 2)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(desktop.module.status().last.ok, true)
end)
test("a window on the other display keeping focus after the display switch is left", function()
  local desktop = away(true)
  -- The menu bar moves to the new display; the old display's window stays key.
  desktop.beforeReply = function()
    desktop:shift(303)
  end
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop.module.status().last.ok, true)
end)
test("Finder activating before its display takes focus still finishes the switch", function()
  local desktop = away(true)
  desktop.lateShift = true
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(#desktop.alerts, 0)
end)
test("PiP retaking focus right after the desktop click finishes without a timeout", function()
  local desktop = away(true)
  desktop.resteal = true
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 2)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(#desktop.alerts, 0)
end)
test("an app activating onto its PiP during the transition retakes the shown Space", function()
  local desktop = away(true)
  desktop.module.switchSpace(3)
  desktop:advance(0.1)
  assertEqual(desktop.space, 303)
  -- Activation arrives before the PiP's focus notification.
  desktop.visible[303], desktop.visible[101], desktop.space = true, nil, 101
  desktop:activate(50)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.clicks, 2)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.alerts, 0)
end)
test("an activation onto the other display before its PiP takes focus waits for the PiP", function()
  local desktop = away(true)
  desktop:add({ id = 70, pid = 500, app = "Browser", title = "Tab", space = 101 })
  desktop.module.switchSpace(3)
  desktop:advance(0.1)
  assertEqual(desktop.space, 303)
  -- The PiP's app activates on the left display, then its PiP becomes key.
  desktop.visible[303], desktop.visible[101], desktop.space = true, nil, 101
  desktop:activate(70)
  desktop:focus(50)
  desktop:advance(2)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.alerts, 0)
end)
test("a user click queued ahead of the desktop click drops it quietly", function()
  local desktop = away(true)
  desktop.beforeClick = function()
    desktop:click()
  end
  desktop.module.switchSpace(3)
  desktop:advance(2)
  assertEqual(#desktop.clicks, 0)
  assertEqual(desktop.dropped, 2)
  assertEqual(desktop.module.status().last.error, "superseded")
  assertEqual(#desktop.alerts, 0)
end)
test("a desktop click after an earlier user click is not dropped", function()
  local desktop = harness()
  assertEqual(desktop:click(), false)
  desktop:advance(0.3)
  desktop.module.switchSpace(3)
  desktop:advance(0.3)
  assertEqual(#desktop.clicks, 1)
  assertEqual(desktop.dropped, nil)
  assertEqual(desktop.module.status().last.ok, true)
end)
test("shortcuts reuse the Space list's displays; native transitions look one up", function()
  local desktop = harness({ displays = { [101] = "left", [202] = "left", [303] = "right" } })
  desktop:row(50).frame = { x = 1400, y = 350, w = 180, h = 180 }
  desktop:loadShortcuts()
  assertEqual(desktop:key("keyDown", "right", { ctrl = true }), true)
  desktop:advance(0.3)
  assertEqual(desktop.space, 202)
  assertEqual(desktop:key("keyDown", "right", { ctrl = true }), true)
  desktop:advance(0.3)
  assertEqual(#desktop.writes, 2)
  desktop.hotkeys["alt:3"]()
  desktop:advance(0.3)
  assertEqual(desktop.space, 303)
  assertEqual(#desktop.clicks, 1)
  -- The desktop click lands on the job's screen, clear of the PiP there.
  assert(desktop.clicks[1].x >= 1000 and outside(desktop.clicks[1], desktop:row(50).frame))
  assertEqual(desktop.displayReads, 0)
  desktop:arrive(101, true)
  desktop:advance(0.3)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(desktop.displayReads, 1)
end)
test("restoration never restarts the mouse-intent tap", function()
  local desktop = harness()
  assertEqual(desktop.module.input.starts, 1)
  desktop.module.switchSpace(2)
  desktop:advance(0.3)
  desktop:arrive(303, true)
  desktop:advance(0.3)
  assertEqual(desktop.module.input.starts, 1)
  assertEqual(desktop.module.input:isEnabled(), true)
  desktop.module.stop()
  assertEqual(desktop.module.input:isEnabled(), false)
end)
test("Mission Control receives the original Ctrl-arrow events immediately", function()
  local desktop = harness()
  desktop:loadShortcuts()
  desktop.missionControl = true
  for _, key in ipairs({ "left", "right" }) do
    assertEqual(desktop:key("keyDown", key, { ctrl = true }), false)
    assertEqual(desktop:key("keyUp", key, { ctrl = true }), false)
  end
  assertEqual(#desktop.writes, 0)
  desktop.missionControl = false
  assertEqual(desktop:key("keyDown", "right", { ctrl = true }), true)
  desktop:advance(0.3)
  assertEqual(desktop.space, 202)
end)
test("other arrow combinations pass through, including plain arrow keys", function()
  local desktop = harness()
  desktop:loadShortcuts()
  for _, flags in ipairs({
    {},
    { ctrl = true, alt = true },
    { ctrl = true, cmd = true },
    { ctrl = true, shift = true },
  }) do
    assertEqual(desktop:key("keyDown", "right", flags), false)
    assertEqual(desktop:key("keyUp", "right", flags), false)
  end
  assertEqual(desktop:key("keyDown", "a", { ctrl = true }), false)
  assertEqual(#desktop.writes, 0)
  assertEqual(desktop:key("keyDown", "right", { ctrl = true, fn = true }), true)
  desktop:advance(0.3)
  assertEqual(desktop.space, 202)
end)
test("Mission Control Space notifications never focus windows or click desktop", function()
  local desktop = harness()
  desktop.missionControl = true
  desktop:arrive(202, true)
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.clicks, 0)
  assertEqual(desktop.lists, 0)
end)
test("opening Mission Control cancels a pending focus action", function()
  local desktop = harness()
  desktop:arrive(202, true)
  desktop.missionControl = true
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.clicks, 0)
  assertEqual(desktop.module.status().busy, false)
end)
test("a newer switch cancels focus before its next run-loop turn", function()
  local desktop = harness()
  desktop.module.switchSpace(2)
  desktop:advance(0.3, 1)
  assertEqual(desktop.space, 202)
  assertEqual(desktop.lists, 1)
  assertEqual(desktop:countFocus(), 0)
  desktop.module.switchSpace(1)
  assertEqual(desktop.writes[#desktop.writes][2], 1)
  desktop:advance(0.4)
  assertEqual(desktop.focused, 1)
  assertEqual(desktop:countFocus(), 1)
end)

test("a newer switch during a window snapshot prevents the old focus action", function()
  local desktop = harness()
  desktop.module.switchSpace(2)
  desktop.listing = function()
    desktop.module.switchSpace(1)
  end
  desktop:advance(0.4)
  assertEqual(desktop.space, 101)
  assertEqual(desktop.focused, 1)
  assertEqual(desktop:countFocus(), 1)
  for _, command in ipairs(desktop.writes) do
    if command[1] == "focus" then
      assertEqual(command[2], 1)
    end
  end
end)

test("a missing Space times out and a failed reply stops, once and without retrying", function()
  for _, options in ipairs({ { noArrival = true }, { spaceError = true } }) do
    local desktop = harness(options)
    -- windowManager replies only once the display shows the Space.
    desktop.noReply = options.noArrival
    desktop.module.switchSpace(2)
    desktop:advance(0.1)
    if options.noArrival then
      assertEqual(desktop.module.status().last, nil)
      assertEqual(desktop.module.status().busy, true)
      assertEqual(#desktop.alerts, 0)
      desktop:advance(1.5)
    end
    local message = options.noArrival and "timed out waiting for Space 2" or "display unavailable"
    assertEqual(desktop.module.status().last.ok, false)
    assertEqual(desktop.module.status().last.error, message)
    assertEqual(desktop.module.status().busy, false)
    desktop:advance(2)
    assertEqual(desktop.space, 101)
    assertEqual(desktop.lists, 0)
    assertEqual(#desktop.writes, 1)
    assertEqual(#desktop.alerts, 1)
    assertEqual(desktop.logs[#desktop.logs], "Space focus: " .. message)
  end
end)

test("a Space notification after an ok reply restores focus", function()
  local desktop = harness({ lateArrival = true })
  desktop.module.switchSpace(2)
  desktop:advance(0.0015)
  assertEqual(desktop.module.status().last, nil)
  assertEqual(desktop.module.status().busy, true)
  assertEqual(desktop.lists, 0)
  desktop:advance(0.3)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(desktop.space, 202)
  assertEqual(desktop.focused, 2)
  assertEqual(desktop:countFocus(), 1)
  assertEqual(#desktop.logs, 0)
  assertEqual(#desktop.alerts, 0)
end)

test("app or window focus after an ok reply restores focus without a Space event", function()
  for _, notify in ipairs({ "app", "window" }) do
    local desktop = harness({ lateArrival = true, notify = notify })
    desktop.module.switchSpace(2)
    desktop:advance(0.3)
    assertEqual(desktop.module.status().last.ok, true)
    assertEqual(desktop.space, 202)
    assertEqual(desktop.focused, 2)
    assertEqual(desktop:countFocus(), 1)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("a press between the reply and the Space arrival supersedes cleanly", function()
  local desktop = harness({ lateArrival = true })
  desktop.module.switchSpace(2)
  desktop:advance(0.0015)
  desktop.module.switchSpace(3)
  assertEqual(desktop.module.status().last.space, 202)
  assertEqual(desktop.module.status().last.error, "superseded")
  assertEqual(#desktop.writes, 2)
  desktop:advance(0.3)
  assertEqual(desktop.module.status().last.space, 303)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(desktop.space, 303)
  assertEqual(desktop.focused, nil)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.logs, 0)
  assertEqual(#desktop.alerts, 0)
end)

test("a reversal before the first reply switches back without queuing or retrying", function()
  local desktop = harness()
  desktop.module.switchSpace(2)
  desktop.module.switchSpace(1)
  assertEqual(#desktop.writes, 2)
  desktop:advance(0.3)
  assertEqual(desktop.module.status().last.ok, true)
  assertEqual(desktop.space, 101)
  assertEqual(desktop.focused, 1)
  assertEqual(#desktop.alerts, 0)
  local switches = 0
  for _, command in ipairs(desktop.writes) do
    if command[1] == "space" then
      switches = switches + 1
    end
  end
  assertEqual(switches, 2)
end)

local function pip(options)
  local desktop = harness(options)
  desktop:add({ id = 61, pid = 500, app = "Browser", title = "News", space = 101 })
  desktop:add({ id = 60, pid = 500, app = "Browser", title = "Mail", space = 202 })
  desktop.recent = { [60] = 2, [61] = 1 }
  return desktop
end

test("activation onto PiP continues to the app's most recent real window", function()
  for _, case in ipairs({ { true }, { false }, { true, true }, { true, false, true } }) do
    local loaded = case[1]
    -- Without Screen Recording, titles come from the tracked windows instead.
    local desktop = pip({ noSwitcher = not loaded, noTitles = case[2] })
    if case[3] then
      desktop:add({ id = 4, pid = 104, app = "Finder", title = "Dock", space = 101 })
    end
    -- Without the switcher, the lowest tracked ID wins.
    desktop.recent = { [61] = 2 }
    desktop:activate(50)
    assertEqual(desktop:countFocus(), 1)
    desktop:advance(0.3)
    assertEqual(desktop:countFocus(), 1)
    assertEqual(desktop.focused, loaded and 61 or 60)
    assertEqual(desktop.space, loaded and 101 or 202)
    assertEqual(desktop.module.status().busy, false)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("activation reads the focused window only for an app with an on-screen PiP", function()
  local desktop = pip()
  desktop.accessibilityReads = {}
  desktop:activate(1)
  desktop:row(50).hidden = true
  desktop:activate(61)
  assertEqual(next(desktop.accessibilityReads), nil)
  desktop:row(50).hidden = nil
  desktop:activate(50)
  assertEqual(desktop.accessibilityReads.app, 1)
  -- PiP title and bounds come from the WindowServer entry.
  assertEqual(desktop.accessibilityReads[50], nil)
  assertEqual(desktop:countFocus(60), 1)
end)

test("PiP redirect uses tracked windows in ID order and switcher recency", function()
  for _, loaded in ipairs({ true, false }) do
    local desktop = harness({ noSwitcher = not loaded })
    desktop:add({ id = 64, pid = 500, app = "Browser", title = "Mail", space = 202 })
    desktop:add({ id = 63, pid = 500, app = "Browser", title = "News", space = 101 })
    desktop:add({
      id = 62,
      pid = 500,
      app = "Browser",
      title = "Draft",
      space = 101,
      minimized = true,
    })
    desktop:add({ id = 61, pid = 500, app = "Browser", title = "PiP", space = 0, layer = 3 })
    desktop:add({
      id = 60,
      pid = 500,
      app = "Browser",
      title = "Tab",
      space = 101,
      untracked = true,
    })
    desktop.recent = { [60] = 10, [61] = 9, [62] = 8, [64] = 2, [63] = 1 }
    desktop:activate(50)
    assertEqual(#desktop.writes, 1)
    assertEqual(table.concat(desktop.writes[1], " "), "focus " .. (loaded and 64 or 63) .. " 500")
    desktop:advance(0.3)
    assertEqual(desktop.focused, loaded and 64 or 63)
    assertEqual(#desktop.writes, 1)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("activation during a Space job or its transition does not redirect PiP", function()
  -- A busy Cmd-Tab leaves the transition without a job.
  for _, case in ipairs({ "job", "transition", "busy" }) do
    local desktop = pip()
    desktop.module.switchSpace(2)
    if case ~= "job" then
      desktop:advance(0.1)
      assertEqual(desktop.module.status().busy, false)
    end
    desktop.busy = case == "busy"
    desktop:activate(50)
    desktop:advance(0.3)
    for _, command in ipairs(desktop.writes) do
      assert(command[2] ~= 60 and command[2] ~= 61)
    end
    desktop:advance(1)
    desktop:activate(50)
    assertEqual(desktop:countFocus(60), 1)
  end
end)

test("PiP activation without another eligible app window does nothing", function()
  for _, loaded in ipairs({ true, false }) do
    local desktop = harness({ noSwitcher = not loaded })
    desktop:add({
      id = 62,
      pid = 500,
      app = "Browser",
      title = "Mail",
      space = 101,
      minimized = true,
    })
    desktop:add({ id = 63, pid = 500, app = "Browser", title = "PiP", space = 0, layer = 3 })
    desktop:add({
      id = 64,
      pid = 500,
      app = "Browser",
      title = "News",
      space = 202,
      untracked = true,
    })
    desktop:activate(50)
    desktop:advance(0.3)
    assertEqual(#desktop.writes, 0)
    assertEqual(desktop.focused, 50)
    assertEqual(#desktop.logs, 0)
    assertEqual(#desktop.alerts, 0)
  end
end)

test("a failed PiP redirect logs and alerts once without retrying", function()
  local desktop = pip({ focusError = true })
  desktop:activate(50)
  desktop:advance(2)
  assertEqual(desktop:countFocus(), 1)
  assertEqual(desktop.focused, 50)
  assertEqual(#desktop.logs, 1)
  assertEqual(#desktop.alerts, 1)
  assert(desktop.logs[1]:find("window unavailable", 1, true))
end)

test("non-PiP activations and other app events keep existing behaviour", function()
  local desktop = pip()
  desktop:activate(61)
  desktop:activate(nil, 900)
  desktop.appCallback(nil, 1, nil)
  desktop.focused = 50
  desktop.appCallback(nil, 2, desktop:app(500))
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 0)
  assertEqual(#desktop.alerts, 0)
end)

test("PiP focus shortly after activating a real window is redirected", function()
  local desktop = pip()
  desktop:activate(61)
  desktop:advance(0.015)
  assertEqual(desktop:countFocus(), 0)
  desktop:focus(50)
  assertEqual(desktop:countFocus(), 1)
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 1)
  assertEqual(desktop.focused, 60)
  assertEqual(desktop.space, 202)
  assertEqual(#desktop.alerts, 0)
end)

test("PiP focus without an activation of its app does not redirect", function()
  for _, other in ipairs({ false, true }) do
    local desktop = pip()
    if other then
      desktop:activate(1)
    end
    desktop:focus(50)
    desktop:advance(0.3)
    assertEqual(desktop:countFocus(), 0)
    assertEqual(desktop.focused, 50)
  end
end)

test("PiP focus that returns within 0.5 s after a redirect is redirected again", function()
  local desktop = pip()
  desktop.recent = { [61] = 2 }
  desktop:activate(50)
  desktop:advance(0.043)
  assertEqual(desktop:countFocus(), 1)
  assertEqual(desktop.focused, 61)
  desktop:focus(50)
  assertEqual(desktop:countFocus(), 2)
  desktop:advance(0.1)
  assertEqual(desktop.focused, 61)
  desktop:advance(0.4)
  desktop:focus(50)
  desktop:advance(0.3)
  assertEqual(desktop:countFocus(), 2)
  assertEqual(desktop.focused, 50)
end)

test("PiP activation or later PiP focus with the pointer over PiP does not redirect", function()
  for _, later in ipairs({ false, true }) do
    local desktop = pip()
    desktop.mouse = { x = 450, y = 400 }
    desktop:activate(later and 61 or 50)
    if later then
      desktop:focus(50)
    end
    desktop:advance(0.3)
    assertEqual(desktop:countFocus(), 0)
    assertEqual(desktop.focused, 50)
  end
end)

test("shutdown stops arrow interception", function()
  local desktop = harness()
  desktop:loadShortcuts()
  desktop.module.stop()
  assertEqual(desktop.module.keys:isEnabled(), false)
  assertEqual(desktop:key("keyDown", "right", { ctrl = true }), false)
end)
print("RESULT " .. passed .. " passed, 0 failed")

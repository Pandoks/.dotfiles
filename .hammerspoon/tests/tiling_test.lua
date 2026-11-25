local root = assert(arg[1])
local passed = 0
local function test(name, body)
  body()
  passed = passed + 1
  print("PASS " .. name)
end
local function assertEqual(actual, expected, label)
  if actual ~= expected then
    error(
      string.format(
        "%s: expected %s, got %s",
        label or "value",
        tostring(expected),
        tostring(actual)
      ),
      2
    )
  end
end

local function rect(left, top, width, height)
  return setmetatable({ x = left, y = top, w = width, h = height }, {
    __index = function(self, key)
      if key == "center" then
        return { x = self.x + self.w / 2, y = self.y + self.h / 2 }
      elseif key == "equals" then
        return function(_, other)
          return self.x == other.x and self.y == other.y and self.w == other.w and self.h == other.h
        end
      end
    end,
  })
end

-- Spaces 1 and 4 on a 1000x600 display, Space 2 on one to its right, Space 3 on none.
local function fakeDesktop(windowSpecs)
  local desktop = {
    subscribers = {},
    frames = {},
    focusedId = nil,
    logs = {},
    focusRequests = {},
    frameRequests = {},
    windowSpaceListeners = {},
    doAfterTimers = {},
    failFrame = false,
    windows = {},
    mouseButtons = {},
    counts = {
      getWindows = 0,
      spaces = 0,
      frame = 0,
      spaceDisplay = 0,
      windowFrame = 0,
      appName = 0,
      appHidden = 0,
      doAfter = 0,
    },
    screenWatcher = function() end,
    spaceWatcher = function() end,
  }
  local function fakeWindow(spec)
    local app = {
      name = function()
        desktop.counts.appName = desktop.counts.appName + 1
        return spec.app
      end,
      pid = function()
        return spec.pid or spec.id * 10
      end,
      isHidden = function()
        desktop.counts.appHidden = desktop.counts.appHidden + 1
        return spec.hidden == true
      end,
    }
    return {
      id = function()
        return spec.id
      end,
      application = function()
        if spec.transientNilApp then
          return nil
        end
        return app
      end,
      title = function()
        return spec.title or ""
      end,
      isStandard = function()
        return spec.standard ~= false
      end,
      isMinimized = function()
        return spec.minimized == true
      end,
      isFullScreen = function()
        return spec.fullscreen == true
      end,
      frame = function()
        desktop.counts.windowFrame = desktop.counts.windowFrame + 1
        return desktop.frames[spec.id]
      end,
    },
      app
  end
  function desktop:windowSpec(id)
    for _, entry in ipairs(self.windows) do
      if entry.spec.id == id then
        return entry.spec
      end
    end
    return {}
  end
  function desktop:add(spec)
    local window, app = fakeWindow(spec)
    self.windows[#self.windows + 1] = { spec = spec, window = window, app = app }
  end
  for _, spec in ipairs(windowSpecs) do
    desktop:add(spec)
  end
  local filterPredicate
  local filterDeleted = false
  local allowedById = {}
  local function windowState(entry)
    return {
      id = entry.spec.id,
      pid = entry.spec.pid or entry.spec.id * 10,
      standard = entry.spec.standard ~= false,
      title = entry.spec.title or "",
      minimized = entry.spec.minimized == true,
    }
  end
  local function matches(entry, window)
    if filterDeleted or entry.spec.tracked == false then
      return false
    end
    local allowed = entry.spec.eligible ~= false
      and (
        not filterPredicate
        or filterPredicate(window or entry.window, entry.app, windowState(entry)) == true
      )
    allowedById[entry.spec.id] = allowed
    return allowed
  end
  local filter = {
    windowCreated = "created",
    windowDestroyed = "destroyed",
    windowMinimized = "minimized",
    windowUnminimized = "unminimized",
    windowHidden = "hidden",
    windowUnhidden = "unhidden",
    windowTitleChanged = "title",
    windowMoved = "moved",
    windowFocused = "focused",
    applicationOf = function(id)
      for _, entry in ipairs(desktop.windows) do
        if entry.spec.id == id and entry.spec.tracked ~= false then
          return entry.app
        end
      end
    end,
    new = function(predicate)
      filterPredicate = predicate
      for _, entry in ipairs(desktop.windows) do
        matches(entry)
      end
      return {
        subscribe = function(_, events, callback)
          for _, event in ipairs(type(events) == "table" and events or { events }) do
            desktop.subscribers[event] = callback
          end
        end,
        getWindows = function()
          desktop.counts.getWindows = desktop.counts.getWindows + 1
          if filterDeleted then
            return {}
          end
          local matching = {}
          for _, entry in ipairs(desktop.windows) do
            if matches(entry) then
              matching[#matching + 1] = entry.window
            end
          end
          return matching
        end,
        getWindow = function(_, id, pid)
          if filterDeleted then
            return nil
          end
          for _, entry in ipairs(desktop.windows) do
            if
              entry.spec.id == id
              and (entry.spec.pid or id * 10) == pid
              and entry.spec.tracked ~= false
            then
              if matches(entry) then
                return entry.window
              end
              return nil
            end
          end
        end,
        delete = function()
          filterDeleted = true
          allowedById = {}
        end,
      }
    end,
  }
  local function unused(name)
    return function()
      error(name .. " must not be called")
    end
  end
  local function place(_, id, x, y, width, height, done)
    desktop.counts.frame = desktop.counts.frame + 1
    desktop.frameRequests[#desktop.frameRequests + 1] = id
    if desktop.failFrame then
      done(false, "failed")
      return
    end
    desktop.frames[id] = rect(x, y, width, height)
    done(true)
  end
  local windowManager = {
    native = {
      spaces = function(ids)
        desktop.counts.spaces = desktop.counts.spaces + 1
        local spacesById = {}
        for _, id in ipairs(ids) do
          spacesById[id] = desktop:windowSpec(id).space or 1
        end
        return spacesById
      end,
      focus = function(pid, id, done)
        desktop.focusRequests[#desktop.focusRequests + 1] = { pid = pid, id = id, done = done }
      end,
      cancelFocus = unused("native.cancelFocus"),
      focusedWindow = unused("native.focusedWindow"),
      frame = place,
      minimize = unused("native.minimize"),
      windows = unused("native.windows"),
      displaySpaces = unused("native.displaySpaces"),
      watchWindowSpaces = unused("native.watchWindowSpaces"),
    },
    space = unused("windowManager.space"),
    focus = unused("windowManager.focus"),
    isBusy = unused("windowManager.isBusy"),
    focusedTarget = unused("windowManager.focusedTarget"),
    windows = unused("windowManager.windows"),
    stop = unused("windowManager.stop"),
    watchWindowSpaces = function(callback)
      desktop.windowSpaceListeners[callback] = true
      return function()
        desktop.windowSpaceListeners[callback] = nil
      end
    end,
    frame = place,
    spaceOf = function(id)
      return desktop:windowSpec(id).space or 1
    end,
  }
  local function watcherFor(key)
    return {
      new = function(callback)
        desktop[key] = callback
        return {
          start = function(self)
            return self
          end,
          stop = function() end,
        }
      end,
    }
  end
  local environment = setmetatable({
    print = function() end,
    hs = {
      geometry = {
        copy = function(source)
          return rect(source.x, source.y, source.w, source.h)
        end,
      },
      screen = {
        -- hs.screen.find matches names too, so "" matches the first.
        find = function(hint)
          local left = ({ display = 0, other = 1000, [""] = 0 })[hint]
          return left
            and {
              frame = function()
                return rect(left, 0, desktop.width or 1000, 600)
              end,
            }
        end,
        watcher = watcherFor("screenWatcher"),
      },
      mouse = {
        getButtons = function()
          return desktop.mouseButtons
        end,
      },
      timer = {
        doAfter = function(_, callback)
          desktop.counts.doAfter = desktop.counts.doAfter + 1
          local timer = { callback = callback, active = true }
          function timer:stop()
            self.active = false
          end
          desktop.doAfterTimers[#desktop.doAfterTimers + 1] = timer
          return timer
        end,
      },
      eventtap = {
        event = { types = { leftMouseUp = "up" } },
        new = function(_, callback)
          desktop.releaseMouse = callback
          return {
            start = function(self)
              return self
            end,
            stop = function() end,
          }
        end,
      },
      spaces = {
        spaceDisplay = function(space)
          desktop.counts.spaceDisplay = desktop.counts.spaceDisplay + 1
          return ({ [1] = "display", [2] = "other", [4] = "display" })[space]
        end,
        activeSpaces = function()
          return { display = 1, other = 2 }
        end,
        focusedSpace = function()
          return 1
        end,
        watcher = watcherFor("spaceWatcher"),
      },
      window = {
        focusedWindow = function()
          for _, entry in ipairs(desktop.windows) do
            if entry.spec.id == desktop.focusedId then
              return entry.window
            end
          end
        end,
      },
    },
    require = function(name)
      if name == "lib.window_filter" then
        return filter
      elseif name == "lib.window_manager" then
        return windowManager
      elseif name == "lib.logger" then
        return {
          error = function(message)
            desktop.logs[#desktop.logs + 1] = message
          end,
        }
      end
      error("unexpected require " .. name)
    end,
  }, { __index = _G })
  desktop.tiling = assert(loadfile(root .. "/tiling.lua", "t", environment))()
  desktop.tiling.manage({ "Helium", "Ghostty", "Slack", "Notion Calendar", "T3 Code (Beta)" })
  local forbidden = setmetatable({}, {
    __index = function(_, key)
      error("synchronous Accessibility read: " .. tostring(key))
    end,
  })
  function desktop:event(name, id)
    local callback = self.subscribers[name]
    if not callback or filterDeleted then
      return
    end
    if name == "destroyed" then
      if not allowedById[id] then
        return
      end
      allowedById[id] = nil
      local app, state
      for _, entry in ipairs(self.windows) do
        if entry.spec.id == id then
          app, state = entry.spec.app, windowState(entry)
          break
        end
      end
      callback(forbidden, app, name, id, state)
      return
    end
    for _, entry in ipairs(self.windows) do
      if entry.spec.id == id then
        if matches(entry, forbidden) then
          callback(forbidden, entry.spec.app, name, id, windowState(entry))
        end
        return
      end
    end
  end
  function desktop:drag(id, frame)
    self.frames[id] = frame
    for _, entry in ipairs(self.windows) do
      if entry.spec.id == id then
        if matches(entry) and self.subscribers.moved then
          self.subscribers.moved(entry.window, entry.spec.app, "moved", id, windowState(entry))
        end
        return
      end
    end
  end
  function desktop:remove(id)
    for i, entry in ipairs(self.windows) do
      if entry.spec.id == id then
        table.remove(self.windows, i)
        break
      end
    end
    self.frames[id] = nil
    self:event("destroyed", id)
  end
  function desktop:frame(id)
    local frame = self.frames[id]
    return frame and string.format("%d,%d %dx%d", frame.x, frame.y, frame.w, frame.h) or "none"
  end
  function desktop:emitWindowSpace(id, space, added, pid)
    local snapshot = {}
    for listener in pairs(self.windowSpaceListeners) do
      snapshot[#snapshot + 1] = listener
    end
    for _, listener in ipairs(snapshot) do
      listener(id, space, added, pid)
    end
  end
  function desktop:flushSpaceSync()
    for _, timer in ipairs(self.doAfterTimers) do
      if timer.active then
        timer.active = false
        timer.callback()
      end
    end
  end
  return desktop
end

test("new windows split the last tile along its longer side", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" } })
  assertEqual(desktop:frame(1), "0,0 1000x600", "single window fills the display")
  desktop:add({ id = 2, app = "Slack" })
  desktop:event("created", 2)
  assertEqual(desktop:frame(1), "0,0 500x600", "wide tile splits side by side")
  assertEqual(desktop:frame(2), "500,0 500x600")
  desktop:add({ id = 3, app = "Helium" })
  desktop:event("created", 3)
  assertEqual(desktop:frame(2), "500,0 500x300", "tall tile splits top and bottom")
  assertEqual(desktop:frame(3), "500,300 500x300")
end)

test("only allowlisted apps tile, and Picture-in-Picture is left alone", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Finder" },
    { id = 3, app = "Helium", title = "Picture in Picture" },
  })
  assertEqual(desktop:frame(1), "0,0 1000x600")
  assertEqual(desktop:frame(2), "none", "other apps are never moved")
  assertEqual(desktop:frame(3), "none", "PiP is never moved")
end)

test("minimizing or hiding a window frees its tile until it returns", function()
  for _, case in ipairs({ { "minimized", "unminimized" }, { "hidden", "unhidden" } }) do
    local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
    desktop:windowSpec(1)[case[1]] = true
    desktop:event(case[1], 1)
    assertEqual(desktop:frame(2), "0,0 1000x600", case[1])
    desktop:windowSpec(1)[case[1]] = nil
    desktop:event(case[2], 1)
    assertEqual(desktop:frame(1), "500,0 500x600", case[2])
  end
end)

test("closing a window gives its tile to its sibling", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack" },
    { id = 3, app = "Helium" },
  })
  desktop:remove(2)
  assertEqual(desktop:frame(1), "0,0 500x600")
  assertEqual(desktop:frame(3), "500,0 500x600")
end)

test("focus moves to the neighbor in a direction", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop.focusedId = 1
  desktop.tiling.focus("east")
  assertEqual(desktop.focusRequests[1].id, 2)
  assertEqual(desktop.focusRequests[1].pid, 20)
  desktop.focusRequests[1].done(true)
  desktop.focusRequests[1].done(false, "superseded")
  assertEqual(#desktop.logs, 0, "ok and superseded focus do not log")
  desktop.focusRequests[1].done(false, "raise failed (-25204)")
  assertEqual(desktop.logs[1], "Tiling: focus failed: raise failed (-25204)")
  desktop.tiling.focus("north")
  assertEqual(#desktop.focusRequests, 1, "no window above")
  assertEqual(desktop.logs[2], "Tiling: no window to the north")
end)

test("swap exchanges tiles; warp splits the neighbor on the side moved toward", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack" },
    { id = 3, app = "Helium" },
  })
  desktop.focusedId = 1
  desktop.tiling.swap("east")
  assertEqual(desktop:frame(1), "500,0 500x300", "swap takes the neighbor's tile")
  assertEqual(desktop:frame(2), "0,0 500x600")
  desktop.tiling.warp("west")
  assertEqual(desktop:frame(1), "0,0 250x600", "warp west lands on the west half of the neighbor")
  assertEqual(desktop:frame(2), "250,0 250x600")
  assertEqual(desktop:frame(3), "500,0 500x600", "the vacated tile closes")
end)

test("resize moves the requested edge, or the opposite one at the screen's edge", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop.focusedId = 2
  desktop.tiling.resize("left", -100)
  assertEqual(desktop:frame(1), "0,0 400x600")
  assertEqual(desktop:frame(2), "400,0 600x600")
  desktop.focusedId = 1
  desktop.tiling.resize("left", -20)
  assertEqual(desktop:frame(1), "0,0 380x600", "no left edge: the right edge moves left")
  assertEqual(desktop:frame(2), "380,0 620x600")
  desktop.tiling.resize("top", -20)
  assertEqual(desktop:frame(1), "0,0 380x600", "no split on either vertical edge")
  assertEqual(desktop.logs[1], "Tiling: no other window to resize against")
  desktop.tiling.balance()
  assertEqual(desktop:frame(1), "0,0 500x600", "balance restores equal halves")
end)

test("a window resized by hand moves the splits on the dragged edges once released", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack" },
    { id = 3, app = "Helium" },
  })
  desktop.mouseButtons = { true }
  desktop:drag(2, rect(300, 0, 700, 400))
  assertEqual(desktop:frame(1), "0,0 500x600", "neighbors wait for the release")
  desktop.releaseMouse()
  desktop.mouseButtons = {}
  assertEqual(desktop:frame(1), "0,0 300x600", "the left edge moved the outer split")
  assertEqual(desktop:frame(2), "300,0 700x400", "the bottom edge moved the inner split")
  assertEqual(desktop:frame(3), "300,400 700x200")
  desktop.mouseButtons = { true }
  desktop:drag(1, rect(0, 0, 300, 700))
  desktop.releaseMouse()
  desktop.mouseButtons = {}
  assertEqual(desktop:frame(1), "0,0 300x600", "the screen's edge has no split to move")
end)

test("columns lay a Space out side by side in equal widths until toggled back", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack" },
    { id = 3, app = "Helium" },
  })
  desktop.focusedId = 1
  desktop.tiling.columns()
  assertEqual(desktop:frame(1), "0,0 333x600", "existing windows keep their order")
  assertEqual(desktop:frame(2), "333,0 334x600")
  assertEqual(desktop:frame(3), "667,0 333x600")
  desktop:add({ id = 4, app = "Slack" })
  desktop:event("created", 4)
  assertEqual(desktop:frame(1), "0,0 250x600", "a new window adds a column")
  assertEqual(desktop:frame(4), "750,0 250x600")
  desktop.tiling.resize("right", 100)
  assertEqual(desktop:frame(1), "0,0 350x600")
  desktop:remove(4)
  assertEqual(desktop:frame(1), "0,0 333x600", "a closed window's column is shared out")
  assertEqual(desktop:frame(3), "667,0 333x600")
  desktop.tiling.resize("right", 100)
  desktop.tiling.balance()
  assertEqual(desktop:frame(1), "0,0 333x600", "balance evens the columns")
  desktop.tiling.columns()
  assertEqual(desktop:frame(1), "0,0 500x600", "toggling back splits again")
  assertEqual(desktop:frame(2), "500,0 500x300")
  assertEqual(desktop:frame(3), "500,300 500x300")
end)

test("zoom fills the Space and float leaves the layout until toggled back", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop.focusedId = 1
  desktop.tiling.zoom()
  assertEqual(desktop:frame(1), "0,0 1000x600")
  desktop.tiling.zoom()
  assertEqual(desktop:frame(1), "0,0 500x600")
  desktop.tiling.float()
  assertEqual(desktop:frame(2), "0,0 1000x600", "the other window takes the whole Space")
  assertEqual(desktop.tiling.status()[1].override, "float", "status reports floated override")
  assertEqual(desktop.tiling.status()[1].space, nil)
  desktop.tiling.float()
  assertEqual(desktop:frame(1), "500,0 500x600", "re-tiled windows are inserted last")
  assertEqual(desktop:frame(2), "0,0 500x600")
  assertEqual(desktop.tiling.status()[1].space, 1)
  assertEqual(desktop.tiling.status()[1].override, nil)
end)

test("existing windows tile in most-recently-used order", function()
  local desktop = fakeDesktop({
    { id = 3, app = "Ghostty" },
    { id = 1, app = "Slack" },
    { id = 2, app = "Helium" },
  })
  assertEqual(desktop:frame(3), "0,0 500x600", "most recent first")
  assertEqual(desktop:frame(1), "500,0 500x300")
  assertEqual(desktop:frame(2), "500,300 500x300")
end)

test("a Space without a display is left alone instead of using another screen", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty", space = 3 } })
  assertEqual(desktop:frame(1), "none")
end)

test("a window moved by hand snaps back, after the drag when the mouse is down", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop:drag(1, rect(100, 100, 300, 300))
  assertEqual(desktop:frame(1), "0,0 500x600", "released moves snap back at once")
  desktop.mouseButtons = { true }
  desktop:drag(1, rect(100, 100, 300, 300))
  assertEqual(desktop:frame(1), "100,100 300x300", "a drag in progress is left alone")
  desktop.mouseButtons = {}
  desktop.releaseMouse()
  assertEqual(desktop:frame(1), "0,0 500x600", "the release snaps it back")
end)

test("a window moved to another display tiles there, after the drag when there is one", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop:windowSpec(1).space = 2
  desktop:drag(1, rect(1200, 100, 300, 300))
  assertEqual(desktop:frame(1), "1000,0 1000x600", "a drop fills the other display")
  assertEqual(desktop:frame(2), "0,0 1000x600", "the window left behind takes the Space")
  desktop:windowSpec(1).space = 1
  desktop.mouseButtons = { true }
  desktop:drag(1, rect(100, 100, 300, 300))
  assertEqual(desktop:frame(1), "100,100 300x300", "a drag crossing back is left alone")
  desktop.windows[2].spec.title = "renamed"
  desktop:event("title", 2)
  assertEqual(desktop:frame(1), "100,100 300x300", "other window events wait for the release too")
  assertEqual(desktop:frame(2), "0,0 1000x600")
  -- The button still reads as held during the release.
  desktop.releaseMouse()
  desktop.mouseButtons = {}
  assertEqual(desktop:frame(2), "0,0 500x600", "the release retiles both displays")
  assertEqual(desktop:frame(1), "500,0 500x600")
end)

test("a window moved to another Space on the same display retiles both once released", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop:windowSpec(1).space = 4
  desktop.releaseMouse()
  desktop.mouseButtons = { true }
  desktop:emitWindowSpace(1, 4, true, 10)
  desktop:flushSpaceSync()
  assertEqual(desktop:frame(2), "500,0 500x600", "a new drag waits for its own release")
  desktop.mouseButtons = {}
  desktop.releaseMouse()
  assertEqual(desktop:frame(2), "0,0 1000x600", "the window left behind takes the Space")
  assertEqual(desktop:frame(1), "0,0 1000x600", "the moved window fills its new Space")
end)

test("a tiled window entering fullscreen leaves the layout instead of snapping back", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop:windowSpec(1).fullscreen = true
  desktop:drag(1, rect(0, 0, 1000, 600))
  assertEqual(desktop:frame(1), "0,0 1000x600", "left alone")
  assertEqual(desktop:frame(2), "0,0 1000x600", "the other window takes the Space")
end)

test("focus reaches a zoomed window on the other display", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack", space = 2 },
    { id = 3, app = "Helium", space = 2 },
  })
  desktop.focusedId = 3
  desktop.tiling.zoom()
  assertEqual(desktop:frame(3), "1000,0 1000x600")
  desktop.focusedId = 1
  desktop.tiling.focus("east")
  assertEqual(desktop.focusRequests[1].id, 3, "the zoomed window is the one showing")
end)

test("non-PiP title changes skip sync, while Picture-in-Picture toggles still sync", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty", title = "zsh" },
    { id = 2, app = "Helium", title = "Docs" },
    { id = 3, app = "Helium", title = "Picture in Picture" },
    { id = 4, app = "Slack", title = "General" },
  })
  desktop.focusedId = 4
  desktop.tiling.float()
  local getWindows, spaces = desktop.counts.getWindows, desktop.counts.spaces
  assertEqual(desktop.subscribers.focused, nil, "tiling does not subscribe to focus events")

  desktop:windowSpec(1).title = "vim"
  desktop:event("title", 1)
  desktop:windowSpec(4).title = "Random"
  desktop:event("title", 4)
  desktop:windowSpec(3).title = "PiP"
  desktop:event("title", 3)
  assertEqual(desktop.counts.getWindows, getWindows, "non-PiP title updates skip getWindows")
  assertEqual(desktop.counts.spaces, spaces, "non-PiP title updates skip spaces query")

  desktop:windowSpec(2).title = "Picture-in-Picture"
  desktop:event("title", 2)
  assertEqual(desktop.counts.getWindows, getWindows + 1, "entering PiP syncs")
  assertEqual(desktop.counts.spaces, spaces + 1)
  assertEqual(desktop:frame(1), "0,0 1000x600")

  desktop:windowSpec(2).title = "Docs"
  desktop:event("title", 2)
  assertEqual(desktop.counts.getWindows, getWindows + 2, "leaving PiP syncs")
  assertEqual(desktop.counts.spaces, spaces + 2)
  assertEqual(desktop:frame(1), "0,0 500x600")
  assertEqual(desktop:frame(2), "500,0 500x600")

  desktop:windowSpec(3).title = "Browser"
  desktop:event("title", 3)
  assertEqual(desktop.counts.getWindows, getWindows + 3, "initial PiP leaving PiP syncs")
  assertEqual(desktop.counts.spaces, spaces + 3)
  assertEqual(desktop:frame(3), "500,300 500x300")
end)

test(
  "apply skips unchanged sibling frames while snapping back moved windows and retrying failures",
  function()
    local desktop = fakeDesktop({
      { id = 1, app = "Ghostty" },
      { id = 2, app = "Slack" },
      { id = 3, app = "Helium" },
      { id = 4, app = "Ghostty" },
    })
    desktop.focusedId = 1
    desktop.frameRequests = {}
    desktop.tiling.swap("east")
    assertEqual(#desktop.frameRequests, 2, "swap only frames the 2 swapped windows")
    local swapped = { [desktop.frameRequests[1]] = true, [desktop.frameRequests[2]] = true }
    assertEqual(swapped[1] and swapped[2], true, "swapped IDs are 1 and 2")

    local resizeDesktop = fakeDesktop({
      { id = 1, app = "Ghostty" },
      { id = 2, app = "Slack" },
      { id = 3, app = "Helium" },
    })
    resizeDesktop.focusedId = 2
    resizeDesktop.frameRequests = {}
    resizeDesktop.tiling.resize("bottom", 50)
    assertEqual(#resizeDesktop.frameRequests, 2, "resize only frames the 2 changed windows")
    local resized =
      { [resizeDesktop.frameRequests[1]] = true, [resizeDesktop.frameRequests[2]] = true }
    assertEqual(resized[2] and resized[3], true, "resized IDs are 2 and 3")

    resizeDesktop.frameRequests = {}
    resizeDesktop:drag(1, rect(100, 100, 300, 300))
    assertEqual(resizeDesktop:frame(1), "0,0 500x600", "moved window snaps back")
    assertEqual(#resizeDesktop.frameRequests, 1, "only snapped-back window is framed")
    assertEqual(resizeDesktop.frameRequests[1], 1)

    resizeDesktop.mouseButtons = { true }
    resizeDesktop:drag(1, rect(100, 100, 300, 300))
    resizeDesktop.mouseButtons = {}
    resizeDesktop.frameRequests = {}
    resizeDesktop.releaseMouse()
    assertEqual(resizeDesktop:frame(1), "0,0 500x600", "dragged window snaps back on release")
    assertEqual(#resizeDesktop.frameRequests, 1, "release only reframes dragged window")
    assertEqual(resizeDesktop.frameRequests[1], 1)

    local failDesktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
    failDesktop.focusedId = 2
    failDesktop.failFrame = true
    failDesktop.tiling.resize("left", -100)
    assertEqual(#failDesktop.logs, 2, "failed frame updates log errors")
    failDesktop.failFrame = false
    failDesktop.frameRequests = {}
    failDesktop.tiling.resize("left", 0)
    assertEqual(
      #failDesktop.frameRequests,
      2,
      "failed frames are cleared and retried on next apply"
    )
  end
)

test("area caches spaceDisplay calls until screen or Space watchers fire", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack" },
    { id = 3, app = "Helium", space = 3 },
    { id = 4, app = "Slack", space = 2 },
  })
  local before = desktop.counts.spaceDisplay
  desktop.focusedId = 1
  desktop.tiling.focus("east")
  desktop.tiling.swap("east")
  desktop.tiling.resize("left", -50)
  desktop.tiling.balance()
  desktop:add({ id = 5, app = "Ghostty", space = 3 })
  desktop:event("created", 5)
  assertEqual(
    desktop.counts.spaceDisplay,
    before,
    "cached hits and misses make no new spaceDisplay calls"
  )

  local framesBefore = desktop.counts.frame
  desktop.screenWatcher()
  assertEqual(desktop.counts.spaceDisplay > before, true, "screenWatcher invalidates area cache")
  assertEqual(
    desktop.counts.frame > framesBefore,
    true,
    "screenWatcher clears applied cache and reapplies"
  )

  local afterScreen = desktop.counts.spaceDisplay
  desktop.tiling.balance()
  assertEqual(desktop.counts.spaceDisplay, afterScreen, "cached again after screenWatcher")

  desktop.spaceWatcher()
  assertEqual(
    desktop.counts.spaceDisplay > afterScreen,
    true,
    "spaceWatcher invalidates area cache"
  )
end)

test("focus skips window:frame for tiled windows and falls back otherwise", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack" },
    { id = 3, app = "Helium" },
  })
  desktop.focusedId = 3
  desktop.tiling.float()
  desktop.frames[3] = rect(0, 0, 200, 600)

  local before = desktop.counts.windowFrame
  desktop.focusedId = 1
  desktop.tiling.focus("east")
  assertEqual(desktop.counts.windowFrame, before, "tiled window uses cached layout frame")
  assertEqual(desktop.focusRequests[1].id, 2)

  desktop.focusedId = 3
  desktop.tiling.focus("east")
  assertEqual(desktop.counts.windowFrame, before + 1, "unmanaged window falls back to window:frame")
  assertEqual(desktop.focusRequests[2].id, 2)
end)

test("sync memoizes per-PID app queries", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty", pid = 999 },
    { id = 2, app = "Ghostty", pid = 999 },
    { id = 3, app = "Ghostty", pid = 999 },
  })
  desktop.counts.appHidden = 0
  desktop.counts.appName = 0
  desktop:add({ id = 4, app = "Ghostty", pid = 999 })
  desktop:event("created", 4)
  assertEqual(desktop.counts.appHidden, 1, "app:isHidden memoized per PID during sync")
  assertEqual(desktop.counts.appName, 6, "app:name called once in manageable plus predicate calls")
end)

test("spaceWatcher skips AX window scan unless a tiled window moved Spaces or displays", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty", space = 1 },
    { id = 2, app = "Slack", space = 4 },
  })
  local getWindows, spaces = desktop.counts.getWindows, desktop.counts.spaces
  desktop.spaceWatcher()
  assertEqual(desktop.counts.getWindows, getWindows, "unchanged layout skips getWindows")
  assertEqual(desktop.counts.spaces, spaces + 1, "checks current spaces via SkyLight")

  -- Window moving to another Space still triggers full sync().
  desktop:windowSpec(1).space = 4
  desktop.spaceWatcher()
  assertEqual(desktop.counts.getWindows, getWindows + 1, "moved tiled window triggers sync")
  assertEqual(desktop:frame(1), "500,0 500x600")
  assertEqual(desktop:frame(2), "0,0 500x600")

  -- Display frame changes for a tiled Space reapply without re-scanning all windows.
  local framesBefore = desktop.counts.frame
  desktop.counts.getWindows = 0
  desktop.width = 1200
  desktop.spaceWatcher()
  assertEqual(desktop.counts.getWindows, 0, "resized display skips getWindows")
  assertEqual(desktop.counts.frame > framesBefore, true, "resized display reapplies frames")
  assertEqual(desktop:frame(2), "0,0 600x600")
  assertEqual(desktop:frame(1), "600,0 600x600")
end)

test("watchWindowSpaces coalesces Space moves and cleans up on stop", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty", space = 1 },
    { id = 2, app = "Slack", space = 1 },
  })
  local getWindows, spaces = desktop.counts.getWindows, desktop.counts.spaces
  -- Unmanaged window or redundant event is ignored / no-op after space verification.
  desktop:emitWindowSpace(999, 4, true, 99)
  desktop:emitWindowSpace(1, 1, true, 10)
  assertEqual(desktop.counts.doAfter, 0, "matching space addition skips scheduleSpaceSync")

  -- Noisy removal event where SkyLight still shows the old space skips full sync.
  desktop:emitWindowSpace(1, 1, false, 10)
  assertEqual(desktop.counts.doAfter, 1)
  desktop:flushSpaceSync()
  assertEqual(desktop.counts.spaces, spaces + 1)
  assertEqual(desktop.counts.getWindows, getWindows, "unchanged Space skips getWindows")

  -- Moving window 1 from Space 1 to Space 4 emits both 1325 and 1326 and coalesces into 1 sync.
  desktop:windowSpec(1).space = 4
  desktop:emitWindowSpace(1, 4, true, 10)
  desktop:emitWindowSpace(1, 1, false, 10)
  assertEqual(desktop.counts.doAfter, 2, "coalesces multiple events into one doAfter(0)")
  desktop:flushSpaceSync()
  assertEqual(desktop.counts.getWindows, getWindows + 1, "runs single sync on move")
  assertEqual(desktop:frame(2), "0,0 1000x600", "remaining window takes Space 1 immediately")
  assertEqual(desktop:frame(1), "0,0 1000x600", "moved window fills Space 4 immediately")

  local listenerCount = 0
  for _ in pairs(desktop.windowSpaceListeners) do
    listenerCount = listenerCount + 1
  end
  assertEqual(listenerCount, 1)
  desktop.tiling.stop()
  listenerCount = 0
  for _ in pairs(desktop.windowSpaceListeners) do
    listenerCount = listenerCount + 1
  end
  assertEqual(listenerCount, 0, "stop() unregisters watchWindowSpaces")
end)

test(
  "keeps window tiled and resizes it when window:application() transiently returns nil",
  function()
    local desktop = fakeDesktop({
      { id = 1, app = "Helium", space = 1 },
      { id = 2, app = "Ghostty", space = 1 },
    })
    assertEqual(desktop:frame(1), "0,0 500x600")
    assertEqual(desktop:frame(2), "500,0 500x600")

    -- Simulate Ghostty quitting while window:application() transiently fails for Helium.
    desktop:windowSpec(1).transientNilApp = true
    table.remove(desktop.windows, 2)
    desktop:event("destroyed", 2)
    assertEqual(desktop:frame(1), "0,0 1000x600", "Helium stays tiled and expands to full screen")

    -- Moving Helium still snaps back without needing to toggle float twice.
    desktop:drag(1, rect(100, 100, 400, 400))
    assertEqual(desktop:frame(1), "0,0 1000x600", "Helium remains managed and snaps back on move")
  end
)

test(
  "float tiles a non-allowlisted window until toggled back, leaving its app's other windows alone",
  function()
    local desktop = fakeDesktop({
      { id = 1, app = "Ghostty", pid = 10 },
      { id = 3, app = "Finder", pid = 20 },
      { id = 2, app = "Finder", pid = 20 },
    })
    assertEqual(desktop:frame(1), "0,0 1000x600")
    assertEqual(desktop:frame(2), "none")
    assertEqual(desktop:frame(3), "none")

    desktop.focusedId = 2
    desktop.tiling.float()
    assertEqual(desktop:frame(1), "0,0 500x600", "existing tile shares the Space")
    assertEqual(desktop:frame(2), "500,0 500x600", "toggled non-allowlisted window inserts last")
    assertEqual(desktop:frame(3), "none", "other windows of the same app stay untouched")
    assertEqual(desktop.tiling.status()[2].space, 1)
    assertEqual(desktop.tiling.status()[2].override, "tile")
    assertEqual(desktop.tiling.status()[3], nil)

    desktop:drag(2, rect(100, 100, 300, 300))
    assertEqual(desktop:frame(2), "500,0 500x600", "opted-in window snaps back on move")

    desktop.tiling.swap("west")
    assertEqual(desktop:frame(2), "0,0 500x600", "opted-in window participates in swap")
    assertEqual(desktop:frame(1), "500,0 500x600")

    desktop:windowSpec(2).minimized = true
    desktop:event("minimized", 2)
    assertEqual(desktop:frame(1), "0,0 1000x600", "minimizing an opted-in window frees its tile")
    desktop:windowSpec(2).minimized = nil
    desktop:event("unminimized", 2)
    assertEqual(desktop:frame(1), "0,0 500x600")
    assertEqual(desktop:frame(2), "500,0 500x600", "unminimizing re-tiles the opted-in window")
    assertEqual(desktop:frame(3), "none")

    desktop:windowSpec(2).hidden = true
    desktop:windowSpec(3).hidden = true
    desktop:event("hidden", 2)
    assertEqual(desktop:frame(1), "0,0 1000x600", "hiding its app frees an opted-in window's tile")
    desktop:windowSpec(2).hidden = nil
    desktop:windowSpec(3).hidden = nil
    desktop:event("unhidden", 2)
    assertEqual(desktop:frame(2), "500,0 500x600", "unhiding its app re-tiles the opted-in window")
    assertEqual(desktop:frame(3), "none")

    desktop.tiling.float()
    assertEqual(desktop:frame(1), "0,0 1000x600", "second toggle lets sibling reclaim the Space")
    assertEqual(desktop.tiling.status()[2], nil)

    local getWindows = desktop.counts.getWindows
    desktop:drag(2, rect(120, 120, 320, 240))
    assertEqual(desktop:frame(2), "120,120 320x240", "untiled window no longer snaps back")
    desktop:windowSpec(2).minimized = true
    desktop:event("minimized", 2)
    assertEqual(desktop.counts.getWindows, getWindows, "untiled window stops delivering events")
  end
)

test(
  "closing an opted-in window reclaims its Space and forgets the override, including while dragging",
  function()
    local desktop = fakeDesktop({
      { id = 1, app = "Ghostty" },
      { id = 2, app = "Finder" },
      { id = 3, app = "Finder" },
    })
    desktop.focusedId = 2
    desktop.tiling.float()
    assertEqual(desktop:frame(2), "500,0 500x600")
    desktop:remove(2)
    assertEqual(desktop:frame(1), "0,0 1000x600", "closing an opted-in window frees its tile")
    assertEqual(desktop.tiling.status()[2], nil, "override is forgotten on destroy")

    desktop:add({ id = 2, app = "Finder" })
    desktop:event("created", 2)
    assertEqual(desktop:frame(2), "none", "reused window ID stays untiled after destroy")

    -- Toggling while held defers layout until release and keeps filter state synced.
    desktop.mouseButtons = { true }
    desktop.focusedId = 2
    desktop.tiling.float()
    assertEqual(desktop:frame(2), "none", "layout waits for mouse release")
    desktop.releaseMouse()
    desktop.mouseButtons = {}
    assertEqual(desktop:frame(1), "0,0 500x600")
    assertEqual(desktop:frame(2), "500,0 500x600", "mouse release tiles the opted-in window")

    desktop.mouseButtons = { true }
    desktop.tiling.float()
    desktop.tiling.float()
    desktop.releaseMouse()
    desktop.mouseButtons = {}
    assertEqual(desktop:frame(2), "500,0 500x600", "double toggle while held keeps tiled state")

    desktop.mouseButtons = { true }
    desktop.tiling.float()
    desktop.releaseMouse()
    desktop.mouseButtons = {}
    assertEqual(desktop:frame(1), "0,0 1000x600", "mouse release untiles after held toggle off")
    assertEqual(desktop.tiling.status()[2], nil)

    desktop.mouseButtons = { true }
    desktop.focusedId = 3
    desktop.tiling.float()
    desktop:remove(3)
    assertEqual(desktop.tiling.status()[3], nil, "destroy before mouse release forgets override")
    desktop.releaseMouse()
    desktop.mouseButtons = {}
    assertEqual(desktop:frame(1), "0,0 1000x600")
  end
)

test("float fails fast and changes nothing when the focused window cannot be tiled", function()
  local desktop = fakeDesktop({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Raycast", tracked = false },
    { id = 3, app = "Finder", eligible = false },
    { id = 4, app = "Finder", standard = false },
    { id = 5, app = "Finder", fullscreen = true },
    { id = 6, app = "Ghostty", fullscreen = true },
    { id = 7, app = "Helium", title = "Picture in Picture" },
    { id = 8, app = "Safari", title = "Picture-in-Picture" },
    { id = 9, app = "Finder", minimized = true },
  })
  assertEqual(desktop:frame(1), "0,0 1000x600")

  for _, case in ipairs({
    { label = "no focused window", id = nil },
    { label = "untracked window", id = 2 },
    { label = "ineligible window", id = 3 },
    { label = "nonstandard window", id = 4 },
    { label = "fullscreen non-allowlisted window", id = 5 },
    { label = "fullscreen allowlisted window", id = 6 },
    { label = "allowlisted PiP window", id = 7 },
    { label = "non-allowlisted PiP window", id = 8 },
    { label = "minimized window", id = 9 },
  }) do
    local logsBefore = #desktop.logs
    local framesBefore = desktop.counts.frame
    desktop.focusedId = case.id
    desktop.tiling.float()
    assertEqual(#desktop.logs, logsBefore + 1, case.label .. " logs an error")
    assertEqual(desktop.counts.frame, framesBefore, case.label .. " moves nothing")
    assertEqual(desktop:frame(1), "0,0 1000x600", case.label .. " leaves tiled layout intact")
    if case.id then
      assertEqual(desktop.tiling.status()[case.id], nil, case.label .. " records no override")
    end
  end

  -- Rejected float on a fullscreen allowlisted window must not float it after exit.
  desktop:windowSpec(6).fullscreen = nil
  desktop:event("unminimized", 6)
  assertEqual(desktop:frame(6), "500,0 500x600", "allowlisted window still tiles once normal")
end)

print("RESULT " .. passed .. " passed, 0 failed")

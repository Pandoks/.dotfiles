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
    windows = {},
    mouseButtons = {},
    runSpaceCheck = function() end,
  }
  local function fakeWindow(spec)
    local app = {
      name = function()
        return spec.app
      end,
      pid = function()
        return spec.id * 10
      end,
      isHidden = function()
        return spec.hidden == true
      end,
    }
    return {
      id = function()
        return spec.id
      end,
      application = function()
        return app
      end,
      title = function()
        return spec.title or ""
      end,
      isStandard = function()
        return true
      end,
      isMinimized = function()
        return spec.minimized == true
      end,
      isFullScreen = function()
        return spec.fullscreen == true
      end,
      frame = function()
        return desktop.frames[spec.id]
      end,
    }
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
    self.windows[#self.windows + 1] = { spec = spec, window = fakeWindow(spec) }
  end
  for _, spec in ipairs(windowSpecs) do
    desktop:add(spec)
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
    new = function(predicate)
      return {
        subscribe = function(_, events, callback)
          for _, event in ipairs(type(events) == "table" and events or { events }) do
            desktop.subscribers[event] = callback
          end
        end,
        getWindows = function()
          local matching = {}
          for _, entry in ipairs(desktop.windows) do
            if predicate(entry.window) then
              matching[#matching + 1] = entry.window
            end
          end
          return matching
        end,
        delete = function() end,
      }
    end,
  }
  local windowManager = {
    native = {
      spaces = function(ids)
        local spacesById = {}
        for _, id in ipairs(ids) do
          spacesById[id] = desktop:windowSpec(id).space or 1
        end
        return spacesById
      end,
      focus = function(pid, id)
        desktop.focusRequests[#desktop.focusRequests + 1] = { pid = pid, id = id }
      end,
    },
    frame = function(_, id, x, y, width, height, done)
      desktop.frames[id] = rect(x, y, width, height)
      done(true)
    end,
    spaceOf = function(id)
      return desktop:windowSpec(id).space or 1
    end,
  }
  local watcher = {
    new = function()
      return {
        start = function(self)
          return self
        end,
        stop = function() end,
      }
    end,
  }
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
                return rect(left, 0, 1000, 600)
              end,
            }
        end,
        watcher = watcher,
      },
      mouse = {
        getButtons = function()
          return desktop.mouseButtons
        end,
      },
      timer = {
        delayed = {
          new = function(_, callback)
            return {
              start = function()
                desktop.runSpaceCheck = callback
              end,
              stop = function() end,
            }
          end,
        },
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
          return ({ [1] = "display", [2] = "other", [4] = "display" })[space]
        end,
        activeSpaces = function()
          return { display = 1, other = 2 }
        end,
        focusedSpace = function()
          return 1
        end,
        watcher = watcher,
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
  function desktop:event(name, id)
    local callback = self.subscribers[name]
    if callback then
      callback(nil, nil, name, id)
    end
  end
  function desktop:drag(id, frame)
    self.frames[id] = frame
    for _, entry in ipairs(self.windows) do
      if entry.spec.id == id then
        self.subscribers.moved(entry.window, entry.spec.app, "moved", id)
      end
    end
  end
  function desktop:remove(id)
    for i, entry in ipairs(self.windows) do
      if entry.spec.id == id then
        table.remove(self.windows, i)
      end
    end
    self:event("destroyed", id)
  end
  function desktop:frame(id)
    local frame = self.frames[id]
    return frame and string.format("%d,%d %dx%d", frame.x, frame.y, frame.w, frame.h) or "none"
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

test("a window renamed to Picture-in-Picture leaves the layout", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Helium" } })
  assertEqual(desktop:frame(1), "0,0 500x600")
  desktop.windows[2].spec.title = "Picture-in-Picture"
  desktop:event("title", 2)
  assertEqual(desktop:frame(1), "0,0 1000x600", "remaining window takes the space back")
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
  desktop.tiling.focus("north")
  assertEqual(#desktop.focusRequests, 1, "no window above")
  assertEqual(desktop.logs[1], "Tiling: no window to the north")
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

test("resize moves only the requested edge, and never the opposite one", function()
  local desktop = fakeDesktop({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  desktop.focusedId = 2
  desktop.tiling.resize("left", -100)
  assertEqual(desktop:frame(1), "0,0 400x600")
  assertEqual(desktop:frame(2), "400,0 600x600")
  desktop.focusedId = 1
  desktop.tiling.resize("left", -20)
  assertEqual(desktop:frame(1), "0,0 400x600", "no left edge: nothing moves")
  assertEqual(desktop.logs[1], "Tiling: no left edge to move")
  desktop.tiling.balance()
  assertEqual(desktop:frame(1), "0,0 500x600", "balance restores equal halves")
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
  desktop.tiling.float()
  assertEqual(desktop:frame(1), "500,0 500x600", "re-tiled windows are inserted last")
  assertEqual(desktop:frame(2), "0,0 500x600")
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
  desktop.runSpaceCheck()
  assertEqual(desktop:frame(2), "500,0 500x600", "a new drag waits for its own release")
  desktop.mouseButtons = {}
  desktop.releaseMouse()
  desktop.runSpaceCheck()
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

print("RESULT " .. passed .. " passed, 0 failed")

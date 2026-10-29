local root = assert(arg[1])
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
local function eq(actual, expected, label)
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

local function rect(x, y, w, h)
  return setmetatable({ x = x, y = y, w = w, h = h }, {
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

-- A 1000x600 display showing Space 1 and, to its right, one showing Space 2. Windows are
-- {id, app, title?, space?}; Space 3 has no display, and Space 4 is another on the first.
local function harness(rows)
  local h = {
    subscribed = {},
    frames = {},
    focused = nil,
    logs = {},
    focuses = {},
    windows = {},
    buttons = {},
    settle = function() end,
  }
  local function window(row)
    local app = {
      name = function()
        return row.app
      end,
      pid = function()
        return row.id * 10
      end,
      isHidden = function()
        return row.hidden == true
      end,
    }
    return {
      id = function()
        return row.id
      end,
      application = function()
        return app
      end,
      title = function()
        return row.title or ""
      end,
      isStandard = function()
        return true
      end,
      isMinimized = function()
        return row.minimized == true
      end,
      isFullScreen = function()
        return row.fullscreen == true
      end,
      frame = function()
        return h.frames[row.id]
      end,
    }
  end
  function h:row(id)
    for _, entry in ipairs(self.windows) do
      if entry.row.id == id then
        return entry.row
      end
    end
    return {}
  end
  function h:add(row)
    self.windows[#self.windows + 1] = { row = row, window = window(row) }
  end
  for _, row in ipairs(rows) do
    h:add(row)
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
        -- Like the real filter, only subscribed events are delivered.
        subscribe = function(_, events, fn)
          for _, event in ipairs(type(events) == "table" and events or { events }) do
            h.subscribed[event] = fn
          end
        end,
        getWindows = function()
          local out = {}
          for _, entry in ipairs(h.windows) do
            if predicate(entry.window) then
              out[#out + 1] = entry.window
            end
          end
          return out
        end,
        delete = function() end,
      }
    end,
  }
  local windowManager = {
    native = {
      spaces = function(ids)
        local out = {}
        for _, id in ipairs(ids) do
          out[id] = h:row(id).space or 1
        end
        return out
      end,
      focus = function(pid, id)
        h.focuses[#h.focuses + 1] = { pid = pid, id = id }
      end,
    },
    frame = function(_, id, x, y, w, hgt, done)
      h.frames[id] = rect(x, y, w, hgt)
      done(true)
    end,
    spaceOf = function(id)
      return h:row(id).space or 1
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
  local env = setmetatable({
    print = function() end,
    hs = {
      geometry = {
        copy = function(r)
          return rect(r.x, r.y, r.w, r.h)
        end,
      },
      screen = {
        -- Like Hammerspoon, a hint that isn't a UUID matches screen names, so "" matches the first.
        find = function(hint)
          local x = ({ display = 0, other = 1000, [""] = 0 })[hint]
          return x
            and {
              frame = function()
                return rect(x, 0, 1000, 600)
              end,
            }
        end,
        watcher = watcher,
      },
      mouse = {
        getButtons = function()
          return h.buttons
        end,
      },
      timer = {
        delayed = {
          new = function(_, fn)
            return {
              start = function()
                h.settle = fn
              end,
              stop = function() end,
            }
          end,
        },
      },
      eventtap = {
        event = { types = { leftMouseUp = "up" } },
        new = function(_, fn)
          h.release = fn
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
          for _, entry in ipairs(h.windows) do
            if entry.row.id == h.focused then
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
            h.logs[#h.logs + 1] = message
          end,
        }
      end
      error("unexpected require " .. name)
    end,
  }, { __index = _G })
  h.tiling = assert(loadfile(root .. "/tiling.lua", "t", env))()
  h.tiling.manage({ "Helium", "Ghostty", "Slack", "Notion Calendar", "T3 Code (Nightly)" })
  function h:event(name, id)
    local callback = self.subscribed[name]
    if callback then
      callback(nil, nil, name, id)
    end
  end
  -- The user moves a window to `frame` by hand.
  function h:drag(id, frame)
    self.frames[id] = frame
    for _, entry in ipairs(self.windows) do
      if entry.row.id == id then
        self.subscribed.moved(entry.window, entry.row.app, "moved", id)
      end
    end
  end
  function h:remove(id)
    for i, entry in ipairs(self.windows) do
      if entry.row.id == id then
        table.remove(self.windows, i)
      end
    end
    self:event("destroyed", id)
  end
  function h:frame(id)
    local f = self.frames[id]
    return f and string.format("%d,%d %dx%d", f.x, f.y, f.w, f.h) or "none"
  end
  return h
end

test("new windows split the last tile along its longer side", function()
  local h = harness({ { id = 1, app = "Ghostty" } })
  eq(h:frame(1), "0,0 1000x600", "single window fills the display")
  h:add({ id = 2, app = "Slack" })
  h:event("created", 2)
  eq(h:frame(1), "0,0 500x600", "wide tile splits side by side")
  eq(h:frame(2), "500,0 500x600")
  h:add({ id = 3, app = "Helium" })
  h:event("created", 3)
  eq(h:frame(2), "500,0 500x300", "tall tile splits top and bottom")
  eq(h:frame(3), "500,300 500x300")
end)

test("only allowlisted apps tile, and Picture-in-Picture is left alone", function()
  local h = harness({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Finder" },
    { id = 3, app = "Helium", title = "Picture in Picture" },
  })
  eq(h:frame(1), "0,0 1000x600")
  eq(h:frame(2), "none", "other apps are never moved")
  eq(h:frame(3), "none", "PiP is never moved")
end)

test("a window renamed to Picture-in-Picture leaves the layout", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Helium" } })
  eq(h:frame(1), "0,0 500x600")
  h.windows[2].row.title = "Picture-in-Picture"
  h:event("title", 2)
  eq(h:frame(1), "0,0 1000x600", "remaining window takes the space back")
end)

test("minimizing or hiding a window frees its tile until it returns", function()
  for _, case in ipairs({ { "minimized", "unminimized" }, { "hidden", "unhidden" } }) do
    local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
    h:row(1)[case[1]] = true
    h:event(case[1], 1)
    eq(h:frame(2), "0,0 1000x600", case[1])
    h:row(1)[case[1]] = nil
    h:event(case[2], 1)
    eq(h:frame(1), "500,0 500x600", case[2])
  end
end)

test("closing a window gives its tile to its sibling", function()
  local h =
    harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" }, { id = 3, app = "Helium" } })
  h:remove(2)
  eq(h:frame(1), "0,0 500x600")
  eq(h:frame(3), "500,0 500x600")
end)

test("focus moves to the neighbor in a direction", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  h.focused = 1
  h.tiling.focus("east")
  eq(h.focuses[1].id, 2)
  eq(h.focuses[1].pid, 20)
  h.tiling.focus("north")
  eq(#h.focuses, 1, "no window above")
  eq(h.logs[1], "Tiling: no window to the north")
end)

test("swap exchanges tiles; warp splits the neighbor on the side moved toward", function()
  local h =
    harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" }, { id = 3, app = "Helium" } })
  h.focused = 1
  h.tiling.swap("east")
  eq(h:frame(1), "500,0 500x300", "swap takes the neighbor's tile")
  eq(h:frame(2), "0,0 500x600")
  h.tiling.warp("west")
  eq(h:frame(1), "0,0 250x600", "warp west lands on the west half of the neighbor")
  eq(h:frame(2), "250,0 250x600")
  eq(h:frame(3), "500,0 500x600", "the vacated tile closes")
end)

test("resize moves only the requested edge, and never the opposite one", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  h.focused = 2
  h.tiling.resize("left", -100)
  eq(h:frame(1), "0,0 400x600")
  eq(h:frame(2), "400,0 600x600")
  h.focused = 1
  h.tiling.resize("left", -20)
  eq(h:frame(1), "0,0 400x600", "no left edge: nothing moves")
  eq(h.logs[1], "Tiling: no left edge to move")
  h.tiling.balance()
  eq(h:frame(1), "0,0 500x600", "balance restores equal halves")
end)

test("zoom fills the Space and float leaves the layout until toggled back", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  h.focused = 1
  h.tiling.zoom()
  eq(h:frame(1), "0,0 1000x600")
  h.tiling.zoom()
  eq(h:frame(1), "0,0 500x600")
  h.tiling.float()
  eq(h:frame(2), "0,0 1000x600", "the other window takes the whole Space")
  h.tiling.float()
  eq(h:frame(1), "500,0 500x600", "re-tiled windows are inserted last")
  eq(h:frame(2), "0,0 500x600")
end)

test("existing windows tile in most-recently-used order", function()
  local h =
    harness({ { id = 3, app = "Ghostty" }, { id = 1, app = "Slack" }, { id = 2, app = "Helium" } })
  eq(h:frame(3), "0,0 500x600", "most recent first")
  eq(h:frame(1), "500,0 500x300")
  eq(h:frame(2), "500,300 500x300")
end)

test("a Space without a display is left alone instead of using another screen", function()
  local h = harness({ { id = 1, app = "Ghostty", space = 3 } })
  eq(h:frame(1), "none")
end)

test("a window moved by hand snaps back, after the drag when the mouse is down", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  h:drag(1, rect(100, 100, 300, 300))
  eq(h:frame(1), "0,0 500x600", "released moves snap back at once")
  h.buttons = { true }
  h:drag(1, rect(100, 100, 300, 300))
  eq(h:frame(1), "100,100 300x300", "a drag in progress is left alone")
  h.buttons = {}
  h.release()
  eq(h:frame(1), "0,0 500x600", "the release snaps it back")
end)

test("a window moved to another display tiles there, after the drag when there is one", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  h:row(1).space = 2
  h:drag(1, rect(1200, 100, 300, 300))
  eq(h:frame(1), "1000,0 1000x600", "a drop fills the other display")
  eq(h:frame(2), "0,0 1000x600", "the window left behind takes the Space")
  h:row(1).space = 1
  h.buttons = { true }
  h:drag(1, rect(100, 100, 300, 300))
  eq(h:frame(1), "100,100 300x300", "a drag crossing back is left alone")
  h.windows[2].row.title = "renamed"
  h:event("title", 2)
  eq(h:frame(1), "100,100 300x300", "other window events wait for the release too")
  eq(h:frame(2), "0,0 1000x600")
  h.buttons = {}
  h.release()
  eq(h:frame(2), "0,0 500x600", "the release retiles both displays")
  eq(h:frame(1), "500,0 500x600")
end)

test("a window moved to another Space on the same display retiles both once released", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  h:row(1).space = 4
  h.release()
  h.buttons = { true }
  h.settle()
  eq(h:frame(2), "500,0 500x600", "a new drag waits for its own release")
  h.buttons = {}
  h.release()
  h.settle()
  eq(h:frame(2), "0,0 1000x600", "the window left behind takes the Space")
  eq(h:frame(1), "0,0 1000x600", "the moved window fills its new Space")
end)

test("a tiled window entering fullscreen leaves the layout instead of snapping back", function()
  local h = harness({ { id = 1, app = "Ghostty" }, { id = 2, app = "Slack" } })
  h:row(1).fullscreen = true
  h:drag(1, rect(0, 0, 1000, 600))
  eq(h:frame(1), "0,0 1000x600", "left alone")
  eq(h:frame(2), "0,0 1000x600", "the other window takes the Space")
end)

test("focus reaches a zoomed window on the other display", function()
  local h = harness({
    { id = 1, app = "Ghostty" },
    { id = 2, app = "Slack", space = 2 },
    { id = 3, app = "Helium", space = 2 },
  })
  h.focused = 3
  h.tiling.zoom()
  eq(h:frame(3), "1000,0 1000x600")
  h.focused = 1
  h.tiling.focus("east")
  eq(h.focuses[1].id, 3, "the zoomed window is the one showing")
end)

print("RESULT " .. passed .. " passed, 0 failed")

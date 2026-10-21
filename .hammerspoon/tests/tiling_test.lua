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
      end
    end,
  })
end

-- One 1000x600 display showing Space 1, with windows given as {id, app, title?}.
local function harness(rows)
  local h = { frames = {}, focused = nil, logs = {}, focuses = {}, windows = {}, events = nil }
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
        return false
      end,
      frame = function()
        return h.frames[row.id]
      end,
    }
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
    new = function(predicate)
      return {
        subscribe = function(_, _, fn)
          h.events = fn
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
          out[id] = 1
        end
        return out
      end,
      focus = function(pid, id)
        h.focuses[#h.focuses + 1] = { pid = pid, id = id }
      end,
    },
    frame = function(_, id, x, y, w, hgt)
      h.frames[id] = rect(x, y, w, hgt)
    end,
    spaceOf = function()
      return 1
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
        find = function(uuid)
          return uuid == "display"
              and {
                frame = function()
                  return rect(0, 0, 1000, 600)
                end,
              }
            or nil
        end,
        watcher = watcher,
      },
      spaces = {
        spaceDisplay = function()
          return "display"
        end,
        activeSpaces = function()
          return { display = 1 }
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
    self.events(nil, nil, name, id)
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

print("RESULT " .. passed .. " passed, 0 failed")

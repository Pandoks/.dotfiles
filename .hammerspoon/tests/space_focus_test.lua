local root = assert(arg[1])
local passed = 0
local function eq(a, b)
  assert(a == b, tostring(a) .. " ~= " .. tostring(b))
end
local function clone(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for k, v in pairs(value) do
    out[k] = clone(v)
  end
  return out
end
local function outside(point, frame)
  return point.x < frame.x - 8
    or point.x >= frame.x + frame.w + 8
    or point.y < frame.y - 8
    or point.y >= frame.y + frame.h + 8
end
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
local function harness(options)
  local o = options or {}
  local h = {
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
    ax = {},
    displayReads = 0,
    shows = {},
  }
  local spaces = o.spaces
    or { { ManagedSpaceID = 101 }, { ManagedSpaceID = 202 }, { ManagedSpaceID = 303 } }
  h.space = o.space or h.space
  local function display(id)
    return o.displays and o.displays[id] or "display"
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
    h.ax[key] = (h.ax[key] or 0) + 1
  end
  -- Current Spaces of other displays.
  for _, id in ipairs(o.visible or {}) do
    h.visible[id] = true
  end
  h.rows = {}
  function h:row(id)
    for _, r in ipairs(self.rows) do
      if r.id == id then
        return r
      end
    end
  end
  function h:add(row)
    -- Windows default to their Space's display.
    local s = screens[display(row.space)] or screens.display
    row.frame = row.frame or { x = s.x + 20, y = s.y + 20, w = 300, h = 200 }
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
    {
      id = 93,
      pid = 910,
      app = "Dock",
      title = "Dock",
      space = 0,
      layer = 20,
      untracked = true,
      frame = { x = 0, y = 740, w = 1000, h = 60 },
    },
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
    h:add(row)
  end
  local function timer(delay, fn, repeatTimer)
    local t =
      { at = h.now + delay, active = true, delay = delay, callback = fn, repeating = repeatTimer }
    function t:stop()
      self.active = false
    end
    function t:setNextTrigger(seconds)
      self.at = h.now + seconds
    end
    h.timers[#h.timers + 1] = t
    return t
  end
  function h:advance(delay, limit)
    local count = 0
    local untilTime = self.now + delay
    while true do
      local nextTimer
      for _, t in ipairs(self.timers) do
        if t.active and t.at <= untilTime and (not nextTimer or t.at < nextTimer.at) then
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
      count = count + 1
      if count == limit then
        return
      end
    end
    self.now = untilTime
  end
  local function window(id)
    local r = h:row(id)
    if not r then
      return nil
    end
    local methods = {
      isStandard = function()
        return true
      end,
      isMinimized = function()
        return r.minimized == true
      end,
      title = function()
        return r.title
      end,
      id = function()
        return r.id
      end,
      frame = function()
        return clone(r.frame)
      end,
      application = function()
        return {
          name = function()
            return r.app
          end,
          pid = function()
            return r.pid
          end,
        }
      end,
    }
    for name, method in pairs(methods) do
      if name ~= "id" then
        methods[name] = function()
          read(r.id)
          return method()
        end
      end
    end
    return methods
  end
  function h:app(pid)
    return {
      pid = function()
        return pid
      end,
      focusedWindow = function()
        read("app")
        local r = self:row(self.focused)
        return r and r.pid == pid and window(r.id) or nil
      end,
    }
  end
  function h:focus(id)
    local r = self:row(id)
    -- Focusing a window on another Space switches to it before notifications arrive.
    local moved = r and r.space ~= 0 and r.space ~= self.space
    if moved then
      self.space = r.space
    end
    self.focused = id
    if moved and self.spaceCallback then
      self.spaceCallback()
    end
    if self.focusCallback then
      self.focusCallback(window(id))
    end
  end
  function h:activate(id, pid)
    self.focused = id
    self.appCallback(nil, 1, self:app(pid or self:row(id).pid))
  end
  -- The Space a display shows: an override, the focused Space, or another display's visible one.
  function h:current(uuid)
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
  function h:show(id)
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
  function h:shift(id)
    self.visible[self.space] = true
    self.visible[id] = nil
    self.space = id
  end
  function h:arrive(id, notify)
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
      subscribe = function(self, _, fn)
        h.focusCallback = fn
        return self
      end,
    }
  end
  -- lib.window_manager: the newest Space request supersedes a pending one; each replies once.
  local windowManager, pending = { native = {} }, nil
  function windowManager.space(index, done)
    h.writes[#h.writes + 1] = { "space", index }
    local id = spaces[index].ManagedSpaceID
    if pending then
      local old = pending
      pending = nil
      old.timer:stop()
      old.done(false, "superseded")
    end
    if o.spaceError then
      done(false, "display unavailable")
      return
    elseif h:current(display(id)) == id then
      done(true)
      return
    end
    local request = { done = done }
    pending = request
    request.timer = timer(0.001, function()
      pending = nil
      local function move()
        if o.away then
          -- The target is shown on its display; focus stays on the other one.
          h:show(id)
          if o.away == "pip" then
            h:focus(50)
          end
          return
        end
        h:arrive(id, o.notify == nil)
        if o.notify == "app" then
          h:activate(h.focused)
        elseif o.notify == "window" then
          h:focus(h.focused)
        end
      end
      if o.lateArrival then
        -- Focus can report the new Space just after its display does.
        timer(0.001, move)
      elseif not o.noArrival then
        move()
      end
      if h.beforeReply then
        h.beforeReply()
      end
      if not h.noReply then
        done(true)
      end
      -- Events queued behind the reply, before the next run-loop turn.
      if h.onReply then
        h.onReply()
      end
      if h.afterReply then
        timer(0.005, h.afterReply)
      end
    end)
  end
  function windowManager.native.focus(pid, id, done)
    h.writes[#h.writes + 1] = { "focus", id, pid }
    timer(0.004, function()
      local r = h:row(id)
      if o.focusError or not r or r.pid ~= pid then
        if done then
          done(false, "window unavailable")
        end
        return
      end
      if o.syncFocus then
        -- Focus can finish before the reply.
        h:focus(id)
      else
        timer(0.015, function()
          h:focus(id)
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
      for _, r in ipairs(h.rows) do
        if r.pid == pid and not r.untracked then
          windows[r.id] = window(r.id)
          ids[#ids + 1] = r.id
        end
      end
      -- Hash order is unspecified; iterate from the highest ID so callers must sort.
      table.sort(ids, function(a, b)
        return a > b
      end)
      return setmetatable(windows, {
        __pairs = function(t)
          local i = 0
          return function()
            i = i + 1
            return ids[i], t[ids[i]]
          end
        end,
      })
    end,
  }
  local hs = {
    application = {
      -- The desktop (no focused window) belongs to Finder.
      frontmostApplication = function()
        local r = h:row(h.focused)
        return {
          bundleID = function()
            return r and r.app or "com.apple.finder"
          end,
        }
      end,
      watcher = {
        activated = 1,
        deactivated = 2,
        new = function(callback)
          h.appCallback = callback
          return object()
        end,
      },
    },
    timer = {
      doAfter = function(d, f)
        return timer(d, f)
      end,
      doEvery = function()
        error("Space focus must not use repeating polling")
      end,
      secondsSinceEpoch = function()
        return h.now
      end,
    },
    spaces = {
      focusedSpace = function()
        return h.space
      end,
      spaceDisplay = function(id)
        h.displayReads = h.displayReads + 1
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
              ["Current Space"] = { ManagedSpaceID = h:current(space.display) or -1 },
            }
          end
        end
        return out
      end,
      watcher = {
        new = function(fn)
          h.spaceCallback = fn
          return object()
        end,
      },
    },
    screen = {
      find = function(name)
        local f = screens[name]
        return f
          and {
            frame = function()
              return clone(f)
            end,
            fullFrame = function()
              return clone(f)
            end,
          }
      end,
    },
    mouse = {
      absolutePosition = function()
        return clone(h.mouse)
      end,
    },
    geometry = {
      new = function(p)
        return {
          inside = function(_, r)
            return p.x >= r.x and p.y >= r.y and p.x <= r.x + r.w and p.y <= r.y + r.h
          end,
        }
      end,
    },
    window = {
      focusedWindow = function()
        read("focused")
        return window(h.focused)
      end,
      -- WindowServer on-screen list, front to back. Without `all`, Hammerspoon 1.1.1 keeps only the
      -- windows below the one titled "Dock", a title it reads with Screen Recording.
      list = function(all)
        h.lists = h.lists + 1
        if h.listing then
          local callback = h.listing
          h.listing = nil
          callback()
        end
        local rows, order = {}, {}
        for index, r in ipairs(h.rows) do
          local shown = r.space == 0 or h:current(display(r.space)) == r.space
          if shown and not r.minimized and not r.hidden then
            rows[#rows + 1], order[r] = r, index
          end
        end
        table.sort(rows, function(a, b)
          local left, right = a.layer or 0, b.layer or 0
          return left > right or (left == right and order[a] < order[b])
        end)
        if not all and not o.noTitles then
          for i, r in ipairs(rows) do
            if r.title == "Dock" then
              rows = { table.unpack(rows, i + 1) }
              break
            end
          end
        end
        local entries = {}
        for i, r in ipairs(rows) do
          local f = r.frame
          entries[i] = {
            kCGWindowNumber = r.id,
            kCGWindowOwnerPID = r.pid,
            kCGWindowOwnerName = r.app,
            kCGWindowName = not o.noTitles and r.title or nil,
            kCGWindowLayer = r.layer or 0,
            kCGWindowBounds = { X = f.x, Y = f.y, Width = f.w, Height = f.h },
          }
        end
        return entries
      end,
    },
    printf = function(fmt, ...)
      h.logs[#h.logs + 1] = string.format(fmt, ...)
    end,
    keycodes = { map = { left = 123, right = 124, a = 0 } },
    eventtap = {
      new = function(types, fn)
        if types[1] == 5 then
          h.keyCallback = fn
        else
          h.inputCallback = fn
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
        newMouseEvent = function(kind, point, mods)
          eq(next(mods), nil)
          local e = { props = {} }
          function e:setProperty(key, value)
            self.props[key] = value
            return self
          end
          function e:post()
            h.mouse = clone(point)
            if kind == 1 and h.beforeClick then
              -- Another click already queued ahead of this one reaches the tap first.
              local callback = h.beforeClick
              h.beforeClick = nil
              callback()
            end
            -- The tap sees clicks, not pointer moves.
            local dropped = kind ~= 4
              and h.inputCallback({
                getProperty = function(_, key)
                  return self.props[key] or 0
                end,
                getType = function()
                  return kind
                end,
              })
            if dropped then
              h.dropped = (h.dropped or 0) + 1
            elseif kind == 2 then
              h.clicks[#h.clicks + 1] = point
              local desktop = h.focused == nil
              timer(0.01, function()
                local moved
                for id in pairs(h.visible) do
                  local s = screens[display(id)]
                  if display(id) ~= display(h.space) and point.x >= s.x and point.x < s.x + s.w then
                    moved = id
                    break
                  end
                end
                if moved and not h.lateShift and not h.resteal then
                  h:shift(moved)
                end
                if desktop then
                  h.focused = nil
                elseif h.resteal then
                  -- PiP on the other display takes focus right back.
                  h.resteal = nil
                  h:focus(50)
                else
                  h:focus(nil)
                end
                -- Finder can activate before its display takes focus.
                if moved and h.lateShift then
                  h:shift(moved)
                end
              end)
            end
          end
          return e
        end,
      },
    },
  }
  local env = setmetatable({
    hs = hs,
    print = function(message)
      h.logs[#h.logs + 1] = message
    end,
    package = {
      loaded = {
        ["lib.window_switcher"] = not o.noSwitcher and {
          isBusy = function()
            return h.busy
          end,
          mostRecent = function(windows)
            local target
            for _, w in ipairs(windows) do
              if not target or (h.recent[w.id] or 0) > (h.recent[target.id] or 0) then
                target = w
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
            h.logs[#h.logs + 1] = message
            h.alerts[#h.alerts + 1] = message
          end,
        }
      elseif name == "lib.window_manager" then
        return windowManager
      elseif name == "lib.mission_control" then
        return {
          isActive = function()
            if h.beforeMissionControl then
              local callback = h.beforeMissionControl
              h.beforeMissionControl = nil
              callback()
            end
            return h.missionControl or false
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
  h.module = assert(loadfile(root .. "/space_focus.lua", "t", env))()
  function h:loadShortcuts()
    self.hotkeys = {}
    hs.hotkey = {
      bind = function(modifiers, key, fn)
        self.hotkeys[table.concat(modifiers, "+") .. ":" .. key] = fn
      end,
    }
    local prior = env.require
    env.require = function(name)
      if name == "lib.space_focus" then
        return self.module
      elseif name == "lib.tiling" then
        return { manage = function() end }
      else
        return prior(name)
      end
    end
    assert(loadfile(root .. "/../windows.lua", "t", env))()
  end
  function h:countFocus(id)
    local n = 0
    for _, c in ipairs(self.writes) do
      if c[1] == "focus" and (not id or c[2] == id) then
        n = n + 1
      end
    end
    return n
  end
  function h:click()
    return self.inputCallback({
      getProperty = function()
        return 0
      end,
      getType = function()
        return 1
      end,
    })
  end
  function h:key(kind, key, flags)
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
  return h
end

test("numbered Space moves focus from PiP to the Space's window", function()
  local h = harness()
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h.space, 202)
  eq(h.focused, 2)
  eq(h.module.status().last.ok, true)
  eq(h:countFocus(), 1)
end)
test("focus notification completes restoration synchronously", function()
  local h = harness()
  h.module.switchSpace(2)
  h:advance(0.021)
  eq(h.focused, 2)
  eq(h.module.status().busy, false)
end)
test("a focus reply completes restoration when focus changed first", function()
  local h = harness({ syncFocus = true })
  h.focusCallback = nil
  h.module.switchSpace(2)
  h:advance(0.006)
  eq(h.focused, 2)
  eq(h.module.status().busy, false)
  eq(h.module.status().last.ok, true)
end)
test("missing focus notification logs timeout without retrying", function()
  local h = harness()
  h.focusCallback = nil
  h.module.switchSpace(2)
  h:advance(0.1)
  eq(h.focused, 2)
  eq(h.module.status().busy, true)
  local lists = h.lists
  h:advance(1)
  eq(h.module.status().busy, false)
  eq(h.lists, lists)
  eq(h:countFocus(), 1)
  assert(h.logs[1]:find("timed out", 1, true))
end)
test("last normal window on the destination is remembered", function()
  local h = harness()
  h.space = 202
  h:focus(3)
  h:advance(0.05)
  h.space = 101
  h:focus(1)
  h:advance(0.05)
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h.focused, 3)
end)
test("the frontmost eligible window is focused when none is remembered", function()
  local h = harness()
  -- Send Shell (2) behind Docs (3).
  for i, r in ipairs(h.rows) do
    if r.id == 2 then
      h:add(table.remove(h.rows, i))
      break
    end
  end
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h.focused, 3)
  eq(h:countFocus(), 1)
end)
test("same-Space shortcut removes PiP focus too", function()
  local h = harness()
  h:focus(50)
  h.module.switchSpace(1)
  h:advance(0.3)
  eq(h.focused, 1)
end)
test("PID reuse cannot satisfy the remembered identity", function()
  local h = harness()
  h.space = 202
  h:focus(3)
  h:advance(0.05)
  h.space = 101
  h:focus(1)
  h:advance(0.05)
  h:row(3).pid = 999
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h.focused, 2)
end)
test("PiP, Hammerspoon, hidden and minimized windows are excluded", function()
  local h = harness()
  h:row(2).hidden = true
  h:row(3).minimized = true
  h:add({ id = 4, pid = 104, app = "Hammerspoon", title = "Console", space = 202 })
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h:countFocus(), 0)
  eq(#h.clicks, 1)
  eq(h.focused, nil)
end)
test("minimized and hidden windows are never candidates, even when remembered", function()
  for _, state in ipairs({ "minimized", "hidden" }) do
    local h = harness()
    h.space = 202
    h:focus(3)
    h:advance(0.05)
    h.space = 101
    h:focus(1)
    h:advance(0.05)
    h:row(3)[state] = true
    h.module.switchSpace(2)
    h:advance(0.3)
    eq(h.focused, 2)
    eq(h:countFocus(), 1)
  end
end)
test("untracked on-screen windows are never candidates but still cover the desktop", function()
  local h = harness()
  h:row(2).untracked = true
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h.focused, 3)
  eq(h:countFocus(), 1)
  h = harness()
  h:row(2).untracked, h:row(3).untracked = true, true
  h:row(2).frame = { x = 300, y = 250, w = 400, h = 300 }
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h:countFocus(), 0)
  eq(#h.clicks, 1)
  for _, id in ipairs({ 2, 3, 50 }) do
    assert(outside(h.clicks[1], h:row(id).frame))
  end
end)
test("layer-3 windows are never candidates, while a focused PiP is seen and avoided", function()
  for _, space in ipairs({ 202, 303 }) do
    local h = harness()
    h:add({
      id = 51,
      pid = 510,
      app = "Player",
      title = "Lecture",
      space = 0,
      layer = 3,
      frame = { x = 300, y = 330, w = 120, h = 120 },
    })
    h:arrive(space, true)
    h:advance(0.3)
    if space == 202 then
      eq(h.focused, 2)
      eq(h:countFocus(), 1)
      eq(#h.clicks, 0)
    else
      eq(h:countFocus(), 0)
      eq(#h.clicks, 1)
      assert(outside(h.clicks[1], h:row(50).frame))
      assert(outside(h.clicks[1], h:row(51).frame))
    end
  end
end)
test("windows on the other display's visible Space are excluded", function()
  local h =
    harness({ displays = { [101] = "left", [202] = "right", [303] = "left" }, visible = { 202 } })
  -- Shell and Docs stay on-screen, centered on the right display.
  h.module.switchSpace(3)
  h:advance(0.3)
  eq(h.space, 303)
  eq(h:countFocus(), 0)
  eq(#h.clicks, 1)
end)
test("an unavailable Space display fails once with a popup", function()
  local h = harness({ displays = { [202] = "gone" } })
  h.module.switchSpace(2)
  h:advance(2)
  eq(h.module.status().last.ok, false)
  eq(h.module.status().last.error, "Space display unavailable")
  eq(h.lists, 0)
  eq(h:countFocus(), 0)
  eq(#h.clicks, 0)
  eq(h.module.status().busy, false)
  eq(#h.alerts, 1)
  eq(h.logs[1], "Space focus: Space display unavailable")
end)
test("empty Space focuses uncovered desktop without returning to another Space", function()
  local h = harness()
  h.module.switchSpace(3)
  h:advance(0.3)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 1)
  eq(h:countFocus(), 0)
  eq(h.mouse.x, 17)
  eq(h.mouse.y, 23)
  assert(outside(h.clicks[1], h:row(50).frame))
end)
test("no desktop click is issued through a covering window", function()
  local h = harness()
  h:row(50).frame = { x = 0, y = 0, w = 1000, h = 800 }
  h.module.switchSpace(3)
  h:advance(0.3)
  eq(#h.clicks, 0)
  eq(h.module.status().last.ok, false)
end)
test("the desktop click misses a toast, which takes clicks above the windows", function()
  local h = harness()
  local frame = { x = 300, y = 380, w = 100, h = 40 }
  h:add({
    id = 92,
    pid = 920,
    app = "Hammerspoon",
    space = 0,
    layer = 25,
    untracked = true,
    frame = frame,
  })
  h.module.switchSpace(3)
  h:advance(0.3)
  eq(#h.clicks, 1)
  assert(outside(h.clicks[1], frame) and outside(h.clicks[1], h:row(50).frame))
end)
test("a Space change from outside the shortcuts moves focus from PiP", function()
  local h = harness()
  h:arrive(202, true)
  h:advance(0.3)
  eq(h.focused, 2)
end)
test("normal focus from an external Space change is preserved", function()
  local h = harness()
  h.space = 202
  h.focused = 3
  h.spaceCallback()
  h:advance(0.3)
  eq(h.focused, 3)
  eq(h:countFocus(), 0)
end)
test("late PiP focus notification is still corrected", function()
  local h = harness()
  h.space = 202
  h.focused = 3
  h.spaceCallback()
  h:advance(0.05)
  h:focus(50)
  h:advance(0.3)
  eq(h.focused, 2)
end)
test("already-visible monitor switch works without a Space event", function()
  local h = harness({ displays = { [101] = "left", [202] = "right" }, visible = { 202 } })
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h.focused, 2)
  eq(h:countFocus(), 1)
  eq(#h.alerts, 0)
  eq(h.module.status().last.ok, true)
end)
test("a Space change before the deferred focus cannot pull focus back", function()
  local h = harness()
  h:arrive(202, true)
  h:arrive(303, true)
  h:advance(0.4)
  eq(h.space, 303)
  eq(h:countFocus(), 0)
end)

test("a new Alt-number dispatches before the previous Space replies", function()
  local h = harness()
  h:loadShortcuts()
  h.hotkeys["alt:2"]()
  h.hotkeys["alt:3"]()
  eq(#h.writes, 2)
  eq(h.writes[2][2], 3)
  eq(h.space, 101)
  h:advance(0.3)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(h:countFocus(), 0)
  eq(h.module.status().busy, false)
  eq(#h.logs, 0)
  eq(#h.alerts, 0)
end)

test(
  "rapid Alt-number presses dispatch every switch but retain only the latest callback",
  function()
    local h = harness()
    h:loadShortcuts()
    h.hotkeys["alt:2"]()
    h:advance(0.005)
    h.hotkeys["alt:1"]()
    h.hotkeys["alt:2"]()
    h:advance(0.2)
    eq(h.space, 202)
    eq(h.focused, 2)
    local count = 0
    for _, command in ipairs(h.writes) do
      if command[1] == "space" then
        count = count + 1
        eq(command[2], ({ 2, 1, 2 })[count])
      else
        eq(command[2], 2)
      end
    end
    eq(count, 3)
    eq(h.module.status().busy, false)
    eq(#h.logs, 0)
  end
)

test("a Space change during a synchronous check cannot dispatch stale focus", function()
  for _, deferred in ipairs({ false, true }) do
    local h = harness()
    h.module.switchSpace(2)
    if deferred then
      -- Arrival only; the focus action waits for the next run-loop turn.
      h:advance(0.3, 1)
    end
    h.beforeMissionControl = function()
      h:arrive(101, false)
    end
    h:advance(0.3)
    eq(h.space, 101)
    eq(h:countFocus(), 0)
    eq(h.module.status().busy, false)
    eq(#h.alerts, 0)
  end
end)

test("mouse input and shutdown cancel the current job without undoing sent commands", function()
  for _, stop in ipairs({ false, true }) do
    local h = harness()
    h.module.switchSpace(2)
    h:advance(0.005, 1)
    h.module.switchSpace(3)
    if stop then
      h.module.stop()
    else
      h:click()
    end
    h:advance(0.15)
    eq(h.space, 303)
    eq(h:countFocus(), 0)
    eq(#h.clicks, 0)
    eq(#h.writes, 2)
    eq(h.module.status().busy, false)
    eq(h.module.status().active, not stop)
    eq(h.module.status().last.error, stop and "stopped" or "superseded")
  end
end)

test("rapid relative shortcuts advance from the pending destination", function()
  local h = harness()
  h.module.switchSpace("next")
  h.module.switchSpace("next")
  h:advance(0.3)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(h:countFocus(), 0)
end)
test("invalid request does not leave the controller busy", function()
  local h = harness()
  h.module.switchSpace(2)
  h.module.switchSpace(99)
  eq(#h.alerts, 1)
  h:advance(0.3)
  eq(h.module.status().busy, false)
end)
test("clicking PiP intentionally is not undone", function()
  local h = harness()
  h.space = 202
  h.focused = 3
  h.spaceCallback()
  h:advance(0.05)
  h:click()
  h:focus(50)
  h:advance(0.3)
  eq(h.focused, 50)
  eq(h:countFocus(), 0)
end)
test("mouse intent cancels a pending correction", function()
  local h = harness()
  h:arrive(202, true)
  h:click()
  h:advance(0.3)
  eq(h:countFocus(), 0)
  eq(#h.clicks, 0)
end)
test("Cmd-Tab exact-window operation takes priority", function()
  local h = harness()
  h.busy = true
  h:arrive(202, true)
  h:advance(0.3)
  eq(h:countFocus(), 0)
end)
test("idle controller takes no periodic window snapshots", function()
  local h = harness()
  h:advance(30)
  eq(h.lists, 0)
end)
test("actual numbered and Ctrl-arrow bindings use PiP-safe focus", function()
  local h = harness()
  h:loadShortcuts()
  h.hotkeys["alt:2"]()
  h:advance(0.3)
  eq(h.focused, 2)
  eq(h.hotkeys["ctrl:left"], nil)
  eq(h:key("keyDown", "left", { ctrl = true }), true)
  eq(h:key("keyUp", "left", {}), true)
  h:advance(0.3)
  eq(h.focused, 1)
  eq(h:key("keyDown", "right", { ctrl = true }), true)
  eq(h:key("keyUp", "right", { ctrl = true }), true)
  h:advance(0.3)
  eq(h.focused, 2)
end)
test("failed focus stops immediately and is never retried", function()
  local h = harness({ focusError = true })
  h.module.switchSpace(2)
  h:advance(0.07)
  eq(h.module.status().busy, false)
  eq(h.module.status().last.ok, false)
  eq(h:countFocus(), 1)
  eq(h.logs[1], "Space focus: window unavailable")
  local lists = h.lists
  h:advance(30)
  eq(h.lists, lists)
  eq(h:countFocus(), 1)
end)
test("relative navigation stops at both display boundaries", function()
  local h = harness({ displays = { [101] = "left", [202] = "right", [303] = "right" } })
  h.module.switchSpace("next")
  eq(#h.writes, 0)
  h.space = 202
  h.module.switchSpace("prev")
  eq(#h.writes, 0)
  h.module.switchSpace("next")
  h:advance(0.3)
  eq(h.space, 303)
  local before = #h.writes
  h.module.switchSpace("next")
  eq(#h.writes, before)
end)
test("Spaces 9 and 10 never navigate into Spaces 8 or 11", function()
  local spaces, displays = {}, {}
  for i = 1, 11 do
    spaces[i] = { ManagedSpaceID = i * 100 }
    displays[i * 100] = i < 9 and "left" or i < 11 and "middle" or "right"
  end
  local h = harness({ spaces = spaces, displays = displays, space = 1000 })
  h.module.switchSpace("prev")
  h:advance(0.3)
  eq(h.space, 900)
  local before = #h.writes
  for _ = 1, 10 do
    h.module.switchSpace("prev")
  end
  eq(#h.writes, before)
  eq(h.space, 900)
  h.module.switchSpace("next")
  h:advance(0.3)
  eq(h.space, 1000)
  before = #h.writes
  for _ = 1, 10 do
    h.module.switchSpace("next")
  end
  eq(#h.writes, before)
end)
test("rapid presses at an edge preserve the pending focus restoration", function()
  local h = harness({ displays = { [101] = "left", [202] = "left", [303] = "right" } })
  h.module.switchSpace("next")
  for _ = 1, 10 do
    h.module.switchSpace("next")
  end
  h:advance(0.3)
  eq(h.space, 202)
  eq(h.focused, 2)
  eq(h:countFocus(), 1)
  eq(h.module.status().busy, false)
end)
test("numbered shortcuts still select a Space on another display", function()
  local h = harness({ displays = { [101] = "left", [202] = "right", [303] = "right" } })
  h.module.switchSpace(2)
  h:advance(0.3)
  eq(h.space, 202)
  eq(h.focused, 2)
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
  local h = away(true)
  -- The display can show the Space before windowManager replies; restoration waits for the reply.
  h.beforeReply = function()
    eq(h.lists, 0)
  end
  h.module.switchSpace(3)
  h:advance(2)
  eq(h.module.status().last.ok, true)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 1)
  assert(h.clicks[1].x >= 1000)
  eq(#h.alerts, 0)
end)
test("PiP focus on the other display after the Space appears goes to the new desktop", function()
  local h = away("pip")
  h.module.switchSpace(3)
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 1)
  eq(h.module.status().last.ok, true)
  eq(#h.alerts, 0)
end)
test("PiP focus after focus reaches the new Space is still left for its desktop", function()
  local h = away(true)
  h.module.switchSpace(3)
  -- The display takes focus, then PiP on the other display takes it back.
  h.beforeReply = function()
    h:shift(303)
    h.focused = 50
  end
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 1)
  eq(h.module.status().last.ok, true)
end)
test("from the other display's desktop, an empty Space there still takes focus", function()
  local h = away(true)
  h.focused = nil
  h.module.switchSpace(3)
  h:advance(2)
  eq(h.space, 303)
  eq(#h.clicks, 1)
  eq(h.module.status().last.ok, true)
end)
test("a Space switch on a display without the PiP recovers focus the PiP took", function()
  local h = harness({
    displays = { [101] = "left", [202] = "right", [303] = "right" },
    visible = { 101 },
    noArrival = true,
  })
  h.space, h.focused = 202, 2
  -- The right display shows 303, then focus lands on the left display's PiP.
  h.beforeReply = function()
    h.space, h.visible = 101, { [303] = true }
  end
  h.afterReply = function()
    h:focus(50)
  end
  h.module.switchSpace(3)
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 1)
  assert(h.clicks[1].x >= 1000)
  eq(h.module.status().last.ok, true)
  eq(#h.alerts, 0)
end)
test("a same-display Space shown before focus follows waits instead of clicking", function()
  local h = harness({
    displays = { [101] = "left", [202] = "right", [303] = "right" },
    visible = { 101 },
    noArrival = true,
  })
  h.space, h.focused = 202, 2
  h.beforeReply = function()
    h.shows.right = 303
  end
  -- Focus follows just after the reply, to the new desktop.
  h.afterReply = function()
    h.shows.right = nil
    h.space, h.focused = 303, nil
    h.spaceCallback()
  end
  h.module.switchSpace(3)
  h:advance(2)
  eq(#h.clicks, 0)
  eq(h.module.status().last.ok, true)
end)
test(
  "a Space notification after the reply, with focus still on the other display, is ignored",
  function()
    local h = away(true)
    h.onReply = function()
      h.spaceCallback()
    end
    h.module.switchSpace(3)
    h:advance(2)
    eq(h.space, 303)
    eq(#h.clicks, 1)
    eq(h:countFocus(), 0)
    eq(h.module.status().last.ok, true)
  end
)
test("PiP retaking focus from the other display after the switch is undone", function()
  local h = away(true)
  h.module.switchSpace(3)
  h:advance(0.1)
  eq(h.space, 303)
  eq(h.module.status().busy, false)
  -- The left display's PiP takes focus back, within the transition.
  h.visible[303], h.visible[101], h.space = true, nil, 101
  h:focus(50)
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 2)
  eq(h:countFocus(), 0)
  eq(h.module.status().last.ok, true)
end)
test("a window on the other display keeping focus after the display switch is left", function()
  local h = away(true)
  -- The menu bar moves to the new display; the old display's window stays key.
  h.beforeReply = function()
    h:shift(303)
  end
  h.module.switchSpace(3)
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 1)
  eq(h.module.status().last.ok, true)
end)
test("Finder activating before its display takes focus still finishes the switch", function()
  local h = away(true)
  h.lateShift = true
  h.module.switchSpace(3)
  h:advance(2)
  eq(h.space, 303)
  eq(#h.clicks, 1)
  eq(h.module.status().last.ok, true)
  eq(#h.alerts, 0)
end)
test("PiP retaking focus right after the desktop click finishes without a timeout", function()
  local h = away(true)
  h.resteal = true
  h.module.switchSpace(3)
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 2)
  eq(h.module.status().last.ok, true)
  eq(#h.alerts, 0)
end)
test("an app activating onto its PiP during the transition retakes the shown Space", function()
  local h = away(true)
  h.module.switchSpace(3)
  h:advance(0.1)
  eq(h.space, 303)
  -- Activation arrives before the PiP's focus notification.
  h.visible[303], h.visible[101], h.space = true, nil, 101
  h:activate(50)
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(#h.clicks, 2)
  eq(h:countFocus(), 0)
  eq(#h.alerts, 0)
end)
test("an activation onto the other display before its PiP takes focus waits for the PiP", function()
  local h = away(true)
  h:add({ id = 70, pid = 500, app = "Browser", title = "Tab", space = 101 })
  h.module.switchSpace(3)
  h:advance(0.1)
  eq(h.space, 303)
  -- The PiP's app activates on the left display, then its PiP becomes key.
  h.visible[303], h.visible[101], h.space = true, nil, 101
  h:activate(70)
  h:focus(50)
  h:advance(2)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(h:countFocus(), 0)
  eq(#h.alerts, 0)
end)
test("a user click queued ahead of the desktop click drops it quietly", function()
  local h = away(true)
  h.beforeClick = function()
    h:click()
  end
  h.module.switchSpace(3)
  h:advance(2)
  eq(#h.clicks, 0)
  eq(h.dropped, 2)
  eq(h.module.status().last.error, "superseded")
  eq(#h.alerts, 0)
end)
test("a desktop click after an earlier user click is not dropped", function()
  local h = harness()
  eq(h:click(), false)
  h:advance(0.3)
  h.module.switchSpace(3)
  h:advance(0.3)
  eq(#h.clicks, 1)
  eq(h.dropped, nil)
  eq(h.module.status().last.ok, true)
end)
test("shortcuts reuse the Space list's displays; native transitions look one up", function()
  local h = harness({ displays = { [101] = "left", [202] = "left", [303] = "right" } })
  h:row(50).frame = { x = 1400, y = 350, w = 180, h = 180 }
  h:loadShortcuts()
  eq(h:key("keyDown", "right", { ctrl = true }), true)
  h:advance(0.3)
  eq(h.space, 202)
  eq(h:key("keyDown", "right", { ctrl = true }), true)
  h:advance(0.3)
  eq(#h.writes, 2)
  h.hotkeys["alt:3"]()
  h:advance(0.3)
  eq(h.space, 303)
  eq(#h.clicks, 1)
  -- The desktop click lands on the job's screen, clear of the PiP there.
  assert(h.clicks[1].x >= 1000 and outside(h.clicks[1], h:row(50).frame))
  eq(h.displayReads, 0)
  h:arrive(101, true)
  h:advance(0.3)
  eq(h.module.status().last.ok, true)
  eq(h.displayReads, 1)
end)
test("restoration never restarts the mouse-intent tap", function()
  local h = harness()
  eq(h.module.input.starts, 1)
  h.module.switchSpace(2)
  h:advance(0.3)
  h:arrive(303, true)
  h:advance(0.3)
  eq(h.module.input.starts, 1)
  eq(h.module.input:isEnabled(), true)
  h.module.stop()
  eq(h.module.input:isEnabled(), false)
end)
test("Mission Control receives the original Ctrl-arrow events immediately", function()
  local h = harness()
  h:loadShortcuts()
  h.missionControl = true
  for _, key in ipairs({ "left", "right" }) do
    eq(h:key("keyDown", key, { ctrl = true }), false)
    eq(h:key("keyUp", key, { ctrl = true }), false)
  end
  eq(#h.writes, 0)
  h.missionControl = false
  eq(h:key("keyDown", "right", { ctrl = true }), true)
  h:advance(0.3)
  eq(h.space, 202)
end)
test("other arrow combinations pass through, including plain arrow keys", function()
  local h = harness()
  h:loadShortcuts()
  for _, flags in ipairs({
    {},
    { ctrl = true, alt = true },
    { ctrl = true, cmd = true },
    { ctrl = true, shift = true },
  }) do
    eq(h:key("keyDown", "right", flags), false)
    eq(h:key("keyUp", "right", flags), false)
  end
  eq(h:key("keyDown", "a", { ctrl = true }), false)
  eq(#h.writes, 0)
  eq(h:key("keyDown", "right", { ctrl = true, fn = true }), true)
  h:advance(0.3)
  eq(h.space, 202)
end)
test("Mission Control Space notifications never focus windows or click desktop", function()
  local h = harness()
  h.missionControl = true
  h:arrive(202, true)
  h:advance(0.3)
  eq(h:countFocus(), 0)
  eq(#h.clicks, 0)
  eq(h.lists, 0)
end)
test("opening Mission Control cancels a pending focus action", function()
  local h = harness()
  h:arrive(202, true)
  h.missionControl = true
  h:advance(0.3)
  eq(h:countFocus(), 0)
  eq(#h.clicks, 0)
  eq(h.module.status().busy, false)
end)
test("a newer switch cancels focus before its next run-loop turn", function()
  local h = harness()
  h.module.switchSpace(2)
  h:advance(0.3, 1)
  eq(h.space, 202)
  eq(h.lists, 1)
  eq(h:countFocus(), 0)
  h.module.switchSpace(1)
  eq(h.writes[#h.writes][2], 1)
  h:advance(0.4)
  eq(h.focused, 1)
  eq(h:countFocus(), 1)
end)

test("a newer switch during a window snapshot prevents the old focus action", function()
  local h = harness()
  h.module.switchSpace(2)
  h.listing = function()
    h.module.switchSpace(1)
  end
  h:advance(0.4)
  eq(h.space, 101)
  eq(h.focused, 1)
  eq(h:countFocus(), 1)
  for _, command in ipairs(h.writes) do
    if command[1] == "focus" then
      eq(command[2], 1)
    end
  end
end)

test("a missing Space times out and a failed reply stops, once and without retrying", function()
  for _, opts in ipairs({ { noArrival = true }, { spaceError = true } }) do
    local h = harness(opts)
    -- windowManager replies only once the display shows the Space.
    h.noReply = opts.noArrival
    h.module.switchSpace(2)
    h:advance(0.1)
    if opts.noArrival then
      eq(h.module.status().last, nil)
      eq(h.module.status().busy, true)
      eq(#h.alerts, 0)
      h:advance(1.5)
    end
    local message = opts.noArrival and "timed out waiting for Space 2" or "display unavailable"
    eq(h.module.status().last.ok, false)
    eq(h.module.status().last.error, message)
    eq(h.module.status().busy, false)
    h:advance(2)
    eq(h.space, 101)
    eq(h.lists, 0)
    eq(#h.writes, 1)
    eq(#h.alerts, 1)
    eq(h.logs[#h.logs], "Space focus: " .. message)
  end
end)

test("a Space notification after an ok reply restores focus", function()
  local h = harness({ lateArrival = true })
  h.module.switchSpace(2)
  h:advance(0.0015)
  eq(h.module.status().last, nil)
  eq(h.module.status().busy, true)
  eq(h.lists, 0)
  h:advance(0.3)
  eq(h.module.status().last.ok, true)
  eq(h.space, 202)
  eq(h.focused, 2)
  eq(h:countFocus(), 1)
  eq(#h.logs, 0)
  eq(#h.alerts, 0)
end)

test("app or window focus after an ok reply restores focus without a Space event", function()
  for _, notify in ipairs({ "app", "window" }) do
    local h = harness({ lateArrival = true, notify = notify })
    h.module.switchSpace(2)
    h:advance(0.3)
    eq(h.module.status().last.ok, true)
    eq(h.space, 202)
    eq(h.focused, 2)
    eq(h:countFocus(), 1)
    eq(#h.alerts, 0)
  end
end)

test("a press between the reply and the Space arrival supersedes cleanly", function()
  local h = harness({ lateArrival = true })
  h.module.switchSpace(2)
  h:advance(0.0015)
  h.module.switchSpace(3)
  eq(h.module.status().last.space, 202)
  eq(h.module.status().last.error, "superseded")
  eq(#h.writes, 2)
  h:advance(0.3)
  eq(h.module.status().last.space, 303)
  eq(h.module.status().last.ok, true)
  eq(h.space, 303)
  eq(h.focused, nil)
  eq(h:countFocus(), 0)
  eq(#h.logs, 0)
  eq(#h.alerts, 0)
end)

test("a reversal before the first reply switches back without queuing or retrying", function()
  local h = harness()
  h.module.switchSpace(2)
  h.module.switchSpace(1)
  eq(#h.writes, 2)
  h:advance(0.3)
  eq(h.module.status().last.ok, true)
  eq(h.space, 101)
  eq(h.focused, 1)
  eq(#h.alerts, 0)
  local switches = 0
  for _, command in ipairs(h.writes) do
    if command[1] == "space" then
      switches = switches + 1
    end
  end
  eq(switches, 2)
end)

local function pip(options)
  local h = harness(options)
  h:add({ id = 61, pid = 500, app = "Browser", title = "News", space = 101 })
  h:add({ id = 60, pid = 500, app = "Browser", title = "Mail", space = 202 })
  h.recent = { [60] = 2, [61] = 1 }
  return h
end

test("activation onto PiP continues to the app's most recent real window", function()
  for _, case in ipairs({ { true }, { false }, { true, true } }) do
    local loaded = case[1]
    -- Without Screen Recording, titles come from the tracked windows instead.
    local h = pip({ noSwitcher = not loaded, noTitles = case[2] })
    -- Without the switcher, the lowest tracked ID wins.
    h.recent = { [61] = 2 }
    h:activate(50)
    eq(h:countFocus(), 1)
    h:advance(0.3)
    eq(h:countFocus(), 1)
    eq(h.focused, loaded and 61 or 60)
    eq(h.space, loaded and 101 or 202)
    eq(h.module.status().busy, false)
    eq(#h.alerts, 0)
  end
end)

test("activation reads the focused window only for an app with an on-screen PiP", function()
  local h = pip()
  h.ax = {}
  h:activate(1)
  h:row(50).hidden = true
  h:activate(61)
  eq(next(h.ax), nil)
  h:row(50).hidden = nil
  h:activate(50)
  eq(h.ax.app, 1)
  -- PiP title and bounds come from the WindowServer entry.
  eq(h.ax[50], nil)
  eq(h:countFocus(60), 1)
end)

test("PiP redirect uses tracked windows in ID order and switcher recency", function()
  for _, loaded in ipairs({ true, false }) do
    local h = harness({ noSwitcher = not loaded })
    h:add({ id = 64, pid = 500, app = "Browser", title = "Mail", space = 202 })
    h:add({ id = 63, pid = 500, app = "Browser", title = "News", space = 101 })
    h:add({ id = 62, pid = 500, app = "Browser", title = "Draft", space = 101, minimized = true })
    h:add({ id = 61, pid = 500, app = "Browser", title = "PiP", space = 0, layer = 3 })
    h:add({ id = 60, pid = 500, app = "Browser", title = "Tab", space = 101, untracked = true })
    h.recent = { [60] = 10, [61] = 9, [62] = 8, [64] = 2, [63] = 1 }
    h:activate(50)
    eq(#h.writes, 1)
    eq(table.concat(h.writes[1], " "), "focus " .. (loaded and 64 or 63) .. " 500")
    h:advance(0.3)
    eq(h.focused, loaded and 64 or 63)
    eq(#h.writes, 1)
    eq(#h.alerts, 0)
  end
end)

test("activation during a Space job or its transition does not redirect PiP", function()
  -- A busy Cmd-Tab leaves the transition without a job.
  for _, case in ipairs({ "job", "transition", "busy" }) do
    local h = pip()
    h.module.switchSpace(2)
    if case ~= "job" then
      h:advance(0.1)
      eq(h.module.status().busy, false)
    end
    h.busy = case == "busy"
    h:activate(50)
    h:advance(0.3)
    for _, command in ipairs(h.writes) do
      assert(command[2] ~= 60 and command[2] ~= 61)
    end
    h:advance(1)
    h:activate(50)
    eq(h:countFocus(60), 1)
  end
end)

test("PiP activation without another eligible app window does nothing", function()
  for _, loaded in ipairs({ true, false }) do
    local h = harness({ noSwitcher = not loaded })
    h:add({ id = 62, pid = 500, app = "Browser", title = "Mail", space = 101, minimized = true })
    h:add({ id = 63, pid = 500, app = "Browser", title = "PiP", space = 0, layer = 3 })
    h:add({ id = 64, pid = 500, app = "Browser", title = "News", space = 202, untracked = true })
    h:activate(50)
    h:advance(0.3)
    eq(#h.writes, 0)
    eq(h.focused, 50)
    eq(#h.logs, 0)
    eq(#h.alerts, 0)
  end
end)

test("a failed PiP redirect logs and alerts once without retrying", function()
  local h = pip({ focusError = true })
  h:activate(50)
  h:advance(2)
  eq(h:countFocus(), 1)
  eq(h.focused, 50)
  eq(#h.logs, 1)
  eq(#h.alerts, 1)
  assert(h.logs[1]:find("window unavailable", 1, true))
end)

test("non-PiP activations and other app events keep existing behaviour", function()
  local h = pip()
  h:activate(61)
  h:activate(nil, 900)
  h.appCallback(nil, 1, nil)
  h.focused = 50
  h.appCallback(nil, 2, h:app(500))
  h:advance(0.3)
  eq(h:countFocus(), 0)
  eq(#h.alerts, 0)
end)

test("PiP focus shortly after activating a real window is redirected", function()
  local h = pip()
  h:activate(61)
  h:advance(0.015)
  eq(h:countFocus(), 0)
  h:focus(50)
  eq(h:countFocus(), 1)
  h:advance(0.3)
  eq(h:countFocus(), 1)
  eq(h.focused, 60)
  eq(h.space, 202)
  eq(#h.alerts, 0)
end)

test("PiP focus without an activation of its app does not redirect", function()
  for _, other in ipairs({ false, true }) do
    local h = pip()
    if other then
      h:activate(1)
    end
    h:focus(50)
    h:advance(0.3)
    eq(h:countFocus(), 0)
    eq(h.focused, 50)
  end
end)

test("PiP focus that returns within 0.5 s after a redirect is redirected again", function()
  local h = pip()
  h.recent = { [61] = 2 }
  h:activate(50)
  h:advance(0.043)
  eq(h:countFocus(), 1)
  eq(h.focused, 61)
  h:focus(50)
  eq(h:countFocus(), 2)
  h:advance(0.1)
  eq(h.focused, 61)
  h:advance(0.4)
  h:focus(50)
  h:advance(0.3)
  eq(h:countFocus(), 2)
  eq(h.focused, 50)
end)

test("PiP activation or later PiP focus with the pointer over PiP does not redirect", function()
  for _, later in ipairs({ false, true }) do
    local h = pip()
    h.mouse = { x = 450, y = 400 }
    h:activate(later and 61 or 50)
    if later then
      h:focus(50)
    end
    h:advance(0.3)
    eq(h:countFocus(), 0)
    eq(h.focused, 50)
  end
end)

test("shutdown stops arrow interception", function()
  local h = harness()
  h:loadShortcuts()
  h.module.stop()
  eq(h.module.keys:isEnabled(), false)
  eq(h:key("keyDown", "right", { ctrl = true }), false)
end)
print("RESULT " .. passed .. " passed, 0 failed")

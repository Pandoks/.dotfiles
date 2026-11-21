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

local function harness(options)
  local desktop = {
    current = 100,
    steps = 0,
    switches = {},
    inflight = {},
    results = {},
    order = {},
    calls = { activeSpaces = 0, spaceDisplay = 0, utilsSpaces = 0, displaySpaces = 0, timers = 0 },
  }
  local spaces = {}
  for i = 1, 4 do
    spaces[i] = { ManagedSpaceID = i * 100, display = "d" }
  end
  local nativeMock = {
    move = function()
      desktop.steps = desktop.steps + 1
      return true
    end,
    spaces = function(ids)
      return { [ids[1]] = desktop.windowSpace }
    end,
    focus = function(_, id, done)
      desktop.focused = id
      desktop.order[#desktop.order + 1] = "focus on " .. desktop.current
      done(true)
    end,
    minimize = function(_, _, minimized, done)
      desktop.order[#desktop.order + 1] = "minimized="
        .. tostring(minimized)
        .. " on "
        .. desktop.current
      if desktop.minimizing then
        desktop.minimizing()
      end
      done(true)
    end,
    windows = function()
      desktop.listed = (desktop.listed or 0) + 1
    end,
  }
  if options and options.nativeDisplaySpaces then
    function nativeMock.displaySpaces()
      desktop.calls.displaySpaces = desktop.calls.displaySpaces + 1
      if desktop.unavailable then
        return nil, "Spaces unavailable"
      end
      local list, bySpace = {}, {}
      for i, row in ipairs(spaces) do
        local id = row.ManagedSpaceID
        list[i] = { id = id, display = row.display }
        if not (desktop.displayGone and id == desktop.windowSpace) then
          bySpace[id] = { index = i, display = row.display }
        end
      end
      return { spaces = list, active = { d = desktop.current }, bySpace = bySpace }
    end
  end
  local dockMock = {
    switch = function(space, done)
      desktop.switches[#desktop.switches + 1] = space
      if desktop.dockError then
        done(false, desktop.dockError)
        return
      end
      if options and options.deferred then
        desktop.inflight[#desktop.inflight + 1] = { space = space, done = done }
        return
      end
      desktop.current = space
      done(true)
    end,
  }
  local environment = setmetatable({
    hs = {
      spaces = {
        spaceDisplay = function(space)
          desktop.calls.spaceDisplay = desktop.calls.spaceDisplay + 1
          return not desktop.displayGone and space and "d" or nil
        end,
        activeSpaces = function()
          desktop.calls.activeSpaces = desktop.calls.activeSpaces + 1
          if desktop.unavailable then
            return nil, "Spaces unavailable"
          end
          return { d = desktop.current }
        end,
      },
      screen = {
        find = function(display)
          if desktop.screenGone or not display then
            return nil
          end
          return {
            frame = function()
              return { center = { x = 0, y = 0 } }
            end,
          }
        end,
      },
      timer = {
        doAfter = function()
          desktop.calls.timers = desktop.calls.timers + 1
          return { stop = function() end }
        end,
      },
    },
    require = function(name)
      if name == "lib.dock" then
        return dockMock
      end
      return {
        spaces = function()
          desktop.calls.utilsSpaces = desktop.calls.utilsSpaces + 1
          return spaces
        end,
        native = function()
          return nativeMock
        end,
      }
    end,
  }, { __index = _G })
  desktop.windowManager = assert(loadfile(root .. "/window_manager.lua", "t", environment))()
  function desktop:space(index)
    self.windowManager.space(index, function(ok, err)
      self.results[index] = ok and "ok" or err
    end)
  end
  function desktop:settle()
    while #self.inflight > 0 do
      local job = table.remove(self.inflight, 1)
      if not desktop.ignoreUpdate then
        self.current = job.space
      end
      job.done(true)
    end
  end
  return desktop
end

test(
  "direct Space switch updates Space immediately through dock.switch without swipes or timers",
  function()
    local desktop = harness()
    desktop:space(4)
    assertEqual(#desktop.switches, 1)
    assertEqual(desktop.switches[1], 400)
    assertEqual(desktop.current, 400)
    assertEqual(desktop.steps, 0, "no swipe fallback")
    assertEqual(desktop.calls.timers, 0, "no swipe deadline timers")
    assertEqual(desktop.results[4], "ok")
    assertEqual(desktop.windowManager.isBusy(), false)
  end
)

test("rapid back-to-back switches execute immediately in order with zero wait lock", function()
  local desktop = harness({ nativeDisplaySpaces = true })
  for _, index in ipairs({ 2, 3, 4, 1 }) do
    desktop:space(index)
    assertEqual(desktop.windowManager.isBusy(), false, "idle after each switch")
  end
  assertEqual(table.concat(desktop.switches, ","), "200,300,400,100")
  assertEqual(desktop.current, 100)
  assertEqual(desktop.steps, 0)
  for _, index in ipairs({ 2, 3, 4, 1 }) do
    assertEqual(desktop.results[index], "ok", "switch " .. index)
  end
end)

test("deferred switch supersedes older request and ignores its stale reply", function()
  local desktop = harness({ deferred = true })
  desktop:space(2)
  assertEqual(desktop.windowManager.isBusy(), true)
  desktop:space(3)
  assertEqual(desktop.results[2], "superseded")
  assertEqual(#desktop.inflight, 2)
  local stale = table.remove(desktop.inflight, 1)
  stale.done(true)
  assertEqual(desktop.windowManager.isBusy(), true, "stale reply does not clear active switch")
  assertEqual(desktop.results[3], nil)
  desktop:settle()
  assertEqual(desktop.current, 300)
  assertEqual(desktop.results[3], "ok")
  assertEqual(desktop.windowManager.isBusy(), false)
end)

test("Dock helper failure fails fast", function()
  local desktop = harness({ nativeDisplaySpaces = true })
  desktop.dockError = "Dock helper not loaded"
  desktop:space(3)
  assertEqual(desktop.results[3], "Dock helper not loaded")
  assertEqual(desktop.current, 100)
  assertEqual(desktop.windowManager.isBusy(), false)
end)

test(
  "unreadable layout, missing Space, and unavailable display fail at once without switching",
  function()
    local desktop = harness()
    desktop.unavailable = true
    desktop:space(3)
    assertEqual(desktop.results[3], "Spaces unavailable")
    assertEqual(#desktop.switches, 0)

    desktop.unavailable = false
    desktop:space(9)
    assertEqual(desktop.results[9], "Space 9 does not exist")
    assertEqual(#desktop.switches, 0)

    desktop.screenGone = true
    desktop:space(2)
    assertEqual(desktop.results[2], "display unavailable")
    assertEqual(#desktop.switches, 0)
  end
)

test(
  "focusing a window whose display can't be found fails instead of skipping its Space",
  function()
    local desktop = harness()
    desktop.windowSpace, desktop.displayGone = 300, true
    local result
    desktop.windowManager.focus(10, 7, function(ok, err)
      result = ok and "ok" or err
    end)
    assertEqual(result, "display unavailable for Space 300")
    assertEqual(desktop.focused, nil, "not focused without showing its Space")
    assertEqual(#desktop.switches, 0)
  end
)

test("a minimized window is restored, on another Space only once that Space shows", function()
  for _, deferred in ipairs({ false, true }) do
    for _, space in ipairs({ 300, 100, false }) do
      local desktop = harness({ deferred = deferred })
      desktop.windowSpace = space or nil
      local result
      desktop.windowManager.focus(10, 7, function(ok, err)
        result = ok and "ok" or err
      end, true)
      if deferred then
        assertEqual(#desktop.order, space == 300 and 0 or 2, "restored before its Space shows")
        desktop:settle()
      end
      local shown = space == 300 and 300 or 100
      assertEqual(
        table.concat(desktop.order, ", "),
        "minimized=false on " .. shown .. ", focus on " .. shown,
        tostring(space)
      )
      assertEqual(result, "ok")
    end
  end
end)

test("a cancelled focus neither restores nor focuses its window afterwards", function()
  for _, stage in ipairs({ "jump", "restore" }) do
    local desktop = harness({ deferred = true })
    desktop.windowSpace = 300
    local live, result = true, nil
    desktop.minimizing = function()
      live = false
    end
    desktop.windowManager.focus(
      10,
      7,
      function(ok, err)
        result = ok and "ok" or err
      end,
      true,
      function()
        return live
      end
    )
    live = stage ~= "jump"
    desktop:settle()
    assertEqual(
      table.concat(desktop.order, ", "),
      stage == "jump" and "" or "minimized=false on 300",
      stage
    )
    assertEqual(desktop.focused, nil, stage)
    assertEqual(result, "cancelled", stage)
  end
end)

test("loading starts one window search, so the first Cmd-Tab is cached", function()
  assertEqual(harness().listed, 1)
end)

test("native.displaySpaces fast path avoids hs.spaces and utils.spaces", function()
  local desktop = harness({ nativeDisplaySpaces = true, deferred = true })
  desktop:space(3)
  assertEqual(desktop.windowManager.isBusy(), true, "busy while switch is in flight")
  desktop:settle()
  assertEqual(desktop.windowManager.isBusy(), false, "idle after settle")
  assertEqual(desktop.current, 300)
  assertEqual(desktop.results[3], "ok")
  assertEqual(desktop.calls.activeSpaces, 0, "no hs.spaces.activeSpaces")
  assertEqual(desktop.calls.spaceDisplay, 0, "no hs.spaces.spaceDisplay")
  assertEqual(desktop.calls.utilsSpaces, 0, "no utils.spaces")

  desktop.windowSpace = 200
  local result
  desktop.windowManager.focus(10, 7, function(ok, err)
    result = ok and "ok" or err
  end, true)
  local readsBeforeSettle = desktop.calls.displaySpaces
  desktop:settle()
  assertEqual(result, "ok")
  assertEqual(desktop.current, 200)
  assertEqual(desktop.focused, 7)
  assertEqual(
    table.concat(desktop.order, ", "),
    "minimized=false on 200, focus on 200",
    "minimized restore order"
  )
  assertEqual(desktop.calls.activeSpaces, 0)
  assertEqual(desktop.calls.spaceDisplay, 0)
  assertEqual(desktop.calls.utilsSpaces, 0)
  assertEqual(readsBeforeSettle, 2, "space() read 1, focus() reused layout for 1")
end)

test("native.displaySpaces handles unreadable layout and missing Space display", function()
  local desktop = harness({ nativeDisplaySpaces = true })
  desktop.unavailable = true
  desktop:space(2)
  assertEqual(desktop.results[2], "Spaces unavailable")
  assertEqual(#desktop.switches, 0)
  assertEqual(desktop.windowManager.isBusy(), false)

  desktop.unavailable = false
  desktop.windowSpace, desktop.displayGone = 300, true
  local result
  desktop.windowManager.focus(10, 7, function(ok, err)
    result = ok and "ok" or err
  end)
  assertEqual(result, "display unavailable for Space 300")
  assertEqual(desktop.focused, nil)
  assertEqual(#desktop.switches, 0)
end)

test("isBusy reflects active switches across no-op, supersede, settle, and stop", function()
  local desktop = harness({ nativeDisplaySpaces = true, deferred = true })
  assertEqual(desktop.windowManager.isBusy(), false, "idle initially")
  desktop:space(1)
  assertEqual(desktop.windowManager.isBusy(), false, "no-op switch stays idle")

  desktop:space(3)
  assertEqual(desktop.windowManager.isBusy(), true, "busy after switch starts")
  desktop:space(2)
  assertEqual(desktop.windowManager.isBusy(), true, "still busy when superseded")
  desktop:settle()
  assertEqual(desktop.windowManager.isBusy(), false, "idle after settling")

  desktop:space(4)
  assertEqual(desktop.windowManager.isBusy(), true, "busy before stop")
  desktop.windowManager.stop()
  assertEqual(desktop.windowManager.isBusy(), false, "idle after stop")
  assertEqual(desktop.results[4], "stopped")
end)

print("RESULT " .. passed .. " passed, 0 failed")

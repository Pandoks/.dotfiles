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

-- The Dock lands each batch of swipes as one Space change.
local function harness(options)
  local desktop = {
    current = 100,
    steps = 0,
    inflight = {},
    results = {},
    timers = {},
    order = {},
    calls = {
      activeSpaces = 0,
      spaceDisplay = 0,
      utilsSpaces = 0,
      displaySpaces = 0,
      cancelFocus = 0,
      spaces = 0,
    },
  }
  local spaces = {}
  for i = 1, 4 do
    spaces[i] = { ManagedSpaceID = i * 100, display = "d" }
  end
  local spaceChanged
  local nativeMock = {
    move = function(right, count)
      desktop.steps = desktop.steps + count
      desktop.inflight[#desktop.inflight + 1] = (right and 100 or -100) * count
      return true
    end,
    spaces = function(ids)
      desktop.calls.spaces = desktop.calls.spaces + 1
      return { [ids[1]] = desktop.windowSpace }
    end,
    focus = function(_, id, done, space)
      desktop.focused = id
      desktop.focusedSpace = space
      desktop.order[#desktop.order + 1] = "focus on " .. desktop.current
      if options and options.deferFocus then
        desktop.pendingFocus = done
        return
      end
      done(true)
    end,
    cancelFocus = function()
      desktop.calls.cancelFocus = desktop.calls.cancelFocus + 1
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
  local environment = setmetatable({
    hs = {
      spaces = {
        spaceDisplay = function(space)
          desktop.calls.spaceDisplay = desktop.calls.spaceDisplay + 1
          return not desktop.displayGone and space and "d" or nil
        end,
        watcher = {
          new = function(callback)
            spaceChanged = callback
            return {
              start = function(self)
                return self
              end,
              stop = function() end,
            }
          end,
        },
        activeSpaces = function()
          desktop.calls.activeSpaces = desktop.calls.activeSpaces + 1
          if desktop.unavailable then
            return nil, "Spaces unavailable"
          end
          return { d = desktop.current }
        end,
      },
      screen = {
        find = function()
          return {
            frame = function()
              return { center = { x = 0, y = 0 } }
            end,
          }
        end,
      },
      timer = {
        doAfter = function(_, callback)
          local timer = { callback = callback, active = true }
          function timer:stop()
            self.active = false
          end
          desktop.timers[#desktop.timers + 1] = timer
          return timer
        end,
      },
    },
    require = function()
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
      self.current = self.current + table.remove(self.inflight, 1)
      desktop.notifications = (desktop.notifications or 0) + 1
      spaceChanged()
    end
  end
  return desktop
end

test("a jump sends every swipe at once and reports when it arrives", function()
  local desktop = harness()
  desktop:space(4)
  assertEqual(#desktop.inflight, 1, "one batch")
  desktop:settle()
  assertEqual(desktop.current, 400)
  assertEqual(desktop.steps, 3)
  assertEqual(desktop.notifications, 1, "no Space between is shown")
  assertEqual(desktop.results[4], "ok")
end)

test("presses during a jump wait for its swipes to land, then continue from there", function()
  for _, case in ipairs({ { second = 1, steps = 2 }, { second = 3, steps = 2 } }) do
    local desktop = harness()
    desktop:space(2)
    desktop:space(case.second)
    assertEqual(#desktop.inflight, 1, "no swipes posted while others are in flight")
    desktop:settle()
    assertEqual(desktop.current, case.second * 100, "lands on the latest press")
    assertEqual(desktop.steps, case.steps)
    assertEqual(desktop.results[2], "superseded")
    assertEqual(desktop.results[case.second], "ok")
  end
end)

test("finished jumps release their timers", function()
  local desktop = harness()
  desktop:space(2)
  desktop:settle()
  assertEqual(desktop.results[2], "ok")
  assertEqual(leaked(desktop.timers), 0)
end)

test("an unreadable Space layout fails at once instead of waiting for the timeout", function()
  local desktop = harness()
  desktop.unavailable = true
  desktop:space(3)
  assertEqual(desktop.results[3], "Spaces unavailable")
  assertEqual(desktop.steps, 0)
end)

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
    assertEqual(desktop.steps, 0)
  end
)

test("a minimized window is restored, on another Space only once that Space shows", function()
  for _, space in ipairs({ 300, 100, false }) do
    local desktop = harness()
    desktop.windowSpace = space or nil
    local result
    desktop.windowManager.focus(10, 7, function(ok, err)
      result = ok and "ok" or err
    end, true)
    assertEqual(#desktop.order, space == 300 and 0 or 2, "restored before its Space shows")
    desktop:settle()
    local shown = space == 300 and 300 or 100
    assertEqual(
      table.concat(desktop.order, ", "),
      "minimized=false on " .. shown .. ", focus on " .. shown,
      tostring(space)
    )
    assertEqual(result, "ok")
  end
end)

test("a cancelled focus neither restores nor focuses its window afterwards", function()
  for _, stage in ipairs({ "jump", "restore" }) do
    local desktop = harness()
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
  local desktop = harness({ nativeDisplaySpaces = true })
  desktop:space(3)
  assertEqual(desktop.windowManager.isBusy(), true, "busy while jump is in flight")
  desktop:settle()
  assertEqual(desktop.windowManager.isBusy(), false, "idle after settle")
  assertEqual(desktop.current, 300)
  assertEqual(desktop.steps, 2)
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
  assertEqual(readsBeforeSettle, 3, "space() + settle() used 2, focus() reused layout for 1")
end)

test("native.displaySpaces handles unreadable layout and missing Space display", function()
  local desktop = harness({ nativeDisplaySpaces = true })
  desktop.unavailable = true
  desktop:space(2)
  assertEqual(desktop.results[2], "Spaces unavailable")
  assertEqual(desktop.steps, 0)
  assertEqual(desktop.windowManager.isBusy(), false)

  desktop.unavailable = false
  desktop.windowSpace, desktop.displayGone = 300, true
  local result
  desktop.windowManager.focus(10, 7, function(ok, err)
    result = ok and "ok" or err
  end)
  assertEqual(result, "display unavailable for Space 300")
  assertEqual(desktop.focused, nil)
  assertEqual(desktop.steps, 0)
end)

test("isBusy reflects active jumps across supersede, settle, and stop", function()
  local desktop = harness({ nativeDisplaySpaces = true })
  assertEqual(desktop.windowManager.isBusy(), false, "idle initially")
  desktop:space(1)
  assertEqual(desktop.windowManager.isBusy(), false, "no-op jump stays idle")

  desktop:space(3)
  assertEqual(desktop.windowManager.isBusy(), true, "busy after jump starts")
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

test(
  "focus forwards space, skips spaces() with knownSpace, cancels, and tracks settle state",
  function()
    local desktop = harness({ nativeDisplaySpaces = true, deferFocus = true })
    local spacesBefore = desktop.calls.spaces
    local cancelsBefore = desktop.calls.cancelFocus
    local result
    desktop.windowManager.focus(10, 7, function(ok, err)
      result = ok and "ok" or err
    end, false, nil, 300)
    assertEqual(desktop.calls.spaces, spacesBefore, "knownSpace skips native.spaces")
    assertEqual(desktop.calls.cancelFocus, cancelsBefore + 1, "jump calls cancelFocus")
    assertEqual(desktop.windowManager.isBusy(), true, "busy during focus jump")
    assertEqual(desktop.windowManager.focusedTarget().id, 7)
    assertEqual(desktop.windowManager.focusedTarget().space, 300)

    desktop:settle()
    assertEqual(desktop.focusedSpace, 300, "native.focus receives expected space")
    assertEqual(desktop.windowManager.isBusy(), true, "still busy while native.focus in flight")
    desktop.pendingFocus(true)
    assertEqual(result, "ok")
    assertEqual(desktop.windowManager.isBusy(), false, "unscoped isBusy false after settle")
    assertEqual(desktop.windowManager.isBusy(300), true, "matching space busy during settle window")
    assertEqual(
      desktop.windowManager.isBusy(nil, 10),
      true,
      "matching pid busy during settle window"
    )
    assertEqual(desktop.windowManager.isBusy(200, 99), false, "unrelated space/pid not busy")
    assertEqual(desktop.windowManager.focusedTarget().id, 7)

    -- Settle timer clears settled state.
    for _, timer in ipairs(desktop.timers) do
      if timer.active then
        timer.active = false
        timer.callback()
      end
    end
    assertEqual(desktop.windowManager.isBusy(300, 10), false, "idle after settle timer expires")
    assertEqual(desktop.windowManager.focusedTarget(), nil)

    -- space() and stop() clear settled state and cancel in-flight focus.
    local cancelsNow = desktop.calls.cancelFocus
    local live = true
    local cancelledResult
    desktop.windowManager.focus(
      10,
      8,
      function(ok, err)
        cancelledResult = ok and "ok" or err
      end,
      false,
      function()
        return live
      end,
      200
    )
    live = false
    local cancelsBeforeSettle = desktop.calls.cancelFocus
    assertEqual(cancelsBeforeSettle, cancelsNow + 1)
    desktop:settle()
    assertEqual(cancelledResult, "cancelled")
    assertEqual(desktop.calls.cancelFocus, cancelsBeforeSettle + 1)

    desktop.pendingFocus = nil
    desktop.windowManager.focus(10, 9, function() end, false, nil, 200)
    desktop.pendingFocus(true)
    assertEqual(desktop.windowManager.isBusy(200), true)
    desktop:space(1)
    assertEqual(desktop.windowManager.focusedTarget(), nil, "space() clears settled state")
    desktop:settle()
    assertEqual(desktop.windowManager.isBusy(200), false)

    desktop.pendingFocus = nil
    desktop.windowManager.focus(10, 11, function() end, false, nil, 100)
    desktop.pendingFocus(true)
    assertEqual(desktop.windowManager.isBusy(100), true)
    cancelsNow = desktop.calls.cancelFocus
    desktop.windowManager.stop()
    assertEqual(desktop.windowManager.isBusy(100), false, "stop() clears settled state")
    assertEqual(desktop.calls.cancelFocus, cancelsNow + 1, "stop() calls cancelFocus")
  end
)

print("RESULT " .. passed .. " passed, 0 failed")

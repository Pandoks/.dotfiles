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
    switches = {},
    leaving = {},
    inflight = {},
    results = {},
    timers = {},
    order = {},
    calls = {
      displaySpaces = 0,
      timers = 0,
      cancelFocus = 0,
      spaces = 0,
      watchWindowSpaces = 0,
    },
  }
  local nativeMock = {
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
      if desktop.minimizeError then
        done(false, desktop.minimizeError)
        return
      end
      done(true)
    end,
    windows = function()
      desktop.listed = (desktop.listed or 0) + 1
    end,
    frame = function() end,
    focusedWindow = function() end,
    watchWindowSpaces = function(callback)
      desktop.calls.watchWindowSpaces = desktop.calls.watchWindowSpaces + 1
      desktop.windowSpaceCallback = callback
      return true
    end,
    displaySpaces = function()
      desktop.calls.displaySpaces = desktop.calls.displaySpaces + 1
      if desktop.unavailable then
        return nil, "Spaces unavailable"
      end
      local list, bySpace = {}, {}
      for i = 1, 4 do
        local id = i * 100
        list[i] = { id = id, display = "d" }
        if not (desktop.displayGone and id == desktop.windowSpace) then
          bySpace[id] = { index = i, display = "d" }
        end
      end
      return { spaces = list, active = { d = desktop.current }, bySpace = bySpace }
    end,
  }
  local dockMock = {
    switch = function(space, done, leaving)
      desktop.switches[#desktop.switches + 1] = space
      desktop.leaving[#desktop.switches] = leaving
      if desktop.dockError then
        done(false, desktop.dockError)
        return
      end
      if options and options.deferred then
        local entry = { space = space, done = done, cancelled = false }
        desktop.inflight[#desktop.inflight + 1] = entry
        return function()
          entry.cancelled = true
        end
      end
      desktop.current = space
      done(true)
    end,
  }
  local environment = setmetatable({
    hs = {
      screen = {
        find = function(display)
          return not desktop.screenGone and display and {} or nil
        end,
      },
      timer = {
        doAfter = function(_, callback)
          desktop.calls.timers = desktop.calls.timers + 1
          local timer = { callback = callback, active = true }
          function timer:stop()
            self.active = false
          end
          desktop.timers[#desktop.timers + 1] = timer
          return timer
        end,
      },
    },
    require = function(name)
      if name == "lib.dock" then
        return dockMock
      end
      return {
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
      if not job.cancelled then
        if not desktop.ignoreUpdate then
          self.current = job.space
        end
        job.done(true)
      end
    end
  end
  return desktop
end

test("rapid back-to-back switches execute immediately in order with zero wait lock", function()
  local desktop = harness()
  for _, index in ipairs({ 2, 3, 4, 1 }) do
    desktop:space(index)
    assertEqual(desktop.windowManager.isBusy(), false, "idle after each switch")
  end
  assertEqual(table.concat(desktop.switches, ","), "200,300,400,100")
  assertEqual(desktop.calls.timers, 0, "no deadline timers")
  assertEqual(desktop.current, 100)
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
  local desktop = harness()
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
    assertEqual(desktop.windowManager.isBusy(), false)

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
  local desktop = harness()
  assertEqual(desktop.listed, 1)
  local manager = desktop.windowManager
  assertEqual(manager.frame, manager.native.frame)
  assertEqual(manager.windows, manager.native.windows)
end)

test("focusing a window on another Space reuses the layout it read", function()
  local desktop = harness({ deferred = true })
  desktop:space(3)
  assertEqual(desktop.windowManager.isBusy(), true, "busy while switch is in flight")
  desktop:settle()
  assertEqual(desktop.windowManager.isBusy(), false, "idle after settle")
  assertEqual(desktop.current, 300)
  assertEqual(desktop.results[3], "ok")

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
  assertEqual(readsBeforeSettle, 2, "space() read 1, focus() reused layout for 1")
end)

test("isBusy reflects active switches across no-op, supersede, settle, and stop", function()
  local desktop = harness({ deferred = true })
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

test(
  "focus forwards space, skips spaces() with knownSpace, cancels, and tracks settle state",
  function()
    local desktop = harness({ deferred = true, deferFocus = true })
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

test(
  "watchWindowSpaces multiplexes listeners, cleans up on last stop, and stops on windowManager.stop",
  function()
    local desktop = harness()
    assertEqual(desktop.calls.watchWindowSpaces, 0)
    local eventsA, eventsB = {}, {}
    local stopB
    local stopA = desktop.windowManager.watchWindowSpaces(function(id, space, added, pid)
      eventsA[#eventsA + 1] = string.format("%s:%s:%s:%s", id, space, added, pid)
    end)
    stopB = desktop.windowManager.watchWindowSpaces(function(id, space, added, pid)
      eventsB[#eventsB + 1] = string.format("%s:%s:%s:%s", id, space, added, pid)
      if added then
        stopB()
      end
    end)
    assertEqual(desktop.calls.watchWindowSpaces, 1, "native watcher registered once")
    assertEqual(type(desktop.windowSpaceCallback), "function")

    desktop.windowSpaceCallback(42, 4, true, 900)
    assertEqual(#eventsA, 1)
    assertEqual(eventsA[1], "42:4:true:900")
    assertEqual(#eventsB, 1)
    assertEqual(eventsB[1], "42:4:true:900")
    assertEqual(desktop.calls.watchWindowSpaces, 1, "stays registered while listener A remains")

    desktop.windowSpaceCallback(42, 1, false, 900)
    assertEqual(#eventsA, 2)
    assertEqual(eventsA[2], "42:1:false:900")
    assertEqual(#eventsB, 1, "unsubscribed listener B stops receiving events")

    stopA()
    assertEqual(desktop.calls.watchWindowSpaces, 2, "unregisters native watcher on last stop")
    assertEqual(desktop.windowSpaceCallback, nil)

    desktop.windowManager.watchWindowSpaces(function() end)
    assertEqual(desktop.calls.watchWindowSpaces, 3)
    assertEqual(type(desktop.windowSpaceCallback), "function")
    desktop.windowManager.stop()
    assertEqual(desktop.calls.watchWindowSpaces, 4, "stop() unregisters native watcher")
    assertEqual(desktop.windowSpaceCallback, nil)
  end
)

test(
  "focusing a same-Space window supersedes an in-flight cross-Space jump instead of landing away",
  function()
    local desktop = harness({ deferred = true })
    local firstResult, secondResult
    desktop.windowManager.focus(10, 1, function(ok, err)
      firstResult = ok and "ok" or err
    end, false, nil, 300)
    assertEqual(#desktop.inflight, 1, "cross-Space jump started")

    desktop.windowManager.focus(20, 2, function(ok, err)
      secondResult = ok and "ok" or err
    end, false, nil, 100)
    assertEqual(firstResult, "superseded", "in-flight cross-Space jump is superseded")
    assertEqual(desktop.inflight[1].cancelled, true, "queued dock switch is cancelled")
    desktop:settle()
    assertEqual(desktop.current, 100, "stays on current Space instead of moving to stale Space")
    assertEqual(secondResult, "ok")
    assertEqual(desktop.focused, 2)
  end
)

test("explicit Space switches pass the last window handed to native.focus as leaving", function()
  -- Nothing to leave before any native.focus call.
  local desktop = harness({ nativeDisplaySpaces = true, deferred = true, deferFocus = true })
  desktop:space(2)
  assertEqual(desktop.leaving[1], nil, "space() has nothing to leave initially")
  desktop:settle()

  desktop.windowManager.focus(10, 7, function() end, false, nil, 300)
  assertEqual(desktop.leaving[2], nil, "focus() has nothing to leave before first native.focus")
  desktop:settle()
  -- Window 7 has now been handed to native.focus (still in flight).

  -- Focusing window 8 on another Space leaves 7 even before 7's native.focus replies.
  desktop.windowManager.focus(10, 8, function() end, false, nil, 400)
  assertEqual(desktop.leaving[3], 7, "focus on another Space leaves last focused window")

  -- Superseding 8 before its Space arrives never hands 8 to native.focus, so leaving stays 7.
  desktop.windowManager.focus(10, 9, function() end, false, nil, 200)
  assertEqual(desktop.leaving[4], 7, "unfocused superseded target does not replace leaving")
  desktop:settle()
  desktop.pendingFocus(true)

  -- Focusing the same window (9) again on another Space must not mark it as leaving.
  desktop.windowManager.focus(10, 9, function() end, false, nil, 300)
  assertEqual(desktop.leaving[5], nil, "refocusing the same window passes no leaving window")
  desktop:settle()
  desktop.pendingFocus(true)

  -- Expiring the settle timer and calling no-op space(3) keeps 9 as the leaving window.
  for _, timer in ipairs(desktop.timers) do
    if timer.active then
      timer.active = false
      timer.callback()
    end
  end
  desktop:space(3)
  assertEqual(#desktop.switches, 5, "no-op space() does not switch")
  desktop:space(2)
  assertEqual(desktop.leaving[6], 9, "space(index) leaves last focused window after settle")
  desktop:settle()

  -- A later switch without another focus must not report window 9 as left a second time.
  desktop:space(4)
  assertEqual(desktop.leaving[7], nil, "space(index) does not report the same left window twice")
  desktop:settle()
  desktop.windowManager.focus(10, 10, function() end, false, nil, 100)
  assertEqual(desktop.leaving[8], nil, "later cross-Space focus does not re-report left window")
  desktop:settle()
  desktop.pendingFocus(true)

  -- Direct windowManager.native.focus callers (space_focus, tiling) update the leaving window.
  desktop.windowManager.native.focus(10, 9, function() end, 100)
  assertEqual(desktop.focused, 9, "native.focus wrapper forwards id")
  assertEqual(desktop.focusedSpace, 100, "native.focus wrapper forwards space")
  desktop:space(2)
  assertEqual(
    desktop.leaving[9],
    9,
    "refocusing via windowManager.native.focus reports window again"
  )
  desktop:settle()

  desktop.windowManager.native.focus(10, 12, function() end)
  desktop.windowManager.focus(10, 13, function() end, false, nil, 300)
  assertEqual(desktop.leaving[10], 12, "cross-Space focus reports window focused via native.focus")
  desktop:settle()
  desktop.pendingFocus(true)

  -- Failed or cancelled unminimize must not overwrite the tracked leaving window.
  desktop.minimizeError = "unminimize failed"
  local failedResult
  desktop.windowManager.focus(10, 14, function(ok, err)
    failedResult = ok and "ok" or err
  end, true, nil, 300)
  assertEqual(failedResult, "unminimize failed")
  desktop.minimizeError = nil

  local live, cancelledResult = true, nil
  desktop.minimizing = function()
    live = false
  end
  desktop.windowManager.focus(
    10,
    15,
    function(ok, err)
      cancelledResult = ok and "ok" or err
    end,
    true,
    function()
      return live
    end,
    300
  )
  assertEqual(cancelledResult, "cancelled")
  desktop.minimizing = nil

  desktop:space(4)
  assertEqual(desktop.leaving[11], 13, "failed and cancelled unminimizes preserve leaving window")
  desktop:settle()

  -- Successful minimized restore updates the tracked leaving window.
  desktop.windowManager.focus(10, 16, function() end, true, nil, 400)
  desktop.pendingFocus(true)
  desktop:space(1)
  assertEqual(desktop.leaving[12], 16, "restored minimized window is reported as leaving")
  desktop:settle()

  -- stop() clears the tracked leaving window.
  desktop.windowManager.native.focus(10, 17, function() end, 100)
  desktop.windowManager.stop()
  desktop:space(2)
  assertEqual(desktop.leaving[13], nil, "stop() clears leaving window")
  desktop:settle()

  -- Synchronous native.focus inside space(index)'s callback is kept for the next switch.
  local sync = harness({ nativeDisplaySpaces = true })
  sync.windowManager.native.focus(10, 50, function() end)
  sync.windowManager.space(2, function(ok)
    assertEqual(ok, true)
    sync.windowManager.native.focus(10, 51, function() end)
  end)
  sync.windowManager.space(3)
  assertEqual(sync.leaving[1], 50, "sync space() reports previous focused window")
  assertEqual(sync.leaving[2], 51, "sync callback focus is preserved for next switch")

  -- Fallback hs.spaces path also forwards leaving on cross-Space focus.
  local fallback = harness()
  fallback.windowSpace = 100
  fallback.windowManager.focus(10, 41)
  fallback.windowSpace = 300
  fallback.windowManager.focus(10, 42)
  assertEqual(fallback.leaving[1], 41, "hs.spaces fallback path forwards leaving window")
end)

print("RESULT " .. passed .. " passed, 0 failed")

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
    focuses = {},
    minimizes = {},
    results = {},
    timers = {},
    order = {},
    calls = {
      activeSpaces = 0,
      spaceDisplay = 0,
      utilsSpaces = 0,
      displaySpaces = 0,
      timers = 0,
      cancelFocus = 0,
      spaces = 0,
      watchWindowSpaces = 0,
    },
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
      desktop.calls.spaces = desktop.calls.spaces + 1
      return { [ids[1]] = desktop.windowSpace }
    end,
    focus = function(pid, id, done, space)
      desktop.focused = id
      desktop.focusedSpace = space
      desktop.order[#desktop.order + 1] = "focus on " .. desktop.current
      desktop.focuses[#desktop.focuses + 1] = { pid = pid, id = id, done = done, space = space }
      if options and options.deferFocus then
        desktop.pendingFocus = done
        return
      end
      done(true)
    end,
    cancelFocus = function()
      desktop.calls.cancelFocus = desktop.calls.cancelFocus + 1
    end,
    minimize = function(pid, id, minimized, done)
      desktop.order[#desktop.order + 1] = "minimized="
        .. tostring(minimized)
        .. " on "
        .. desktop.current
      desktop.minimizes[#desktop.minimizes + 1] = {
        pid = pid,
        id = id,
        minimized = minimized,
        done = done,
      }
      if desktop.minimizing then
        desktop.minimizing()
      end
      if options and options.deferMinimize then
        desktop.pendingMinimize = done
        return
      end
      done(true)
    end,
    windows = function()
      desktop.listed = (desktop.listed or 0) + 1
    end,
    watchWindowSpaces = function(callback)
      desktop.calls.watchWindowSpaces = desktop.calls.watchWindowSpaces + 1
      desktop.windowSpaceCallback = callback
      return true
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

test(
  "focus forwards space, skips spaces() with knownSpace, cancels, and tracks settle state",
  function()
    local desktop = harness({ nativeDisplaySpaces = true, deferred = true, deferFocus = true })
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
    local desktop = harness({ nativeDisplaySpaces = true })
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
    local desktop = harness({ nativeDisplaySpaces = true, deferred = true })
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

test(
  "same-pid focus waits for in-flight native focus or restore, suppresses stale failure, and resolves Space on start",
  function()
    local desktop = harness({ nativeDisplaySpaces = true, deferFocus = true })
    local firstResult, firstCalls = nil, 0
    local secondResult, secondCalls = nil, 0
    desktop.windowManager.focus(10, 1, function(ok, err)
      firstCalls = firstCalls + 1
      firstResult = ok and "ok" or err
    end, false, nil, 300)
    assertEqual(#desktop.switches, 1)
    assertEqual(desktop.current, 300)
    assertEqual(#desktop.focuses, 1)
    local cancelsAfterFirst = desktop.calls.cancelFocus

    -- Same pid while native.focus is in flight: no switch, cancel, Space lookup, or native call.
    desktop.windowSpace = 200
    desktop.windowManager.focus(10, 2, function(ok, err)
      secondCalls = secondCalls + 1
      secondResult = ok and "ok" or err
    end, true)
    assertEqual(#desktop.switches, 1, "does not switch Space under in-flight same-pid focus")
    assertEqual(desktop.current, 300)
    assertEqual(desktop.calls.cancelFocus, cancelsAfterFirst, "does not cancel in-flight focus")
    assertEqual(#desktop.focuses, 1, "does not call native.focus while same pid is in flight")
    assertEqual(#desktop.minimizes, 0, "does not call native.minimize while same pid is in flight")
    assertEqual(desktop.calls.spaces, 0, "defers Space lookup until remembered request starts")
    assertEqual(desktop.windowManager.isBusy(), true, "stays busy while request is remembered")
    assertEqual(desktop.windowManager.focusedTarget().id, 2, "target tracks newest request")
    assertEqual(desktop.windowManager.focusedTarget().pid, 10)
    assertEqual(firstCalls, 0)
    assertEqual(secondCalls, 0)

    -- Space changes before the remembered request starts; in-flight failure stays silent.
    desktop.windowSpace = 400
    desktop.focuses[1].done(false, "raise failed (-25204)")
    assertEqual(firstCalls, 1)
    assertEqual(firstResult, "superseded", "superseded in-flight failure is reported silently")
    assertEqual(desktop.calls.spaces, 1, "looks up Space when remembered request starts")
    assertEqual(#desktop.switches, 2, "switches Space once in-flight focus returns")
    assertEqual(desktop.switches[2], 400, "uses Space looked up on start")
    assertEqual(desktop.current, 400)
    assertEqual(#desktop.minimizes, 1, "honours remembered minimized flag")
    assertEqual(#desktop.focuses, 2)
    assertEqual(desktop.focuses[2].id, 2)
    assertEqual(desktop.focuses[2].space, 400)
    assertEqual(desktop.windowManager.focusedTarget().space, 400)
    assertEqual(
      table.concat(desktop.order, ", "),
      "focus on 300, minimized=false on 400, focus on 400"
    )

    desktop.focuses[2].done(true)
    assertEqual(secondCalls, 1)
    assertEqual(secondResult, "ok")
    assertEqual(desktop.windowManager.isBusy(), false)
    assertEqual(desktop.windowManager.isBusy(400), true)
    assertEqual(desktop.windowManager.isBusy(nil, 10), true)
    assertEqual(desktop.windowManager.focusedTarget().id, 2)

    -- In-flight native.minimize also holds a same-pid request and skips raising the stale window.
    local restore = harness({ nativeDisplaySpaces = true, deferFocus = true, deferMinimize = true })
    local minFirst, minSecond
    restore.windowManager.focus(10, 5, function(ok, err)
      minFirst = ok and "ok" or err
    end, true, nil, 200)
    assertEqual(#restore.minimizes, 1)
    assertEqual(#restore.focuses, 0)
    local restoreCancels = restore.calls.cancelFocus

    restore.windowManager.focus(10, 6, function(ok, err)
      minSecond = ok and "ok" or err
    end, false, nil, 300)
    assertEqual(#restore.switches, 1, "does not switch Space under in-flight native.minimize")
    assertEqual(restore.calls.cancelFocus, restoreCancels)
    assertEqual(#restore.focuses, 0)

    restore.minimizes[1].done(true)
    assertEqual(minFirst, "superseded")
    assertEqual(#restore.switches, 2)
    assertEqual(restore.switches[2], 300)
    assertEqual(#restore.focuses, 1, "skips native.focus for superseded minimized window")
    assertEqual(restore.focuses[1].id, 6)
    restore.focuses[1].done(true)
    assertEqual(minSecond, "ok")
  end
)

test(
  "replacing a remembered same-pid focus supersedes it once, and a different pid proceeds immediately",
  function()
    local desktop = harness({ nativeDisplaySpaces = true, deferFocus = true })
    local results, counts = {}, { 0, 0, 0, 0 }
    local function record(slot)
      return function(ok, err)
        counts[slot] = counts[slot] + 1
        results[slot] = ok and "ok" or err
      end
    end

    desktop.windowManager.focus(10, 1, record(1), false, nil, 300)
    desktop.windowManager.focus(10, 2, record(2), false, nil, 200)
    desktop.windowManager.focus(10, 3, record(3), false, nil, 400)
    assertEqual(results[2], "superseded", "replaced remembered request finishes superseded")
    assertEqual(counts[2], 1, "replaced request callback runs once")
    assertEqual(#desktop.switches, 1)
    assertEqual(#desktop.focuses, 1)
    assertEqual(desktop.windowManager.focusedTarget().id, 3)
    assertEqual(desktop.windowManager.focusedTarget().space, 400)

    desktop.focuses[1].done(true)
    assertEqual(counts[1], 1)
    assertEqual(results[1], "ok", "an in-flight success is still reported")
    assertEqual(counts[2], 1, "replaced request is not called again")
    assertEqual(desktop.calls.spaces, 0, "remembered knownSpace skips native.spaces")
    assertEqual(#desktop.switches, 2)
    assertEqual(desktop.switches[2], 400)
    assertEqual(#desktop.focuses, 2)
    assertEqual(desktop.focuses[2].id, 3)

    -- Different pid proceeds immediately while pid 10 is still in flight.
    desktop.windowManager.focus(20, 9, record(4), false, nil, 200)
    assertEqual(#desktop.switches, 3, "different pid switches Space immediately")
    assertEqual(desktop.switches[3], 200)
    assertEqual(#desktop.focuses, 3, "different pid calls native.focus immediately")
    assertEqual(desktop.focuses[3].pid, 20)
    assertEqual(desktop.focuses[3].id, 9)
    assertEqual(desktop.windowManager.focusedTarget().id, 9)
    assertEqual(desktop.windowManager.focusedTarget().pid, 20)

    desktop.focuses[3].done(true)
    assertEqual(results[4], "ok")
    desktop.focuses[2].done(false, "raise failed (-25204)")
    assertEqual(results[3], "superseded")
    assertEqual(desktop.windowManager.focusedTarget().id, 9)

    -- A different-pid request also supersedes a remembered same-pid request so it never hijacks later.
    local cross = harness({ nativeDisplaySpaces = true, deferFocus = true })
    local crossResults, crossCounts = {}, { 0, 0, 0 }
    local function crossRecord(slot)
      return function(ok, err)
        crossCounts[slot] = crossCounts[slot] + 1
        crossResults[slot] = ok and "ok" or err
      end
    end
    cross.windowManager.focus(10, 1, crossRecord(1), false, nil, 300)
    cross.windowManager.focus(10, 2, crossRecord(2), false, nil, 200)
    cross.windowManager.focus(20, 9, crossRecord(3), false, nil, 400)
    assertEqual(crossResults[2], "superseded")
    assertEqual(crossCounts[2], 1)
    assertEqual(#cross.switches, 2)
    assertEqual(cross.switches[2], 400)
    assertEqual(#cross.focuses, 2)
    assertEqual(cross.focuses[2].pid, 20)

    cross.focuses[1].done(true)
    assertEqual(crossCounts[2], 1)
    assertEqual(#cross.switches, 2, "old pid completion does not replay superseded request")
    assertEqual(#cross.focuses, 2)
    cross.focuses[2].done(true)
    assertEqual(crossResults[3], "ok")
  end
)

test(
  "remembered same-pid focus honours live cancellation without switching and clears on stop",
  function()
    local desktop = harness({ nativeDisplaySpaces = true, deferFocus = true })
    local live = true
    local firstResult, secondResult, secondCalls = nil, nil, 0
    desktop.windowManager.focus(10, 1, function(ok, err)
      firstResult = ok and "ok" or err
    end, false, nil, 300)
    desktop.windowSpace = 200
    desktop.windowManager.focus(
      10,
      2,
      function(ok, err)
        secondCalls = secondCalls + 1
        secondResult = ok and "ok" or err
      end,
      false,
      function()
        return live
      end
    )
    local cancelsBefore = desktop.calls.cancelFocus
    live = false
    desktop.focuses[1].done(true)
    assertEqual(firstResult, "ok")
    assertEqual(secondCalls, 1)
    assertEqual(secondResult, "cancelled")
    assertEqual(#desktop.switches, 1, "cancelled remembered request does not switch Space")
    assertEqual(desktop.current, 300)
    assertEqual(desktop.calls.spaces, 0, "cancelled remembered request does not look up Space")
    assertEqual(desktop.calls.cancelFocus, cancelsBefore)
    assertEqual(#desktop.focuses, 1)
    assertEqual(desktop.windowManager.isBusy(), false)
    assertEqual(desktop.windowManager.focusedTarget(), nil)

    -- stop() finishes a remembered request with stopped and leaves nothing behind.
    local stopCase = harness({ nativeDisplaySpaces = true, deferFocus = true })
    local thirdResult, fourthResult, fourthCalls = nil, nil, 0
    stopCase.windowManager.focus(10, 3, function(ok, err)
      thirdResult = ok and "ok" or err
    end, false, nil, 300)
    stopCase.windowManager.focus(10, 4, function(ok, err)
      fourthCalls = fourthCalls + 1
      fourthResult = ok and "ok" or err
    end, false, nil, 200)
    assertEqual(stopCase.windowManager.isBusy(), true)
    assertEqual(stopCase.windowManager.focusedTarget().id, 4)

    stopCase.windowManager.stop()
    assertEqual(fourthCalls, 1)
    assertEqual(fourthResult, "stopped")
    assertEqual(stopCase.windowManager.isBusy(), false)
    assertEqual(stopCase.windowManager.focusedTarget(), nil)

    stopCase.focuses[1].done(true)
    assertEqual(thirdResult, "ok")
    assertEqual(fourthCalls, 1, "late callback does not re-run stopped request")
    assertEqual(#stopCase.switches, 1)
    assertEqual(#stopCase.focuses, 1)
    assertEqual(stopCase.windowManager.isBusy(), false)

    -- A new same-pid request after stop() proceeds immediately.
    local fifthResult
    stopCase.windowManager.focus(10, 5, function(ok, err)
      fifthResult = ok and "ok" or err
    end, false, nil, 400)
    assertEqual(#stopCase.switches, 2)
    assertEqual(stopCase.switches[2], 400)
    assertEqual(#stopCase.focuses, 2)
    stopCase.focuses[2].done(true)
    assertEqual(fifthResult, "ok")
  end
)

test("a remembered focus starts only behind its own app and a Space switch drops it", function()
  local desktop = harness({ nativeDisplaySpaces = true, deferFocus = true })
  local results = {}
  local function record(slot)
    return function(ok, err)
      results[slot] = ok and "ok" or err
    end
  end
  desktop.windowManager.focus(10, 1, record(1), false, nil, 300)
  desktop.windowManager.focus(20, 9, record(2), false, nil, 200)
  desktop.windowManager.focus(20, 8, record(3), false, nil, 400)
  assertEqual(#desktop.focuses, 2, "the second app's second request is remembered")
  desktop.focuses[1].done(true)
  assertEqual(#desktop.focuses, 2, "another app finishing does not start it")
  assertEqual(#desktop.switches, 2)
  desktop.focuses[2].done(true)
  assertEqual(desktop.focuses[3].id, 8, "its own app finishing starts it")
  assertEqual(desktop.switches[3], 400)
  desktop.focuses[3].done(true)
  assertEqual(results[3], "ok")

  desktop.windowManager.focus(10, 1, record(4), false, nil, 300)
  desktop.windowManager.focus(10, 2, record(5), false, nil, 200)
  desktop:space(1)
  assertEqual(results[5], "superseded", "a direct Space switch drops the remembered request")
  assertEqual(desktop.windowManager.focusedTarget(), nil)
  local switches, focuses = #desktop.switches, #desktop.focuses
  desktop.focuses[focuses].done(true)
  assertEqual(#desktop.switches, switches, "the dropped request never switches the Space back")
  assertEqual(#desktop.focuses, focuses)
  assertEqual(desktop.windowManager.isBusy(), false)
end)

print("RESULT " .. passed .. " passed, 0 failed")

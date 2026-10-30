local root = assert(arg[1])
local canvases, timers, loggedErrors, printedLines, measureCalls = {}, {}, {}, {}, 0
local clockNs = 0 -- whole, as hs.timer.absoluteTime gives
local fakeTap
local fakeGlasses, glassBuildFails = {}, false
---@type string?
local macosInterfaceStyle, fakeWatchers = "Dark", {}
-- Userdata, as in Hammerspoon.
local screenMetatable, styledTextMetatable, screenLefts = {}, {}, {}
screenMetatable.__index = {
  id = function(self)
    return screenLefts[self] / 1000 + 1
  end,
  frame = function(self)
    return { x = screenLefts[self], y = 25, w = 1000, h = 600 }
  end,
}
local function fakeScreen(left)
  local screen = debug.setmetatable(assert(io.open("/dev/null")), screenMetatable)
  screenLefts[screen] = left
  return screen
end
local mainScreen, sideScreen = fakeScreen(0), fakeScreen(1000)
local pluggedScreens, screenWatcherCallback = { mainScreen, sideScreen }, nil
---@type file*?
local focusedScreen = mainScreen
local windowMetatable = { __index = {
  screen = function()
    return sideScreen
  end,
} }
local fakeWindow = debug.setmetatable(assert(io.open("/dev/null")), windowMetatable)
local alert = {}
function alert.show(message, ...)
  return alert.showWithImage(message, nil, ...)
end
local toast = assert(loadfile(
  root .. "/toast.lua",
  "t",
  setmetatable({
    hs = {
      alert = alert,
      host = {
        interfaceStyle = function()
          return macosInterfaceStyle
        end,
      },
      distributednotifications = {
        new = function(callback, name)
          local watcher = { callback = callback, name = name }
          function watcher.start()
            watcher.running = true
            return watcher
          end
          function watcher.stop()
            watcher.running = false
            return watcher
          end
          fakeWatchers[#fakeWatchers + 1] = watcher
          return watcher
        end,
      },
      getObjectMetatable = function(name)
        local metatablesByName = {
          ["hs.styledtext"] = styledTextMetatable,
          ["hs.screen"] = screenMetatable,
          ["hs.window"] = windowMetatable,
        }
        return metatablesByName[name]
      end,
      screen = {
        find = function(hint)
          for _, screen in ipairs(pluggedScreens) do
            if
              hint == screenMetatable.__index.id(screen) or hint == tostring(screenLefts[screen])
            then
              return screen
            end
          end
        end,
        primaryScreen = function()
          return pluggedScreens[1]
        end,
        watcher = {
          new = function(callback)
            return setmetatable({
              start = function(self)
                screenWatcherCallback = callback
                return self
              end,
            }, {
              -- Collected, Hammerspoon's watcher stops.
              __gc = function()
                screenWatcherCallback = nil
              end,
            })
          end,
        },
      },
      spaces = {
        focusedSpace = function()
          return 7
        end,
        spaceDisplay = function(space)
          assert(space == 7, "not the focused Space")
          if not focusedScreen then
            return nil, "space not found in managed displays"
          end
          return tostring(screenLefts[focusedScreen])
        end,
      },
      styledtext = {
        new = function(text, style)
          local styleCopy = {}
          for key, value in pairs(style) do
            styleCopy[key] = value
          end
          return { text = text, style = styleCopy }
        end,
      },
      eventtap = {
        event = {
          types = {
            leftMouseDown = 1,
            leftMouseUp = 2,
            rightMouseDown = 3,
            rightMouseUp = 4,
            otherMouseDown = 25,
            otherMouseUp = 26,
          },
          properties = { mouseEventClickState = 1, mouseEventButtonNumber = 3 },
        },
        -- No stop: toast.lua never stops the tap.
        new = function(eventMask, callback)
          fakeTap = { callback = callback, enabledTypes = {} }
          for _, eventType in ipairs(eventMask) do
            -- Toggled, as libeventtap's mask bit is.
            fakeTap.enabledTypes[eventType] = not fakeTap.enabledTypes[eventType]
          end
          function fakeTap.start()
            fakeTap.running = true
          end
          return fakeTap
        end,
      },
      timer = {
        absoluteTime = function()
          return clockNs
        end,
        -- Holds its callback in the registry until collected, as hs.timer does.
        doAfter = function(seconds, callback)
          local timer, registryKey =
            { seconds = seconds, callback = callback, dueNs = clockNs + math.floor(seconds * 1e9) },
            {}
          debug.getregistry()[registryKey] = callback
          setmetatable(timer, {
            __gc = function()
              debug.getregistry()[registryKey] = nil
            end,
          })
          function timer.stop()
            timer.stopped = true
          end
          timers[#timers + 1] = timer
          return timer
        end,
      },
      canvas = {
        windowLevels = { dock = 20 },
        new = function()
          local canvas = { elements = {}, visible = false, deleted = false, recordedCalls = {} }
          function canvas.minimumTextSize(_, styledText)
            measureCalls = measureCalls + 1
            local width, lines = 0, 0
            for line in styledText.text:gmatch("[^\n]+") do
              width, lines = math.max(width, 7 * #line), lines + 1
            end
            return { w = width, h = 16 * lines }
          end
          function canvas.size(_, size)
            canvas.frame = size or canvas.frame
            return canvas.frame
          end
          function canvas.topLeft(_, point)
            canvas.origin = point
          end
          function canvas.replaceElements(_, ...)
            local elements = ...
            assert(select("#", ...) == 1 and elements[1], "not one array of elements")
            canvas.elements = { table.unpack(elements) }
          end
          function canvas.behaviorAsLabels(_, labels)
            local sorted = { table.unpack(labels) }
            table.sort(sorted)
            canvas.behaviorLabels = table.concat(sorted, " ")
          end
          -- Without one, its window ignores clicks.
          function canvas.mouseCallback(_, ...)
            local callback = ...
            assert(
              select("#", ...) == 1 and (callback == nil or type(callback) == "function"),
              "not a function or nil"
            )
            canvas.mouseHandler = callback
          end
          function canvas.show()
            canvas.visible = true
          end
          canvas.orderedOut, canvas.reappeared, canvas.opacity = false, false, 1
          function canvas.alpha(_, value)
            canvas.opacity = value or canvas.opacity
            return canvas.opacity
          end
          function canvas.delete()
            canvas.deleted, canvas.orderedOut = true, true
          end
          for _, method in ipairs({ "level", "clickActivating", "canvasMouseEvents" }) do
            rawset(canvas, method, function(_, ...)
              canvas.recordedCalls[method] = { ... }
            end)
          end
          setmetatable(canvas, {
            __index = function(_, key)
              error("no hs.canvas method " .. key, 2)
            end,
          })
          canvases[#canvases + 1] = canvas
          return canvas
        end,
      },
    },
    require = function(name)
      if name == "lib.utils" then
        return {
          native = function(moduleName)
            assert(moduleName == "toast" and not glassBuildFails, "toast: native build failed")
            return {
              glass = function(canvas, cornerRadius, fadeSeconds, darkAppearance)
                assert(type(darkAppearance) == "boolean", "no appearance for the glass")
                assert(
                  type(cornerRadius) == "number" and type(fadeSeconds) == "number",
                  "no radius or fade"
                )
                local glass = { canvas = canvas, dark = darkAppearance }
                function glass.hide(_, hideSeconds)
                  glass.hideFade = hideSeconds
                end
                function glass.paint(_, darkNow)
                  glass.dark = darkNow
                end
                fakeGlasses[#fakeGlasses + 1] = glass
                return glass
              end,
            }
          end,
        }
      end
      assert(name == "lib.logger")
      return {
        error = function(message)
          loggedErrors[#loggedErrors + 1] = message
        end,
      }
    end,
    -- Raises after logging, as hs.ipc's does while a dead `hs` CLI is registered.
    print = function(...)
      printedLines[#printedLines + 1] = table.concat({ ... }, "\t")
      error("dead hs CLI")
    end,
  }, { __index = _G })
))()
local shownIds, realShow = {}, toast.show
function toast.show(...)
  local id = realShow(...)
  shownIds[#shownIds + 1] = id
  return id
end
local function reset()
  for _, id in ipairs(shownIds) do
    toast.close(id, 0)
  end
  shownIds, canvases, timers, fakeGlasses, focusedScreen, macosInterfaceStyle =
    {}, {}, {}, {}, mainScreen, "Dark"
  pluggedScreens = { mainScreen, sideScreen }
end
local function assertEqual(actual, expected, label)
  assert(
    actual == expected,
    (label or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual)
  )
end
local passed = 0
local function test(name, body)
  reset()
  body()
  passed = passed + 1
  print("PASS " .. name)
end
local function textsOf(canvas)
  local foundTexts = {}
  for _, element in ipairs(canvas.elements) do
    if element.type == "text" then
      foundTexts[#foundTexts + 1] = element.text.text
    end
  end
  return table.concat(foundTexts, " | ")
end
local function findElement(canvas, kind)
  for _, element in ipairs(canvas.elements) do
    if element.type == kind then
      return element
    end
  end
end
local function rimGrays(canvas)
  local levels = {}
  for index, color in ipairs(findElement(canvas, "rectangle").fillGradientColors) do
    levels[index] = color.white
  end
  return table.concat(levels, " ")
end
local function textGrays(canvas)
  local levels = {}
  for _, element in ipairs(canvas.elements) do
    if element.type == "text" then
      levels[#levels + 1] = element.text.style.color.white
    end
  end
  return levels
end
local function bottomOf(canvas)
  return canvas.origin.y + canvas.frame.h
end
local function pointInside(canvas)
  return { x = canvas.origin.x + 5, y = canvas.origin.y + 5 }
end
-- A down via the tap (false: swallowed; nil: reached beneath; else the toast hit) and its release.
local function holdClick(point, clickState, button, beforeToastHears)
  button = button or 0
  local downType = ({ [0] = 1, [1] = 3 })[button] or 25
  local function tapSwallows(eventType)
    return fakeTap
      and fakeTap.running
      and fakeTap.enabledTypes[eventType]
      and fakeTap.callback({
        getProperty = function(_, propertyCode)
          assert(propertyCode == 1 or propertyCode == 3, "not the click state or button")
          return propertyCode == 1 and clickState or button
        end,
        getType = function()
          return eventType
        end,
      })
  end
  local swallowed, toastHit = tapSwallows(downType), nil
  for _, canvas in ipairs(canvases) do
    local onScreen = canvas.visible and not canvas.orderedOut
    local underPoint = point.x >= canvas.origin.x
      and point.x < canvas.origin.x + canvas.frame.w
      and point.y >= canvas.origin.y
      and point.y < bottomOf(canvas)
    if not swallowed and onScreen and underPoint and rawget(canvas, "mouseHandler") then
      toastHit = canvas
    end
  end
  local function deliverToToast(phase)
    if
      toastHit
      and rawget(toastHit, "mouseHandler")
      and (toastHit.recordedCalls.canvasMouseEvents or {})[phase]
    then
      toastHit.mouseHandler(toastHit, phase == 1 and "mouseDown" or "mouseUp")
    end
  end
  -- Runs after the down reaches its window, before the toast hears of it.
  if beforeToastHears then
    beforeToastHears()
  end
  deliverToToast(1)
  -- upMissedTap: the up passed before the tap started, as a quick first click's can.
  return not swallowed and toastHit,
    function(upMissedTap)
      assert(
        upMissedTap or not tapSwallows(downType + 1) == not swallowed,
        "a click's down and up split"
      )
      if toastHit then
        -- A window ordered out under a held click comes back (live, only a left single click).
        toastHit.reappeared = toastHit.orderedOut
      end
      deliverToToast(2)
    end
end
local function click(...)
  local hit, release = holdClick(...)
  release()
  return hit
end
local function isDrawn(canvas)
  return (canvas.visible and not canvas.orderedOut or canvas.reappeared) and canvas.opacity > 0
end
-- Runs each timer when due unless collected, as hs.timer does.
local function advanceClock(seconds)
  local untilNs = clockNs + math.floor(seconds * 1e9)
  while true do
    local nextIndex
    for index, timer in ipairs(timers) do
      local isDue = timer and not timer.stopped and timer.dueNs <= untilNs
      if isDue and (not nextIndex or timer.dueNs < timers[nextIndex].dueNs) then
        nextIndex = index
      end
    end
    clockNs = math.max(clockNs, nextIndex and timers[nextIndex].dueNs or untilNs)
    if not nextIndex then
      return
    end
    local weakTimer = setmetatable({}, { __mode = "v" })
    weakTimer[1], timers[nextIndex] = timers[nextIndex], false
    collectgarbage()
    if weakTimer[1] then
      weakTimer[1].callback()
    end
  end
end
-- Seconds until it is no longer drawn, to the nearest 0.05 s.
local function secondsUntilHidden(canvas)
  local frameCount = 0
  repeat
    advanceClock(1 / 60)
    frameCount = frameCount + 1
  until not isDrawn(canvas) or frameCount == 600
  return math.floor(frameCount / 3 + 0.5) / 20
end

test("a failure sits at the bottom right, titled by its source, with a red cross", function()
  toast.show("Tiling: no focused window", { failure = true, seconds = 5 })
  local canvas = canvases[1]
  assertEqual(textsOf(canvas), "Tiling | No focused window")
  assert(findElement(canvas, "circle") and canvas.visible and timers[1].seconds == 5)
  assert(
    canvas.origin.x + canvas.frame.w == 1000 - 16 and bottomOf(canvas) == 609,
    "not bottom right"
  )
  assertEqual(canvas.behaviorLabels, "canJoinAllSpaces fullScreenAuxiliary stationary")
  assert(canvas.recordedCalls.clickActivating[1] == false)
  assert(canvas.recordedCalls.level[1] == 19, "not just below the Dock")
end)

test("a newer toast stacks below the older, which drops back when it goes", function()
  toast.show("first")
  toast.show("second", { seconds = 1 })
  local firstCanvas, secondCanvas = canvases[1], canvases[2]
  assert(bottomOf(secondCanvas) == 609 and bottomOf(firstCanvas) == secondCanvas.origin.y - 8)
  assert(
    textsOf(firstCanvas) == "first"
      and not findElement(firstCanvas, "circle")
      and not findElement(firstCanvas, "image"),
    "an info toast has an icon"
  )
  advanceClock(1)
  assert(secondCanvas.deleted and not firstCanvas.deleted and bottomOf(firstCanvas) == 609)
  assert(
    secondsUntilHidden(secondCanvas) == 0,
    "it faded while the toast above moved into its place"
  )
  advanceClock(2)
  assert(secondsUntilHidden(firstCanvas) == 0.25, "the oldest did not fade")
end)

test("a toast stays on its screen when focus and the stack change", function()
  toast.show("on main")
  focusedScreen = sideScreen
  toast.show("on side")
  assert(canvases[1].origin.x < 1000 and canvases[2].origin.x >= 1000, "a toast moved screens")
  assert(bottomOf(canvases[1]) == 609 and bottomOf(canvases[2]) == 609, "screens share one stack")
  timers[2].callback()
  assert(secondsUntilHidden(canvases[2]) == 0.25, "the side screen's oldest did not fade")
end)

test("a closed toast lets clicks through while it fades", function()
  toast.close(toast.show("fading"), 5)
  local canvas = canvases[1]
  advanceClock(2.5)
  assert(canvas.opacity > 0 and canvas.opacity < 1, "it did not fade")
  assert(click(pointInside(canvas), 1) == nil, "the fading toast took it")
  assert(secondsUntilHidden(canvas) == 2.5)
end)

test("a multi-click closes only its toast, and the rest of it reaches nothing", function()
  -- The bottom toast is triple-clicked.
  for _, case in ipairs({
    { "older", "newer", button = 1, held = 0 }, -- right, left held; first: a press starts the tap
    { "older", "newer" },
    { "lone", late = "late" }, -- shown between the clicks
    { "older", "newer", button = 3, held = 2 }, -- button 4, with the middle held
    { "older", "newer", single = true },
  }) do
    for _, text in ipairs(case) do
      toast.show(text)
    end
    local target
    for _, canvas in ipairs(canvases) do
      if bottomOf(canvas) == 609 then
        target = canvas
      end
    end
    local toastPoint, awayPoint = pointInside(target), { x = 5, y = 30 }
    -- Another button's double-click, or single click, ends after the toast's first click, held.
    if not case.single then
      click(awayPoint, 1, case.held or 1)
    end
    assert(click(toastPoint, 1, case.button) == target, "the click missed it")
    local beneath, releaseOther = holdClick(awayPoint, case.single and 1 or 2, case.held or 1)
    assert(beneath == nil, "another button's click was swallowed")
    assert(not target.reappeared, "its window came back when the click was let go")
    if case.late then
      toast.show(case.late)
    end
    local secondHit, release = holdClick(toastPoint, 2, case.button)
    releaseOther()
    release()
    local restOfClick = { secondHit, click(toastPoint, 3, case.button) }
    assert(restOfClick[1] == false and restOfClick[2] == false, "the rest of the click got through")
    assert(
      click(awayPoint, 1, case.button) == nil and click(awayPoint, 2, case.button) == nil,
      "a later double-click was swallowed"
    )
    reset()
  end
  toast.show("lone")
  local toastPoint, awayPoint = pointInside(canvases[1]), { x = 5, y = 30 }
  click(awayPoint, 1, 0)
  fakeTap.running = false -- misses the next up; its last stays the left click above
  local _, release = holdClick(toastPoint, 1, 1)
  release(true)
  assert(click(toastPoint, 2, 1) == false, "the rest of a quick click got through")
  assert(
    click(awayPoint, 1, 0) == nil and click(awayPoint, 2, 0) == nil,
    "a later double-click was swallowed"
  )
end)

test("a toast pressed while closed waits for its release, then uses the close's fade", function()
  toast.install()
  toast.show("older")
  toast.show("pressed")
  local older, pressed = canvases[1], canvases[2]
  local hit, release = holdClick(pointInside(pressed), 1)
  assert(hit == pressed)
  timers[2].callback()
  alert.closeAll()
  assert(secondsUntilHidden(older) == 0.25, "the oldest did not fade")
  assert(rawget(pressed, "mouseHandler"), "a pressed toast closed")
  release()
  assert(secondsUntilHidden(pressed) == 0.25, "it did not fade once let go")
  assert(not pressed.reappeared, "its window came back when the click was let go")
  local heldId = alert.show("held", "indefinite")
  local _, releaseHeld = holdClick(pointInside(canvases[3]), 1)
  alert.closeSpecific(heldId, 0)
  releaseHeld()
  assert(secondsUntilHidden(canvases[3]) == 0, "a close at once faded once let go")
end)

test("a toast closed under a press it has not heard of ends at alpha 0, after any fade", function()
  local function fireTimer(index)
    return function()
      timers[index].callback()
    end
  end
  local closedCanvases = setmetatable({}, { __mode = "k" })
  for _, case in ipairs({
    { { "older", "target" }, 0, fireTimer(2) }, -- times out, not its screen's oldest
    { { "target" }, 0.25, fireTimer(1) },
  }) do
    for _, text in ipairs(case[1]) do
      toast.show(text)
    end
    local target = canvases[#canvases]
    local _, release = holdClick(pointInside(target), 1, nil, case[3])
    assert(case[2] == 0 or target.opacity == 1, "its fade was not seen")
    -- Let go once its window is ordered out, before any timer set for after its fade.
    assert(secondsUntilHidden(target) == case[2], "it stayed or did not fade as asked")
    release()
    assert(target.reappeared and not isDrawn(target), "its window came back drawn")
    closedCanvases[target] = true
    reset()
  end
  for _ = 1, 3 do
    collectgarbage()
  end
  assert(next(closedCanvases) == nil, "a closed toast is never collected")
end)

test("a toast without a focused display is printed instead, never raising", function()
  focusedScreen = nil
  local ok, id = pcall(toast.show, "Tiling: lost")
  assert(ok, "a toast without a focused display raised: " .. tostring(id))
  assert(id == nil and #canvases == 0, "a toast without a focused display was shown")
  assert(
    printedLines[1] and printedLines[1]:find("Tiling: lost", 1, true),
    tostring(printedLines[1])
  )
end)

test("the same toast again restarts its time on its screen instead of stacking", function()
  local id = toast.show("Window list unavailable", { seconds = 2 })
  assert(toast.show("Window list unavailable", { seconds = 2 }) == id, "a repeat lost its id")
  assert(#canvases == 1 and timers[1].stopped and timers[2].seconds == 2)
  focusedScreen = sideScreen
  toast.show("Window list unavailable", { seconds = 2 })
  assert(#canvases == 2 and canvases[2].origin.x >= 1000, "the repeat stayed on the other screen")
  reset()
  toast.show("old")
  toast.show("new")
  toast.show("old")
  assert(#canvases == 2 and bottomOf(canvases[1]) == 609, "the repeat is not the newest")
end)

test("long text wraps to three lines, measured once a word until then", function()
  measureCalls = 0
  toast.show(("word "):rep(600), { failure = true })
  local lines = select(2, textsOf(canvases[1]):gsub("\n", "")) + 1
  assert(lines == 3 and canvases[1].frame.w <= 14 + 26 + 340 + 14, lines)
  assert(measureCalls < 40, measureCalls .. " measurements: the last line is measured again a word")
  reset()
  toast.show("Tiling: " .. ("word "):rep(600))
  assert(select(2, textsOf(canvases[1]):gsub("\n", "")) == 2, textsOf(canvases[1]):sub(1, 80))
end)

test("a line break is kept, blank or not, unless trailing, and a name keeps its case", function()
  toast.install()
  alert.show("⌘A: Alpha\n⌘B: Beta\n⌘C: Gamma\n⌘D: Delta")
  assertEqual(textsOf(canvases[1]), "⌘A: Alpha\n⌘B: Beta\n⌘C: Gamma ⌘D: Delta")
  alert.show("Title\n\nDetail")
  assertEqual(textsOf(canvases[2]), "Title\n\nDetail")
  toast.show("Space focus: macOS refused it")
  assertEqual(textsOf(canvases[3]), "Space focus | macOS refused it")
  toast.show("Could not write Hammerspoon file log: denied")
  assertEqual(textsOf(canvases[4]), "Could not write Hammerspoon file log: denied")
  toast.show("Синхронизация: готово") -- 13 characters, 26 bytes
  assertEqual(textsOf(canvases[5]), "Синхронизация | готово")
  assert(pcall(toast.show, "caf\xe9: done"), "a title that isn't UTF-8 raised")
  assertEqual(textsOf(canvases[6]), "caf\xe9 | Done")
  alert.show("Done\n")
  assertEqual(textsOf(canvases[7]), "Done")
end)

test("install picks the theme, and an unknown one is logged and fails the load", function()
  toast.install({ theme = "edge" })
  toast.show("edged")
  local edgeRim = rimGrays(canvases[1])
  reset()
  local ok, problem = pcall(toast.install, { theme = "chrome" })
  assert(not ok and tostring(problem):find("no theme chrome", 1, true), tostring(problem))
  assert(
    loggedErrors[1] and loggedErrors[1]:find("no theme chrome", 1, true),
    tostring(loggedErrors[1])
  )
  toast.install({ appearance = "dark" })
  ok, problem = pcall(toast.install, { theme = "edge", appearance = "sepia" })
  assert(problem and tostring(problem):find("no appearance sepia", 1, true), "sepia loaded")
  assert(
    loggedErrors[2] and loggedErrors[2]:find("no appearance sepia", 1, true),
    tostring(loggedErrors[2])
  )
  for _, invalidOptions in ipairs({ { theme = false }, { appearance = false } }) do
    assert(not pcall(toast.install, invalidOptions), "false fell back to a default")
  end
  toast.show("metal")
  assert(rimGrays(canvases[1]) ~= edgeRim, "the edge theme did not change the rim")
end)

test("light and dark each draw their own colors, and system starts as macOS is", function()
  for _, name in ipairs({ "metal", "edge", "flat", "glass" }) do
    local rimsByAppearance = {}
    -- The appearance, macOS's, and whether it is dark.
    for index, case in ipairs({
      { "dark", nil, true },
      { "light", "Dark", false },
      { "system", "Dark", true },
      { "system", nil, false },
    }) do
      macosInterfaceStyle = case[2]
      toast.install({ theme = name, appearance = case[1] })
      toast.show("Tiling: no focused window", { failure = true })
      local canvas, titleGray, detailGray = canvases[1], table.unpack(textGrays(canvases[1]))
      local caseLabel, expectDark = ("%s case %d"):format(name, index), case[3]
      assert(
        expectDark == (titleGray > 0.5) and expectDark == (detailGray > 0.5),
        caseLabel .. ": text in the other tone"
      )
      assert(
        name ~= "glass" or fakeGlasses[1].dark == expectDark,
        caseLabel .. ": glass in the other appearance"
      )
      assert(findElement(canvas, "circle"), caseLabel .. ": the failure lost its cross")
      local appearanceKey, rimLook =
        tostring(expectDark), findElement(canvas, "rectangle") and rimGrays(canvas)
      rimsByAppearance[appearanceKey] = rimsByAppearance[appearanceKey] or rimLook
      assert(rimsByAppearance[appearanceKey] == rimLook, caseLabel .. ": one appearance, two rims")
      reset()
    end
    assert(
      name == "glass" or rimsByAppearance["true"] ~= rimsByAppearance["false"],
      name .. ": light has the dark rim"
    )
  end
end)

test("system redraws shown toasts in place as macOS switches, until installed otherwise", function()
  for _, name in ipairs({ "metal", "glass" }) do
    macosInterfaceStyle = nil
    toast.install({ theme = name })
    local watcher = fakeWatchers[#fakeWatchers]
    assert(watcher and watcher.running, "system does not follow macOS")
    assertEqual(watcher.name, "AppleInterfaceThemeChangedNotification")
    toast.show("Config reloaded", { seconds = false })
    toast.show("Tiling: no window", { failure = true })
    local beforeSwitch = {}
    for index, canvas in ipairs(canvases) do
      beforeSwitch[index] =
        { x = canvas.origin.x, y = canvas.origin.y, title = textGrays(canvas)[1] }
      beforeSwitch[index].look = name == "glass" or rimGrays(canvas)
    end
    watcher.callback("AppleInterfaceThemeChangedNotification")
    assert(textGrays(canvases[1])[1] < 0.5, name .. ": it switched while macOS stayed light")
    macosInterfaceStyle = "Dark"
    watcher.callback("AppleInterfaceThemeChangedNotification")
    assert(#canvases == 2 and #timers == 1, "a toast was shown or timed again")
    for index, canvas in ipairs(canvases) do
      local moved = canvas.origin.x ~= beforeSwitch[index].x
        or canvas.origin.y ~= beforeSwitch[index].y
      assert(not moved and isDrawn(canvas), "a toast moved or went")
      assert(
        textGrays(canvas)[1] > 0.5 and beforeSwitch[index].title < 0.5,
        name .. ": its text did not turn light"
      )
      assert(
        name == "glass" or rimGrays(canvas) ~= beforeSwitch[index].look,
        "its rim stayed light"
      )
      assert(
        textsOf(canvas) == ({ "Config reloaded", "Tiling | No window" })[index],
        textsOf(canvas)
      )
      assert(name ~= "glass" or fakeGlasses[index].dark == true, "its glass stayed light")
    end
    assert(findElement(canvases[2], "circle"), "the failure lost its cross")
    assert(#fakeGlasses == (name == "glass" and 2 or 0), "a glass was added")
    reset()
  end
  toast.install({ appearance = "light" })
  assert(not fakeWatchers[#fakeWatchers].running, "a watcher was left following macOS")
  local watcherCount = #fakeWatchers
  toast.install({ appearance = "dark" })
  assert(#fakeWatchers == watcherCount, "an explicit appearance follows macOS")
end)

test("installing again redraws shown toasts in place, in its theme and appearance", function()
  toast.install({ appearance = "dark" })
  toast.show("Config reloaded", { seconds = false })
  toast.show("Tiling: no window", { failure = true })
  local darkRim, secondTop, timerCount = rimGrays(canvases[1]), canvases[2].origin.y, #timers
  toast.install({ appearance = "light" })
  assert(textGrays(canvases[1])[1] < 0.5 and rimGrays(canvases[1]) ~= darkRim, "it stayed dark")
  toast.install({ theme = "glass", appearance = "light" })
  for index, canvas in ipairs(canvases) do
    assert(not findElement(canvas, "rectangle"), "a rim over the glass")
    assert(
      fakeGlasses[index]
        and fakeGlasses[index].canvas == canvas
        and fakeGlasses[index].dark == false,
      "no light glass"
    )
  end
  toast.install({ theme = "glass", appearance = "dark" })
  assert(#fakeGlasses == 2 and fakeGlasses[1].dark == true, "its glass was doubled or stayed light")
  toast.install({ appearance = "dark" })
  assert(
    rimGrays(canvases[1]) == darkRim and fakeGlasses[1].hideFade and fakeGlasses[2].hideFade,
    "glass stayed"
  )
  assert(
    #canvases == 2 and #timers == timerCount and canvases[2].origin.y == secondTop,
    "a toast was remade or moved"
  )
  toast.install({ theme = "glass", appearance = "dark" })
  assert(#fakeGlasses == 4 and fakeGlasses[3].canvas == canvases[1], "no glass after metal")
  toast.install({ appearance = "dark" })
  assert(isDrawn(canvases[1]) and isDrawn(canvases[2]) and findElement(canvases[2], "circle"))
end)

test("glass that can't be built fails the load, as an unknown theme does", function()
  glassBuildFails = true
  local ok, problem = pcall(toast.install, { theme = "glass" })
  assert(not ok and tostring(problem):find("native build failed", 1, true), tostring(problem))
  glassBuildFails = false
  toast.show("still metal")
  assert(
    findElement(canvases[1], "rectangle") and #fakeGlasses == 0,
    "a failed build changed the theme"
  )
end)

test("glass: each toast has its own, hidden with the toast's fade, under shadowed text", function()
  toast.install({ theme = "glass" })
  toast.show("first")
  toast.show("Second: detail", { failure = true })
  local firstCanvas, secondCanvas = canvases[1], canvases[2]
  assert(
    not findElement(firstCanvas, "rectangle") and not findElement(secondCanvas, "rectangle"),
    "a rim over the glass"
  )
  for _, element in ipairs(secondCanvas.elements) do
    assert(element.type ~= "text" or element.text.style.shadow, "glass text has no shadow")
  end
  assert(
    #fakeGlasses == 2
      and fakeGlasses[1].canvas == firstCanvas
      and fakeGlasses[2].canvas == secondCanvas
  )
  click(pointInside(secondCanvas), 1)
  alert.closeAll()
  assert(
    fakeGlasses[2].hideFade == secondsUntilHidden(secondCanvas)
      and fakeGlasses[1].hideFade == secondsUntilHidden(firstCanvas),
    "a glass stayed"
  )
  toast.install()
  toast.show("metal")
  assert(not findElement(canvases[3], "text").text.style.shadow, "the glass shadow stayed")
end)

test("every hs.alert is a toast, with its seconds and screen", function()
  toast.install()
  alert.show("Could not switch to that window", 4)
  alert.show("Focused display unavailable", {}, sideScreen, 7)
  alert.show(setmetatable({}, {
    __tostring = function()
      return "hs.window: Notes"
    end,
  }))
  assert(textsOf(canvases[1]) == "Could not switch to that window" and timers[1].seconds == 4)
  assert(canvases[2].origin.x >= 1000 and timers[2].seconds == 7, "the screen or seconds were lost")
  assert(
    textsOf(canvases[3]) == "hs.window | Notes" and timers[3].seconds == 2,
    textsOf(canvases[3])
  )
  local message = setmetatable({}, styledTextMetatable)
  function message.getString()
    return "styled"
  end
  alert.show(message)
  assertEqual(textsOf(canvases[4]), "styled")
  alert.show(io.stdout) -- not styled text
  assert(textsOf(canvases[5]):find("^file %("), textsOf(canvases[5]))
  alert.show("on the window's screen", fakeWindow, 2)
  alert.show("false is the default", false)
  assert(canvases[6].origin.x >= 1000 and timers[6].seconds == 2, "a window is not its screen")
  assert(timers[7] and timers[7].seconds == 2, "false is not hs.alert's 2 s default")
end)

test("an hs.alert with non-number seconds stays until closed by its id", function()
  toast.install()
  assert(not pcall(alert.closeAll, true), "a fade of true was taken with none shown")
  local id = alert.show("Working…", "indefinite")
  alert.show("other", 1)
  assert(#timers == 1, "the indefinite one got a timer")
  alert.closeSpecific(id)
  assert(secondsUntilHidden(canvases[1]) == 0.25 and not canvases[2].deleted)
  alert.show("another", 1)
  alert.closeAll()
  assert(isDrawn(canvases[3]) and secondsUntilHidden(canvases[2]) == 0.25 and canvases[3].deleted)
  alert.closeSpecific(alert.show("now", "indefinite"), 0)
  alert.show("all now", 5)
  alert.closeAll(0)
  assert(
    secondsUntilHidden(canvases[4]) == 0 and secondsUntilHidden(canvases[5]) == 0,
    "a close ignored its fade time"
  )
  alert.show("above", "indefinite")
  local stuckId = alert.show("stuck?", "indefinite")
  assert(not pcall(alert.closeSpecific, stuckId, true), "a fade of true was taken")
  assert(not pcall(alert.closeSpecific, 999, true), "a fade of true was taken for an unknown id")
  alert.closeAll()
  assert(secondsUntilHidden(canvases[7]) == 0.25, "a failed close left a toast nothing can close")
end)

test("each hs.alert kept until closed has its own id, and an old id closes nothing", function()
  toast.install()
  local firstId = alert.show("Working…", "indefinite")
  local secondId = alert.show("Working…", "indefinite")
  assert(firstId ~= secondId and #canvases == 2, "two callers share one alert")
  assertEqual(type(firstId), "string", "hs.alert's id type")
  alert.closeSpecific(firstId)
  assert(secondsUntilHidden(canvases[1]) == 0.25, "the closed one did not fade")
  assert(not canvases[2].deleted, "closing one closed the other")
  alert.show("Working…", 2)
  assert(#canvases == 3 and timers[#timers].seconds == 2, "a timed repeat merged into a kept alert")
  alert.show("Working…", "indefinite")
  assert(#canvases == 4, "a kept alert merged into a timed one")
  reset()
  local timedId = alert.show("Done", 2)
  alert.closeSpecific(timedId)
  local againId = alert.show("Done", 2)
  alert.closeSpecific(timedId)
  assert(againId ~= timedId and not canvases[2].deleted, "an old id closed a later alert")
end)

test("the cap drops a screen's oldest unpressed timed toast, never a kept one", function()
  toast.install()
  for index = 1, 6 do
    toast.show("toast " .. index)
  end
  assert(canvases[1].deleted and not canvases[2].deleted, "the cap dropped no toast or two")
  assert(
    secondsUntilHidden(canvases[1]) == 0,
    "the dropped toast faded under the one moving into its place"
  )
  reset()
  local keptId = alert.show("Working…", "indefinite")
  for index = 1, 5 do
    toast.show("toast " .. index)
  end
  assert(not canvases[1].deleted and canvases[2].deleted, "the cap dropped the kept alert")
  focusedScreen = sideScreen
  for index = 1, 5 do
    toast.show("side " .. index)
  end
  assert(not canvases[3].deleted, "another screen's toasts counted toward this screen's cap")
  alert.closeSpecific(keptId)
  reset()
  for index = 1, 5 do
    toast.show("toast " .. index)
  end
  local _, release = holdClick(pointInside(canvases[1]), 1)
  toast.show("sixth")
  assert(not canvases[1].deleted, "the cap dropped the pressed toast")
  assert(canvases[2].deleted, "the cap dropped no unpressed toast")
  release()
  reset()
  for _ = 1, 6 do
    alert.show("Working…", "indefinite")
  end
  toast.show("timed")
  assert(not canvases[7].deleted, "the cap dropped the toast it was making room for")
end)

test("a toast whose display is unplugged moves to the primary one, within its cap", function()
  focusedScreen = sideScreen
  toast.show("Working…", { seconds = false })
  collectgarbage()
  assert(screenWatcherCallback, "nothing watches the displays")
  screenWatcherCallback()
  assert(canvases[1].origin.x >= 1000, "it left a display still plugged in")
  pluggedScreens = {}
  assert(pcall(screenWatcherCallback), "no display listed broke it")
  pluggedScreens = { mainScreen }
  screenWatcherCallback()
  assert(
    canvases[1].origin.x < 1000 and bottomOf(canvases[1]) == 609,
    "it stayed on the gone display"
  )
  reset()
  for index = 1, 4 do
    toast.show("main " .. index)
  end
  focusedScreen = sideScreen
  toast.show("Working…", { seconds = false })
  toast.show("side 1")
  toast.show("side 2")
  pluggedScreens = { mainScreen }
  screenWatcherCallback()
  assert(canvases[1].deleted and canvases[2].deleted, "the cap kept more than five")
  for index = 3, 7 do
    assert(
      not canvases[index].deleted and canvases[index].origin.x < 1000,
      "it stayed on the gone display"
    )
  end
  assert(
    bottomOf(canvases[6]) == canvases[7].origin.y - 8 and bottomOf(canvases[7]) == 609,
    "unstacked"
  )
end)

test("a failure and a plain toast with the same text are not repeats", function()
  toast.show("Window list unavailable")
  toast.show("Window list unavailable", { failure = true })
  assert(#canvases == 2 and findElement(canvases[2], "circle"), "the failure merged")
end)

test("hs.alert.showWithImage shows its image as the icon, never repeated as plain", function()
  toast.install()
  local image = {}
  alert.showWithImage("Synced", image, 2)
  local icon = findElement(canvases[1], "image")
  assert(icon and icon.image == image, "no image")
  assert(
    findElement(canvases[1], "text").frame.x >= icon.frame.x + icon.frame.w,
    "the text is not past the icon"
  )
  alert.show("Synced", 2)
  assert(#canvases == 2 and not findElement(canvases[2], "image"), "the plain one kept the icon")
  alert.showWithImage("Synced", image, 2)
  assert(#canvases == 3, "the image merged into the plain one")
end)

test("an argument hs.alert would not take is an error, as in hs.alert", function()
  toast.install()
  local ok, problem = pcall(alert.show, "x", {}, sideScreen, 2, 3)
  assert(not ok and tostring(problem):find("unexpected number", 1, true), tostring(problem))
  ok, problem = pcall(alert.show, "x", io.stdout)
  assert(not ok and tostring(problem):find("argument 2", 1, true), tostring(problem))
  assert(#canvases == 0, "a toast was shown")
  alert.show("kept", sideScreen, io.stdout)
  assert(#canvases == 1 and #timers == 0, "a userdata after the screen was no seconds")
end)

print("RESULT " .. passed .. " passed, 0 failed")

local root = assert(arg[1])
local canvases, timers, logged, printed, measured = {}, {}, {}, {}, 0
local clock = 0 -- ns, as hs.timer.absoluteTime gives
local tap
local glasses, unbuilt = {}, false
-- Userdata, as in Hammerspoon.
local screens, styled, at = {}, {}, {}
screens.__index = {
  id = function(self)
    return at[self] / 1000 + 1
  end,
  frame = function(self)
    return { x = at[self], y = 25, w = 1000, h = 600 }
  end,
}
local function display(x)
  local screen = debug.setmetatable(assert(io.open("/dev/null")), screens)
  at[screen] = x
  return screen
end
local main, side = display(0), display(1000)
---@type file*?
local focused = main
local windows = { __index = {
  screen = function()
    return side
  end,
} }
local window = debug.setmetatable(assert(io.open("/dev/null")), windows)
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
      getObjectMetatable = function(name)
        local kinds =
          { ["hs.styledtext"] = styled, ["hs.screen"] = screens, ["hs.window"] = windows }
        return kinds[name]
      end,
      screen = {
        -- Can stay on another display while a fullscreen app has focus.
        mainScreen = function()
          return main
        end,
        find = function(uuid)
          return ({ ["0"] = main, ["1000"] = side })[uuid]
        end,
      },
      spaces = {
        focusedSpace = function()
          return 7
        end,
        spaceDisplay = function(space)
          assert(space == 7, "not the focused Space")
          if not focused then
            return nil, "space not found in managed displays"
          end
          return tostring(at[focused])
        end,
      },
      styledtext = {
        new = function(text, style)
          local copy = {}
          for key, value in pairs(style) do
            copy[key] = value
          end
          return { text = text, style = copy }
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
        new = function(mask, fn)
          tap = { fn = fn, types = {} }
          for _, kind in ipairs(mask) do
            tap.types[kind] = not tap.types[kind] -- toggled, as libeventtap's mask bit is
          end
          function tap.start()
            tap.on = true
          end
          return tap
        end,
      },
      timer = {
        absoluteTime = function()
          return clock
        end,
        -- Its callback is held in the registry until the timer is collected, as in hs.timer.
        doAfter = function(seconds, fn)
          local timer, ref = { seconds = seconds, fn = fn, at = clock + seconds * 1e9 }, {}
          debug.getregistry()[ref] = fn
          setmetatable(timer, {
            __gc = function()
              debug.getregistry()[ref] = nil
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
          local canvas = { elements = {}, visible = false, deleted = false, calls = {} }
          function canvas.minimumTextSize(_, text)
            measured = measured + 1
            local w, lines = 0, 0
            for line in text.text:gmatch("[^\n]+") do
              w, lines = math.max(w, 7 * #line), lines + 1
            end
            return { w = w, h = 16 * lines }
          end
          function canvas.size(_, size)
            canvas.frame = size or canvas.frame
            return canvas.frame
          end
          function canvas.topLeft(_, point)
            canvas.at = point
          end
          function canvas.appendElements(_, ...)
            for _, element in ipairs({ ... }) do
              canvas.elements[#canvas.elements + 1] = element
            end
          end
          function canvas.behaviorAsLabels(_, labels)
            canvas.labels = table.concat(labels, " ")
          end
          -- Without one, its window ignores clicks.
          function canvas.mouseCallback(_, ...)
            local fn = ...
            assert(
              select("#", ...) == 1 and (fn == nil or type(fn) == "function"),
              "not a function or nil"
            )
            canvas.click = fn
          end
          function canvas.show()
            canvas.visible = true
          end
          canvas.out, canvas.ghost, canvas.opacity = false, false, 1
          function canvas.alpha(_, value)
            canvas.opacity = value or canvas.opacity
            return canvas.opacity
          end
          -- Ordered out now, or after its fade, at the alpha it began at; one mid-fade is ignored.
          canvas.ending = false
          function canvas.delete(_, fade)
            canvas.deleted = true
            if not fade then
              canvas.out = true
            elseif not canvas.ending then
              local restore, over = canvas.opacity, clock + fade * 1e9
              function canvas.ending()
                if clock >= over then
                  canvas.ending, canvas.out, canvas.opacity = false, true, restore
                end
              end
            end
          end
          for _, method in ipairs({ "level", "clickActivating", "canvasMouseEvents" }) do
            rawset(canvas, method, function(_, ...)
              canvas.calls[method] = { ... }
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
          native = function(module)
            assert(module == "toast" and not unbuilt, "toast: native build failed")
            return {
              glass = function(canvas)
                local glass = { canvas = canvas }
                function glass.hide(_, fade)
                  glass.fade = fade
                end
                glasses[#glasses + 1] = glass
                return glass
              end,
            }
          end,
        }
      end
      assert(name == "lib.logger")
      return {
        error = function(message)
          logged[#logged + 1] = message
        end,
      }
    end,
    -- Raises after logging, as hs.ipc's does while a dead `hs` CLI is registered.
    print = function(...)
      printed[#printed + 1] = table.concat({ ... }, "\t")
      error("dead hs CLI")
    end,
  }, { __index = _G })
))()
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
local function texts(canvas)
  local found = {}
  for _, element in ipairs(canvas.elements) do
    if element.type == "text" then
      found[#found + 1] = element.text.text
    end
  end
  return table.concat(found, " | ")
end
local function find(canvas, kind)
  for _, element in ipairs(canvas.elements) do
    if element.type == kind then
      return element
    end
  end
end
local function rim(canvas)
  local levels = {}
  for i, color in ipairs(find(canvas, "rectangle").fillGradientColors) do
    levels[i] = color.white
  end
  return table.concat(levels, " ")
end
local function bottom(canvas)
  return canvas.at.y + canvas.frame.h
end
-- A down via the tap (false: swallowed; nil: reached beneath; else the toast hit) and its release.
local function hold(point, state, button, first)
  button = button or 0
  local down = ({ [0] = 1, [1] = 3 })[button] or 25
  local function through(kind)
    return tap
      and tap.on
      and tap.types[kind]
      and tap.fn({
        getProperty = function(_, key)
          assert(key == 1 or key == 3, "not the click state or button")
          return key == 1 and state or button
        end,
        getType = function()
          return kind
        end,
      })
  end
  local swallowed, front = through(down), nil
  for _, canvas in ipairs(canvases) do
    local there = canvas.visible and not canvas.out
    local over = point.x >= canvas.at.x
      and point.x < canvas.at.x + canvas.frame.w
      and point.y >= canvas.at.y
      and point.y < bottom(canvas)
    if not swallowed and there and over and rawget(canvas, "click") then
      front = canvas
    end
  end
  -- As canvasMouseEvents asks, with the up sent where the down went.
  local function deliver(phase)
    if front and rawget(front, "click") and (front.calls.canvasMouseEvents or {})[phase] then
      front.click(front, phase == 1 and "mouseDown" or "mouseUp")
    end
  end
  -- Runs after the down reaches its window, before the toast hears of it.
  if first then
    first()
  end
  deliver(1)
  return not swallowed and front,
    function()
      assert(not through(down + 1) == not swallowed, "a click's down and up went different ways")
      if front then
        -- A window ordered out under a held click comes back (live, only a left single click).
        front.ghost = front.out
      end
      deliver(2)
    end
end
local function press(...)
  local hit, release = hold(...)
  release()
  return hit
end
-- Shown and not yet ordered out, or put back, and not transparent.
local function drawn(canvas)
  return (canvas.visible and not canvas.out or canvas.ghost) and canvas.opacity > 0
end
-- Lets the seconds pass, running each timer when due if still held; hs.timer collects the rest.
local function wait(seconds)
  local stop = clock + seconds * 1e9
  while true do
    local first
    for i, timer in ipairs(timers) do
      local due = timer and not timer.stopped and timer.at <= stop
      if due and (not first or timer.at < timers[first].at) then
        first = i
      end
    end
    clock = math.max(clock, first and timers[first].at or stop)
    -- An hs.canvas fade over by then ends first.
    for _, canvas in ipairs(canvases) do
      if canvas.ending then
        canvas.ending()
      end
    end
    if not first then
      return
    end
    local alive = setmetatable({}, { __mode = "v" })
    alive[1], timers[first] = timers[first], false
    collectgarbage()
    if alive[1] then
      alive[1].fn()
    end
  end
end
-- Seconds until its window is ordered out, to the nearest 0.05 s, letting frames pass.
local function fade(canvas)
  local frames = 0
  repeat
    wait(1 / 60)
    frames = frames + 1
  until not drawn(canvas) or frames == 600
  return math.floor(frames / 3 + 0.5) / 20
end
local function clear()
  for _, canvas in ipairs(canvases) do
    if rawget(canvas, "click") then
      canvas.click(canvas, "mouseUp")
    end
  end
  canvases, timers, glasses, focused = {}, {}, {}, main
end

test("a failure sits at the bottom right, titled by its source, with a red cross", function()
  toast.show("Tiling: no focused window", { failure = true, seconds = 5 })
  local canvas = canvases[1]
  assert(texts(canvas) == "Tiling | No focused window", texts(canvas))
  assert(find(canvas, "circle") and canvas.visible and timers[1].seconds == 5)
  assert(canvas.at.x + canvas.frame.w == 1000 - 16 and bottom(canvas) == 609, "not bottom right")
  assert(canvas.labels == "canJoinAllSpaces stationary fullScreenAuxiliary", canvas.labels)
  assert(canvas.calls.clickActivating[1] == false)
  assert(canvas.calls.level[1] == 19, "not just below the Dock")
  clear()
end)

test("a newer toast stacks below the older, which drops back when it goes", function()
  toast.show("first")
  toast.show("second")
  local first, second = canvases[1], canvases[2]
  assert(bottom(second) == 609 and bottom(first) == second.at.y - 8)
  assert(
    texts(first) == "first" and not find(first, "circle") and not find(first, "image"),
    "an info toast has an icon"
  )
  timers[2].fn()
  assert(second.deleted and not first.deleted and bottom(first) == 609)
  assert(fade(second) == 0, "it faded while the toast above moved into its place")
  timers[1].fn()
  assert(fade(first) == 0.25, "the oldest did not fade")
  clear()
end)

test("a toast stays on its screen when focus and the stack change", function()
  toast.show("on main")
  focused = side
  toast.show("on side")
  assert(canvases[1].at.x < 1000 and canvases[2].at.x >= 1000, "a toast moved screens")
  assert(bottom(canvases[1]) == 609 and bottom(canvases[2]) == 609, "screens share one stack")
  timers[2].fn()
  assert(fade(canvases[2]) == 0.25, "the side screen's oldest did not fade")
  clear()
end)

test("a closed toast lets clicks through while it fades", function()
  toast.close(toast.show("fading"), 5)
  local canvas = canvases[1]
  wait(2.5)
  assert(canvas.opacity > 0 and canvas.opacity < 1, "it did not fade")
  assert(press({ x = canvas.at.x + 5, y = canvas.at.y + 5 }, 1) == nil, "the fading toast took it")
  assert(fade(canvas) == 2.5)
  clear()
end)

test("a multi-click closes only its toast, and the rest of it reaches nothing", function()
  -- The bottom toast is triple-clicked, or clicked second and third after a click away.
  for _, case in ipairs({
    { "lone" },
    { "older", "newer" },
    { "older", "newer", second = true },
    { "lone", late = "late" }, -- shown between the clicks
    { "older", "newer", button = 1, held = 0 }, -- right, with left held
    { "older", "newer", button = 3, held = 2 }, -- button 4, with the middle held
  }) do
    for _, text in ipairs(case) do
      toast.show(text)
    end
    local target
    for _, canvas in ipairs(canvases) do
      if bottom(canvas) == 609 then
        target = canvas
      end
    end
    local point, away, state = { x = target.at.x + 5, y = target.at.y + 5 }, { x = 5, y = 30 }, 1
    -- Another button's double-click is held through the toast's, and let go during it.
    press(away, 1, case.held or 1)
    local _, other = hold(away, 2, case.held or 1)
    if case.second then
      assert(press(away, 1) == nil, "the click away was swallowed")
      state = 2
    end
    assert(
      press(point, state, case.button) == target and not rawget(target, "click"),
      "the click missed it"
    )
    assert(not target.ghost, "its window came back when the click was let go")
    if case.late then
      toast.show(case.late)
    end
    local second, release = hold(point, state + 1, case.button)
    other()
    release()
    local rest = { second, press(point, state + 2, case.button) }
    assert(rest[1] == false and rest[2] == false, "the rest of the click got through")
    assert(
      press(away, 1, case.button) == nil and press(away, 2, case.button) == nil,
      "a later double-click was swallowed"
    )
    clear()
  end
end)

test("a toast pressed as it times out or all close waits for its release", function()
  toast.install()
  toast.show("older")
  toast.show("pressed")
  local older, pressed = canvases[1], canvases[2]
  local hit, release = hold({ x = pressed.at.x + 5, y = pressed.at.y + 5 }, 1)
  assert(hit == pressed)
  timers[2].fn()
  alert.closeAll()
  assert(fade(older) == 0.25, "the oldest did not fade")
  assert(rawget(pressed, "click"), "a pressed toast closed")
  release()
  assert(fade(pressed) == 0.25, "it did not fade once let go")
  assert(not pressed.ghost, "its window came back when the click was let go")
  clear()
end)

test("a toast closed under a press it has not heard of ends at alpha 0, after any fade", function()
  toast.install()
  local function fire(i)
    return function()
      timers[i].fn()
    end
  end
  local function all()
    alert.closeAll(0)
  end
  local id
  local function slow()
    alert.closeSpecific(id, 2)
  end
  local function cap()
    toast.show("sixth", { seconds = false })
  end
  local closed = setmetatable({}, { __mode = "k" })
  for _, case in ipairs({
    { { "older", "target" }, 0, fire(2) }, -- times out, not its screen's oldest
    { { "target" }, 0.25, fire(1) },
    { { "older", "target" }, 0, all },
    { { "target" }, 2, slow },
    { { "target", "b", "c", "d", "e" }, 0, cap },
  }) do
    local target
    for i, text in ipairs(case[1]) do
      if text == "target" then
        id, target = toast.show(text), canvases[i]
      else
        toast.show(text)
      end
    end
    local _, release = hold({ x = target.at.x + 5, y = target.at.y + 5 }, 1, nil, case[3])
    assert(case[2] == 0 or target.opacity == 1, "its fade was not seen")
    -- Let go once its window is ordered out, before any timer set for after its fade.
    assert(fade(target) == case[2], "it stayed or did not fade as asked")
    release()
    assert(target.ghost and not drawn(target), "its window came back drawn")
    closed[target] = true
    clear()
  end
  for _ = 1, 3 do
    collectgarbage()
  end
  assert(next(closed) == nil, "a closed toast is never collected")
end)

test("a toast without a focused display is printed instead, never raising", function()
  focused = nil
  local ok, id = pcall(toast.show, "Tiling: lost")
  assert(ok, "a toast without a focused display raised: " .. tostring(id))
  assert(id == nil and #canvases == 0, "a toast without a focused display was shown")
  assert(printed[1] and printed[1]:find("Tiling: lost", 1, true), tostring(printed[1]))
  clear()
end)

test("the same toast again restarts its time on its screen instead of stacking", function()
  local id = toast.show("Window list unavailable", { seconds = 2 })
  assert(toast.show("Window list unavailable", { seconds = 2 }) == id, "a repeat lost its id")
  assert(#canvases == 1 and timers[1].stopped and timers[2].seconds == 2)
  focused = side
  toast.show("Window list unavailable", { seconds = 2 })
  assert(#canvases == 2 and canvases[2].at.x >= 1000, "the repeat stayed on the other screen")
  clear()
  toast.show("old")
  toast.show("new")
  toast.show("old")
  assert(#canvases == 2 and bottom(canvases[1]) == 609, "the repeat is not the newest")
  for i = 1, 4 do
    toast.show("more " .. i)
  end
  assert(not canvases[1].deleted and canvases[2].deleted, "the cap dropped the repeat")
  clear()
end)

test("a click dismisses, and a sixth toast drops the oldest", function()
  for i = 1, 6 do
    toast.show("toast " .. i)
  end
  assert(canvases[1].deleted and timers[1].stopped and not canvases[2].deleted)
  assert(fade(canvases[1]) == 0, "the dropped toast faded under the one moving into its place")
  press({ x = canvases[4].at.x + 5, y = canvases[4].at.y + 5 }, 1)
  assert(canvases[4].deleted and bottom(canvases[3]) == canvases[5].at.y - 8)
  clear()
end)

test("long text wraps to three lines, measured once a word until then", function()
  measured = 0
  toast.show(("word "):rep(600), { failure = true })
  local lines = select(2, texts(canvases[1]):gsub("\n", "")) + 1
  assert(lines == 3 and canvases[1].frame.w <= 14 + 26 + 340 + 14, lines)
  assert(measured < 40, measured .. " measurements: the last line is measured again a word")
  clear()
  toast.show("Tiling: " .. ("word "):rep(600))
  assert(select(2, texts(canvases[1]):gsub("\n", "")) == 2, texts(canvases[1]):sub(1, 80))
  clear()
end)

test("a line break is kept, a blank one too, and a name keeps its case", function()
  toast.install()
  alert.show("⌘A: Alpha\n⌘B: Beta\n⌘C: Gamma\n⌘D: Delta")
  assert(
    texts(canvases[1]) == "⌘A: Alpha\n⌘B: Beta\n⌘C: Gamma ⌘D: Delta",
    texts(canvases[1])
  )
  alert.show("Title\n\nDetail\n")
  assert(texts(canvases[2]) == "Title\n\nDetail", texts(canvases[2]))
  toast.show("Space focus: macOS refused it")
  assert(texts(canvases[3]) == "Space focus | macOS refused it", texts(canvases[3]))
  toast.show("Could not write Hammerspoon file log: denied")
  assert(texts(canvases[4]) == "Could not write Hammerspoon file log: denied", texts(canvases[4]))
  toast.show("Синхронизация: готово") -- 13 characters, 26 bytes
  assert(texts(canvases[5]) == "Синхронизация | готово", texts(canvases[5]))
  assert(pcall(toast.show, "caf\xe9: done"), "a title that isn't UTF-8 raised")
  assert(texts(canvases[6]) == "caf\xe9 | Done", texts(canvases[6]))
  clear()
end)

test("install picks the theme, and an unknown one is logged and fails the load", function()
  toast.install({ theme = "edge" })
  toast.show("edged")
  local edge = rim(canvases[1])
  clear()
  for _, name in ipairs({ "metal", "edge", "flat" }) do
    toast.install({ theme = name })
  end
  local ok, problem = pcall(toast.install, { theme = "chrome" })
  assert(not ok and tostring(problem):find("no theme chrome", 1, true), tostring(problem))
  assert(logged[1] and logged[1]:find("no theme chrome", 1, true), tostring(logged[1]))
  toast.install()
  toast.show("metal")
  assert(rim(canvases[1]) ~= edge, "the edge theme did not change the rim")
  clear()
end)

test("glass that can't be built fails the load, as an unknown theme does", function()
  unbuilt = true
  local ok, problem = pcall(toast.install, { theme = "glass" })
  assert(not ok and tostring(problem):find("native build failed", 1, true), tostring(problem))
  unbuilt = false
  toast.show("still metal")
  assert(find(canvases[1], "rectangle") and #glasses == 0, "a failed build changed the theme")
  clear()
end)

test("glass: each toast has its own, hidden with the toast's fade, under shadowed text", function()
  toast.install({ theme = "glass" })
  toast.show("first")
  toast.show("Second: detail", { failure = true })
  local first, second = canvases[1], canvases[2]
  assert(not find(first, "rectangle") and not find(second, "rectangle"), "a rim over the glass")
  for _, element in ipairs(second.elements) do
    assert(element.type ~= "text" or element.text.style.shadow, "glass text has no shadow")
  end
  assert(#glasses == 2 and glasses[1].canvas == first and glasses[2].canvas == second)
  press({ x = second.at.x + 5, y = second.at.y + 5 }, 1)
  alert.closeAll()
  assert(glasses[2].fade == fade(second) and glasses[1].fade == fade(first), "a glass stayed")
  toast.install()
  toast.show("metal")
  assert(not find(canvases[3], "text").text.style.shadow, "the glass shadow stayed")
  clear()
end)

test("every hs.alert is a toast, with its seconds and screen", function()
  toast.install()
  alert.show("Could not switch to that window", 4)
  alert.show("Focused display unavailable", {}, side, 7)
  alert.show(setmetatable({}, {
    __tostring = function()
      return "hs.window: Notes"
    end,
  }))
  assert(texts(canvases[1]) == "Could not switch to that window" and timers[1].seconds == 4)
  assert(canvases[2].at.x >= 1000 and timers[2].seconds == 7, "the screen or seconds were lost")
  assert(texts(canvases[3]) == "hs.window | Notes" and timers[3].seconds == 2, texts(canvases[3]))
  local message = setmetatable({}, styled)
  function message.getString()
    return "styled"
  end
  alert.show(message)
  assert(texts(canvases[4]) == "styled", texts(canvases[4]))
  alert.show(io.stdout) -- not styled text
  assert(texts(canvases[5]):find("^file %("), texts(canvases[5]))
  alert.show("on the window's screen", window, 2)
  alert.show("false is the default", false)
  assert(canvases[6].at.x >= 1000 and timers[6].seconds == 2, "a window is not its screen")
  assert(timers[7] and timers[7].seconds == 2, "false is not hs.alert's 2 s default")
  clear()
end)

test("an hs.alert with non-number seconds stays until closed by its id", function()
  toast.install()
  local id = alert.show("Working…", "indefinite")
  alert.show("other", 1)
  assert(#timers == 1, "the indefinite one got a timer")
  alert.closeSpecific(id)
  assert(fade(canvases[1]) == 0.25 and not canvases[2].deleted)
  alert.show("another", 1)
  alert.closeAll()
  assert(drawn(canvases[3]) and fade(canvases[2]) == 0.25 and canvases[3].deleted)
  alert.closeSpecific(alert.show("now", "indefinite"), 0)
  alert.show("all now", 5)
  alert.closeAll(0)
  assert(fade(canvases[4]) == 0 and fade(canvases[5]) == 0, "a close ignored its fade time")
  alert.show("above", "indefinite")
  local stuck = alert.show("stuck?", "indefinite")
  assert(not pcall(alert.closeSpecific, stuck, true), "a fade of true was taken")
  assert(not pcall(alert.closeSpecific, 999, true), "a fade of true was taken for an unknown id")
  alert.closeAll()
  assert(fade(canvases[7]) == 0.25, "a failed close left a toast nothing can close")
  clear()
end)

test("each hs.alert kept until closed has its own id, and an old id closes nothing", function()
  toast.install()
  local first = alert.show("Working…", "indefinite")
  local second = alert.show("Working…", "indefinite")
  assert(first ~= second and #canvases == 2, "two callers share one alert")
  alert.closeSpecific(first)
  assert(fade(canvases[1]) == 0.25, "the closed one did not fade")
  assert(not canvases[2].deleted, "closing one closed the other")
  alert.show("Working…", 2)
  assert(#canvases == 3 and timers[#timers].seconds == 2, "a timed repeat merged into a kept alert")
  alert.show("Working…", "indefinite")
  assert(#canvases == 4, "a kept alert merged into a timed one")
  clear()
  local timed = alert.show("Done", 2)
  alert.closeSpecific(timed)
  local again = alert.show("Done", 2)
  alert.closeSpecific(timed)
  assert(again ~= timed and not canvases[2].deleted, "an old id closed a later alert")
  clear()
end)

test("the cap drops a screen's oldest unpressed timed toast, never a kept one", function()
  toast.install()
  local kept = alert.show("Working…", "indefinite")
  for i = 1, 5 do
    toast.show("toast " .. i)
  end
  assert(not canvases[1].deleted and canvases[2].deleted, "the cap dropped the kept alert")
  focused = side
  for i = 1, 5 do
    toast.show("side " .. i)
  end
  assert(not canvases[3].deleted, "another screen's toasts counted toward this screen's cap")
  alert.closeSpecific(kept)
  clear()
  for i = 1, 5 do
    toast.show("toast " .. i)
  end
  local _, release = hold({ x = canvases[1].at.x + 5, y = canvases[1].at.y + 5 }, 1)
  toast.show("sixth")
  assert(not canvases[1].deleted, "the cap dropped the pressed toast")
  assert(canvases[2].deleted, "the cap dropped no unpressed toast")
  release()
  clear()
  for _ = 1, 6 do
    alert.show("Working…", "indefinite")
  end
  toast.show("timed")
  assert(not canvases[7].deleted, "the cap dropped the toast it was making room for")
  clear()
end)

test("a failure and a plain toast with the same text are not repeats", function()
  toast.show("Window list unavailable")
  toast.show("Window list unavailable", { failure = true })
  assert(#canvases == 2 and find(canvases[2], "circle"), "the failure merged")
  clear()
end)

test("hs.alert.showWithImage shows its image as the icon, never repeated as plain", function()
  toast.install()
  local image = {}
  alert.showWithImage("Synced", image, 2)
  local icon = find(canvases[1], "image")
  assert(icon and icon.image == image, "no image")
  assert(
    find(canvases[1], "text").frame.x >= icon.frame.x + icon.frame.w,
    "the text is not past the icon"
  )
  alert.show("Synced", 2)
  assert(#canvases == 2 and not find(canvases[2], "image"), "the plain one kept the icon")
  alert.showWithImage("Synced", image, 2)
  assert(#canvases == 3, "the image merged into the plain one")
  clear()
end)

test("an argument hs.alert would not take is an error, as in hs.alert", function()
  toast.install()
  local ok, problem = pcall(alert.show, "x", {}, side, 2, 3)
  assert(not ok and tostring(problem):find("unexpected number", 1, true), tostring(problem))
  ok, problem = pcall(alert.show, "x", io.stdout)
  assert(not ok and tostring(problem):find("argument 2", 1, true), tostring(problem))
  assert(#canvases == 0, "a toast was shown")
  alert.show("kept", side, io.stdout)
  assert(#canvases == 1 and #timers == 0, "a userdata after the screen was no seconds")
  clear()
end)

print("RESULT " .. passed .. " passed, 0 failed")

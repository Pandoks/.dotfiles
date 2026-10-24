local root = assert(arg[1])
-- Two 1000x600 screens side by side below a 25 pt menu bar; text is 7 pt a character, 16 a line.
local canvases, timers, logged, measured = {}, {}, {}, 0
local screens, styled = {}, {}
local function display(id, x)
  return setmetatable({
    id = function()
      return id
    end,
    frame = function()
      return { x = x, y = 25, w = 1000, h = 600 }
    end,
  }, screens)
end
local main, side = display(1, 0), display(2, 1000)
local focused = main
local windows = {}
local window = setmetatable({
  screen = function()
    return side
  end,
}, windows)
-- As hs.alert's: `show` and `hs.alert(...)` call `showWithImage`.
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
        mainScreen = function()
          return focused
        end,
      },
      styledtext = {
        new = function(text)
          return { text = text }
        end,
      },
      timer = {
        doAfter = function(seconds, fn)
          local timer = { seconds = seconds, fn = fn }
          function timer.stop()
            timer.stopped = true
          end
          timers[#timers + 1] = timer
          return timer
        end,
      },
      canvas = {
        windowLevels = { status = 25 },
        new = function()
          local canvas = { elements = {}, visible = false, deleted = false }
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
          function canvas.appendElements(_, element)
            canvas.elements[#canvas.elements + 1] = element
          end
          function canvas.behaviorAsLabels(_, labels)
            canvas.labels = table.concat(labels, " ")
          end
          function canvas.mouseCallback(_, fn)
            canvas.click = fn
          end
          function canvas.show()
            canvas.visible = true
          end
          function canvas.delete(_, fade)
            canvas.deleted, canvas.fade = true, fade
          end
          setmetatable(canvas, {
            __index = function()
              return function() end
            end,
          })
          canvases[#canvases + 1] = canvas
          return canvas
        end,
      },
    },
    require = function(name)
      assert(name == "lib.logger")
      return {
        error = function(message)
          logged[#logged + 1] = message
        end,
      }
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
local function bottom(canvas)
  return canvas.at.y + canvas.frame.h
end
local function clear()
  for _, canvas in ipairs(canvases) do
    if not canvas.deleted then
      canvas.click()
    end
  end
  canvases, timers, focused = {}, {}, main
end

test("a failure sits at the bottom right, titled by its source, with a red cross", function()
  toast.show("Tiling: no focused window", { failure = true, seconds = 5 })
  local canvas = canvases[1]
  assert(texts(canvas) == "Tiling | No focused window", texts(canvas))
  assert(canvas.elements[3].type == "circle" and canvas.visible and timers[1].seconds == 5)
  assert(canvas.at.x + canvas.frame.w == 1000 - 16 and bottom(canvas) == 609, "not bottom right")
  assert(canvas.labels:find("fullScreenAuxiliary", 1, true), "hidden over full-screen apps")
  clear()
end)

test("a newer toast stacks below the older, which drops back when it goes", function()
  toast.show("first")
  toast.show("second")
  local first, second = canvases[1], canvases[2]
  assert(bottom(second) == 609 and bottom(first) == second.at.y - 8)
  assert(texts(first) == "first" and #first.elements == 3, "an info toast has no icon")
  timers[2].fn()
  assert(second.deleted and not first.deleted and bottom(first) == 609)
  assert(second.fade == 0, "it faded while the toast above moved into its place")
  timers[1].fn()
  assert(first.fade == 0.25, "the oldest did not fade")
  clear()
end)

test("a toast stays on its screen when focus and the stack change", function()
  toast.show("on main")
  focused = side
  toast.show("on side")
  assert(canvases[1].at.x < 1000 and canvases[2].at.x >= 1000, "a toast moved screens")
  assert(bottom(canvases[1]) == 609 and bottom(canvases[2]) == 609, "screens share one stack")
  clear()
end)

test("the same toast again restarts its time on its screen instead of stacking", function()
  toast.show("Window list unavailable", { seconds = 2 })
  toast.show("Window list unavailable", { seconds = 2 })
  assert(#canvases == 1 and timers[1].stopped and timers[2].seconds == 2)
  focused = side
  toast.show("Window list unavailable", { seconds = 2 })
  assert(#canvases == 2 and canvases[2].at.x >= 1000, "the repeat stayed on the other screen")
  clear()
end)

test("a click dismisses, and a sixth toast drops the oldest", function()
  for i = 1, 6 do
    toast.show("toast " .. i)
  end
  assert(canvases[1].deleted and timers[1].stopped and not canvases[2].deleted)
  canvases[4].click()
  assert(canvases[4].deleted and bottom(canvases[5]) == canvases[6].at.y - 8)
  clear()
end)

test("long text wraps to three lines, measured once a word until then", function()
  measured = 0
  toast.show(("word "):rep(600), { failure = true })
  local lines = select(2, texts(canvases[1]):gsub("\n", "")) + 1
  assert(lines == 3 and canvases[1].frame.w <= 14 + 26 + 340 + 14, lines)
  assert(measured < 40, measured .. " measurements: the last line is measured again a word")
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
  clear()
end)

test("install picks the theme, and an unknown one is logged and fails the load", function()
  toast.install({ theme = "edge" })
  toast.show("edged")
  assert(canvases[1].elements[1].fillGradientColors[4].white == 0.3, "not the edge rim")
  clear()
  local ok = pcall(toast.install, { theme = "chrome" })
  assert(not ok, "an unknown theme loaded")
  assert(logged[1] and logged[1]:find("no theme chrome", 1, true), tostring(logged[1]))
  toast.install()
  toast.show("metal")
  assert(canvases[1].elements[1].fillGradientColors[3].white == 0.42, "not the metal rim")
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
  alert.show(io.stdout) -- a userdata that is not styled text
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
  assert(canvases[1].deleted and not canvases[2].deleted)
  alert.closeAll()
  assert(canvases[2].deleted and canvases[2].fade == 0.25)
  alert.closeSpecific(alert.show("now", "indefinite"), 0)
  alert.show("all now", 5)
  alert.closeAll(0)
  assert(canvases[3].fade == 0 and canvases[4].fade == 0, "a close ignored its fade time")
  clear()
end)

test("each hs.alert kept until closed has its own id, and an old id closes nothing", function()
  toast.install()
  local first = alert.show("Working…", "indefinite")
  local second = alert.show("Working…", "indefinite")
  assert(first ~= second and #canvases == 2, "two callers share one alert")
  alert.closeSpecific(first)
  assert(canvases[1].deleted and not canvases[2].deleted, "closing one closed the other")
  alert.closeSpecific(second)
  local timed = alert.show("Done", 2)
  alert.closeSpecific(timed)
  local again = alert.show("Done", 2)
  alert.closeSpecific(timed)
  assert(again ~= timed and not canvases[4].deleted, "an old id closed a later alert")
  clear()
end)

test("the cap drops a screen's oldest timed toast, never one kept until closed", function()
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
  assert(#canvases == 2 and canvases[2].elements[3].type == "circle", "the failure merged")
  clear()
end)

test("hs.alert.showWithImage shows its image as the icon, never repeated as plain", function()
  toast.install()
  local image = {}
  alert.showWithImage("Synced", image, 2)
  local icon = canvases[1].elements[3]
  assert(icon.type == "image" and icon.image == image and icon.frame.w == 16, "no image")
  assert(canvases[1].elements[4].frame.x == 14 + 16 + 10, "the text is not past the icon")
  alert.show("Synced", 2)
  assert(#canvases == 2 and canvases[2].elements[3].type == "text", "the plain one kept the icon")
  clear()
end)

test("an argument hs.alert would not take is an error, as in hs.alert", function()
  toast.install()
  local ok, problem = pcall(alert.show, "x", {}, side, 2, 3)
  assert(not ok and tostring(problem):find("unexpected number", 1, true), tostring(problem))
  clear()
end)

print("RESULT " .. passed .. " passed, 0 failed")

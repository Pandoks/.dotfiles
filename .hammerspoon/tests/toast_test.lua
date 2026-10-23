local root = assert(arg[1])
-- A 1000x600 screen below a 25 pt menu bar; text is 7 pt a character, 16 pt a line.
local canvases, timers = {}, {}
local alert = {}
local toast = assert(loadfile(
  root .. "/toast.lua",
  "t",
  setmetatable({
    hs = {
      alert = alert,
      screen = {
        mainScreen = function()
          return {
            frame = function()
              return { x = 0, y = 25, w = 1000, h = 600 }
            end,
          }
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
          function timer.setNextTrigger(_, next)
            timer.seconds = next
          end
          timers[#timers + 1] = timer
          return timer
        end,
      },
      canvas = {
        windowLevels = { status = 25 },
        new = function()
          local canvas = { elements = {}, visible = false, deleted = false }
          function canvas.minimumTextSize(_, styled)
            local w, lines = 0, 0
            for line in styled.text:gmatch("[^\n]+") do
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
          function canvas.mouseCallback(_, fn)
            canvas.click = fn
          end
          function canvas.show()
            canvas.visible = true
          end
          function canvas.delete()
            canvas.deleted = true
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
local function clear()
  for _, canvas in ipairs(canvases) do
    if not canvas.deleted and canvas.click then
      canvas.click()
    end
  end
  canvases, timers = {}, {}
end

test("a failure sits at the bottom right, titled by its source, with a red cross", function()
  toast.show("Tiling: no focused window", "failure", 5)
  local canvas = canvases[1]
  assert(texts(canvas) == "Tiling | No focused window", texts(canvas))
  assert(canvas.elements[3].type == "circle" and canvas.visible and timers[1].seconds == 5)
  assert(canvas.at.x + canvas.frame.w == 1000 - 16, "not at the right edge")
  assert(canvas.elements[1].fillGradient == "linear" and canvas.elements[2].frame.x == 1, "no rim")
  assert(canvas.at.y + canvas.frame.h == 25 + 600 - 16, "not at the bottom")
  clear()
end)

test("a newer toast stacks below the older, which drops back when it goes", function()
  toast.show("first")
  toast.show("second")
  local first, second = canvases[1], canvases[2]
  assert(second.at.y + second.frame.h == 609 and first.at.y + first.frame.h == second.at.y - 8)
  assert(texts(first) == "first" and #first.elements == 3, "an info toast has no icon")
  timers[2].fn()
  assert(second.deleted and not first.deleted and first.at.y + first.frame.h == 609)
  clear()
end)

test("the same toast again restarts its time instead of stacking", function()
  toast.show("Window list unavailable", nil, 2)
  timers[1].seconds = 0
  toast.show("Window list unavailable", nil, 2)
  assert(#canvases == 1 and timers[1].seconds == 2)
  clear()
end)

test("a click dismisses, and a sixth toast drops the oldest", function()
  for i = 1, 6 do
    toast.show("toast " .. i)
  end
  assert(canvases[1].deleted and timers[1].stopped and not canvases[2].deleted)
  canvases[4].click()
  assert(canvases[4].deleted and canvases[5].at.y + canvases[5].frame.h == canvases[6].at.y - 8)
  clear()
end)

test("long text wraps to three lines, and a name keeps its case", function()
  toast.show(("word "):rep(60), "failure")
  local lines = select(2, texts(canvases[1]):gsub("\n", "")) + 1
  assert(lines == 3 and canvases[1].frame.w <= 14 + 26 + 340 + 14, lines)
  toast.show("Space focus: macOS refused it")
  assert(texts(canvases[2]) == "Space focus | macOS refused it", texts(canvases[2]))
  clear()
end)

test("install makes every hs.alert.show a toast, with its seconds", function()
  toast.install()
  alert.show("Could not switch to that window", 4)
  alert.show("Focused display unavailable", {}, nil, 7)
  assert(texts(canvases[1]) == "Could not switch to that window" and timers[1].seconds == 4)
  assert(texts(canvases[2]) == "Focused display unavailable" and timers[2].seconds == 7)
  clear()
end)

print("RESULT " .. passed .. " passed, 0 failed")

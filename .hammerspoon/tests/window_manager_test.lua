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
local function harness()
  local desktop = { current = 100, steps = 0, inflight = {}, results = {}, timers = {} }
  local spaces = {}
  for i = 1, 4 do
    spaces[i] = { ManagedSpaceID = i * 100, display = "d" }
  end
  local spaceChanged
  local environment = setmetatable({
    hs = {
      spaces = {
        spaceDisplay = function(space)
          return not desktop.displayGone and space and "d" or nil
        end,
        watcher = {
          new = function(callback)
            spaceChanged = callback
            return {
              start = function(self)
                return self
              end,
            }
          end,
        },
        activeSpaces = function()
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
          return spaces
        end,
        native = function()
          return {
            move = function(right, count)
              desktop.steps = desktop.steps + count
              desktop.inflight[#desktop.inflight + 1] = (right and 100 or -100) * count
              return true
            end,
            spaces = function(ids)
              return { [ids[1]] = desktop.windowSpace }
            end,
            focus = function(_, id, done)
              desktop.focused = id
              done(true)
            end,
            windows = function()
              desktop.listed = (desktop.listed or 0) + 1
            end,
          }
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

test("loading starts one window search, so the first Cmd-Tab is cached", function()
  assertEqual(harness().listed, 1)
end)

print("RESULT " .. passed .. " passed, 0 failed")

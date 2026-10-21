local root = assert(arg[1])
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
local function eq(actual, expected, label)
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

-- Four Spaces on one display; the Dock lands each batch of swipes and reports once.
local function harness()
  local h = { current = 100, steps = 0, inflight = {}, results = {} }
  local spaces = {}
  for i = 1, 4 do
    spaces[i] = { ManagedSpaceID = i * 100, display = "d" }
  end
  local watcher
  local env = setmetatable({
    hs = {
      spaces = {
        spaceDisplay = function(space)
          return not h.displayGone and space and "d" or nil
        end,
        watcher = {
          new = function(fn)
            watcher = fn
            return {
              start = function(self)
                return self
              end,
            }
          end,
        },
        activeSpaces = function()
          if h.unavailable then
            return nil, "Spaces unavailable"
          end
          return { d = h.current }
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
        doAfter = function()
          return { stop = function() end }
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
              h.steps = h.steps + count
              h.inflight[#h.inflight + 1] = (right and 100 or -100) * count
              return true
            end,
            spaces = function(ids)
              return { [ids[1]] = h.windowSpace }
            end,
            focus = function(_, id, done)
              h.focused = id
              done(true)
            end,
          }
        end,
      }
    end,
  }, { __index = _G })
  h.windowManager = assert(loadfile(root .. "/window_manager.lua", "t", env))()
  function h:space(index)
    self.windowManager.space(index, function(ok, err)
      self.results[index] = ok and "ok" or err
    end)
  end
  function h:settle()
    while #self.inflight > 0 do
      self.current = self.current + table.remove(self.inflight, 1)
      h.notifications = (h.notifications or 0) + 1
      watcher()
    end
  end
  return h
end

test("a jump sends every swipe at once and reports when it arrives", function()
  local h = harness()
  h:space(4)
  eq(#h.inflight, 1, "one batch")
  h:settle()
  eq(h.current, 400)
  eq(h.steps, 3)
  eq(h.notifications, 1, "no Space between is shown")
  eq(h.results[4], "ok")
end)

test("presses during a jump wait for its swipes to land, then continue from there", function()
  for _, case in ipairs({ { second = 1, steps = 2 }, { second = 3, steps = 2 } }) do
    local h = harness()
    h:space(2)
    h:space(case.second)
    eq(#h.inflight, 1, "no swipes posted while others are in flight")
    h:settle()
    eq(h.current, case.second * 100, "lands on the latest press")
    eq(h.steps, case.steps)
    eq(h.results[2], "superseded")
    eq(h.results[case.second], "ok")
  end
end)

test("an unreadable Space layout fails at once instead of waiting for the timeout", function()
  local h = harness()
  h.unavailable = true
  h:space(3)
  eq(h.results[3], "Spaces unavailable")
  eq(h.steps, 0)
end)

test(
  "focusing a window whose display can't be found fails instead of skipping its Space",
  function()
    local h = harness()
    h.windowSpace, h.displayGone = 300, true
    local result
    h.windowManager.focus(10, 7, function(ok, err)
      result = ok and "ok" or err
    end)
    eq(result, "display unavailable for Space 300")
    eq(h.focused, nil, "not focused without showing its Space")
    eq(h.steps, 0)
  end
)

print("RESULT " .. passed .. " passed, 0 failed")

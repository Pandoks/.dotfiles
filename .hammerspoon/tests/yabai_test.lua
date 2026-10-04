local root = assert(arg[1], "pass a lib directory")
local passed = 0

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

local function setup()
  local model = { focused = 101, now = 0, requests = {}, timers = {} }
  local function timer(delay, callback, repeating)
    local handle = { delay = delay, callback = callback, active = true, repeating = repeating }
    function handle:stop()
      self.active = false
    end
    function handle:setNextTrigger(nextDelay)
      self.delay = nextDelay
    end
    model.timers[#model.timers + 1] = handle
    return handle
  end
  local native = {
    run = function(path, args, timeout, callback)
      model.requests[#model.requests + 1] = {
        path = path,
        args = args,
        timeout = timeout,
        callback = callback,
      }
    end,
  }
  local environment = setmetatable({
    hs = {
      processInfo = { arch = "arm64", version = "test", build = "1", bundleID = "test" },
      hash = {
        SHA256 = function()
          return "test-source"
        end,
      },
      fs = {
        attributes = function()
          return true
        end,
      },
      timer = {
        secondsSinceEpoch = function()
          return model.now
        end,
        doAfter = function(delay, callback)
          return timer(delay, callback, false)
        end,
        doEvery = function(delay, callback)
          return timer(delay, callback, true)
        end,
      },
      spaces = {
        focusedSpace = function()
          return model.focused
        end,
        watcher = {
          new = function(callback)
            model.notify = callback
            return {
              start = function(self)
                return self
              end,
            }
          end,
        },
      },
    },
    package = {
      loadlib = function(_, symbol)
        assert(symbol == "luaopen_yabai")
        return function()
          return native
        end
      end,
    },
    require = function(name)
      assert(name == "lib.utils")
      return {
        spaces = function()
          return { { ManagedSpaceID = 101 }, { ManagedSpaceID = 202 } }
        end,
      }
    end,
    print = function() end,
  }, { __index = _G })
  model.client = assert(loadfile(root .. "/yabai.lua", "t", environment))()
  function model:assertStopped()
    for _, handle in ipairs(self.timers) do
      assert(not handle.active, "request left a running timer")
    end
  end
  return model
end

test("run copies arguments, strips -m, and converts the timeout", function()
  local model = setup()
  local args = { "-m", "query", "--windows" }
  model.client.run(args, function() end, 1.25)
  local request = model.requests[1]
  assert(request.args[1] == "query" and request.timeout == 1250)
  assert(request.args ~= args and args[1] == "-m")
end)

test("focused and unknown Spaces finish without a request", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(1, function(ok)
    assert(ok)
    calls = calls + 1
  end)
  model.client.switchSpace(3, function(ok, error)
    assert(not ok and error == "space 3 does not exist")
    calls = calls + 1
  end)
  assert(calls == 2 and #model.requests == 0 and #model.timers == 0)
end)

test("command success settles focus without a notification", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(2, function(ok)
    assert(ok)
    calls = calls + 1
  end)
  model.focused = 202
  model.requests[1].callback(true, "", "")
  assert(calls == 1)
  model:assertStopped()
end)

test("delayed focus settles even when its notification arrived early", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(2, function(ok)
    assert(ok)
    calls = calls + 1
  end)
  model.notify(-1)
  model.requests[1].callback(true, "", "")
  assert(calls == 0)
  model.focused = 202
  model.timers[2].callback()
  assert(calls == 1)
  model:assertStopped()
end)

test("notification can settle before the command reply", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(2, function(ok)
    assert(ok)
    calls = calls + 1
  end)
  model.focused = 202
  model.notify(-1)
  model.requests[1].callback(false, "", "late error")
  assert(calls == 1)
  model:assertStopped()
end)

test("deadline checks the current focus before reporting timeout", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(2, function(ok)
    assert(ok)
    calls = calls + 1
  end)
  model.focused = 202
  model.timers[1].callback()
  assert(calls == 1)
  model:assertStopped()
end)

test("concurrent waiters share a request and the earliest deadline", function()
  local model = setup()
  local calls = 0
  local function done(ok)
    assert(ok)
    calls = calls + 1
  end
  model.client.switchSpace(2, done, 10)
  model.now = 1
  model.client.switchSpace(2, done, 2)
  assert(#model.requests == 1 and #model.timers == 2 and model.timers[1].delay == 2)
  model.focused = 202
  model.timers[2].callback()
  model.notify(-1)
  assert(calls == 2)
  model:assertStopped()
end)

test("a throwing waiter does not prevent other callbacks", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(2, function()
    error("test callback error")
  end)
  model.client.switchSpace(2, function(ok)
    assert(ok)
    calls = calls + 1
  end)
  model.focused = 202
  model.notify(-1)
  assert(calls == 1)
  model:assertStopped()
end)

test("timeout stops polling and ignores late completion", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(2, function(ok, error)
    assert(not ok and error == "timed out waiting for Space 2")
    calls = calls + 1
  end)
  model.timers[1].callback()
  model.focused = 202
  model.notify(-1)
  model.requests[1].callback(true, "", "")
  assert(calls == 1)
  model:assertStopped()
end)

test("command failure stops both timers", function()
  local model = setup()
  local calls = 0
  model.client.switchSpace(2, function(ok, error)
    assert(not ok and error == "rejected")
    calls = calls + 1
  end)
  model.requests[1].callback(false, "", "rejected")
  assert(calls == 1)
  model:assertStopped()
end)

test("an old failed reply cannot cancel a newer request for the same Space", function()
  local model = setup()
  local first, second = 0, 0
  model.client.switchSpace(2, function(ok)
    assert(not ok)
    first = first + 1
  end)
  model.timers[1].callback()
  model.client.switchSpace(2, function(ok)
    assert(ok)
    second = second + 1
  end)
  model.requests[1].callback(false, "", "stale error")
  assert(first == 1 and second == 0 and model.timers[3].active and model.timers[4].active)
  model.focused = 202
  model.requests[2].callback(true, "", "")
  assert(first == 1 and second == 1)
  model:assertStopped()
end)

print(passed .. " yabai tests passed")

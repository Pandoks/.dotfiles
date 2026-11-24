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
  options = options or {}
  local state = {
    loaded = options.loaded ~= false,
    dockRunning = options.dockRunning ~= false,
    devEnabled = options.devEnabled ~= false,
    opens = 0,
    deletes = 0,
    sends = {},
    onSend = options.onSend,
    injects = 0,
    tasks = {},
    errors = {},
    handles = {},
  }

  local function makePort()
    local handle = { valid = true, deleted = false }
    function handle:isValid()
      return not self.deleted and self.valid
    end
    function handle:send(payload, timeout)
      state.sends[#state.sends + 1] = { payload = payload, timeout = timeout }
      if state.onSend then
        return state.onSend(self, payload)
      end
      return true, ""
    end
    function handle:delete()
      if not self.deleted then
        self.deleted = true
        self.valid = false
        state.deletes = state.deletes + 1
      end
    end
    state.handles[#state.handles + 1] = handle
    return handle
  end

  local environment = setmetatable({
    hs = {
      application = {
        applicationsForBundleID = function(id)
          assertEqual(id, "com.apple.dock")
          return state.dockRunning
              and {
                {
                  pid = function()
                    return 4242
                  end,
                },
              }
            or {}
        end,
      },
      execute = function()
        return state.devEnabled and "Developer mode is currently enabled.\n" or "disabled\n"
      end,
      task = {
        new = function(path, callback, args)
          state.injects = state.injects + 1
          assertEqual(path, "/usr/bin/xcrun")
          local task = {
            callback = callback,
            args = args,
            terminated = false,
          }
          function task:start()
            state.tasks[#state.tasks + 1] = self
            if options.autoCompleteInject then
              state.loaded = true
              self.callback(0, "", "")
            end
          end
          function task:terminate()
            self.terminated = true
          end
          return task
        end,
      },
    },
    require = function(name)
      if name == "lib.logger" then
        return {
          error = function(msg)
            state.errors[#state.errors + 1] = msg
          end,
        }
      elseif name == "lib.utils" then
        return {
          build = function(target)
            assertEqual(target, "dock")
            return "/var/tmp/dock-test.so"
          end,
          native = function(target)
            assertEqual(target, "port")
            return {
              open = function(portName)
                state.opens = state.opens + 1
                assertEqual(portName, "org.hammerspoon.dock-test.so")
                if not state.loaded then
                  return nil
                end
                return makePort()
              end,
            }
          end,
        }
      end
      error("unexpected require: " .. name)
    end,
  }, { __index = _G })

  state.dock = assert(loadfile(root .. "/dock.lua", "t", environment))()
  function state:completeInject(success, output, errors)
    local task = assert(table.remove(self.tasks, 1), "no pending inject task")
    self.loaded = success
    task.callback(success and 0 or 1, output or "", errors or "")
  end
  return state
end

test("warm move and switch reuse one cached port across repeated calls", function()
  local state = harness()
  assertEqual(state.opens, 1)
  assertEqual(state.injects, 0)
  assertEqual(#state.sends, 1, "checks follow status once on connect")
  assertEqual(state.sends[1].payload, "follow")
  assertEqual(state.sends[1].timeout, 0.5, "follow handshake uses 0.5 s timeout")

  local results = {}
  state.dock.move(10, 20, function(ok, err)
    results[#results + 1] = { ok, err }
  end)
  state.dock.switch(30, function(ok, err)
    results[#results + 1] = { ok, err }
  end)
  state.dock.move(40, 50, function(ok, err)
    results[#results + 1] = { ok, err }
  end)

  assertEqual(state.opens, 1, "reuses cached port")
  assertEqual(state.deletes, 0, "never deletes valid cached port")
  assertEqual(#state.sends, 4)
  assertEqual(state.sends[2].payload, "10 20")
  assertEqual(state.sends[3].payload, "switch 30")
  assertEqual(state.sends[4].payload, "40 50")
  for i = 1, 3 do
    assertEqual(results[i][1], true)
    assertEqual(results[i][2], nil)
  end
  assertEqual(#state.errors, 0)
end)

test("invalidated cached port deletes stale handle and reconnects on next call", function()
  local state = harness()
  assertEqual(state.opens, 1)
  state.handles[1].valid = false

  local ok, err
  state.dock.switch(4, function(status, msg)
    ok, err = status, msg
  end)

  assertEqual(ok, true)
  assertEqual(err, nil)
  assertEqual(state.deletes, 1)
  assertEqual(state.handles[1].deleted, true)
  assertEqual(state.opens, 2)
  assertEqual(state.injects, 0)
  assertEqual(#state.sends, 3)
  assertEqual(state.sends[1].payload, "follow")
  assertEqual(state.sends[2].payload, "follow")
  assertEqual(state.sends[3].payload, "switch 4")
end)

test("send failure deletes stale handle and fails fast without reinjecting", function()
  local state = harness()
  state.onSend = function()
    return false, "send failed"
  end

  local ok1, err1
  state.dock.switch(5, function(status, msg)
    ok1, err1 = status, msg
  end)
  assertEqual(ok1, false, "fails fast on send failure")
  assertEqual(err1, "send failed")
  assertEqual(state.deletes, 1)
  assertEqual(state.injects, 0, "does not reinject on warm send failure")
  assertEqual(#state.sends, 2)
  assertEqual(state.sends[2].payload, "switch 5")

  -- If Dock restarted and the port is gone, the next call injects once cleanly.
  state.loaded = false
  state.onSend = nil
  local ok2, err2
  state.dock.switch(6, function(status, msg)
    ok2, err2 = status, msg
  end)
  assertEqual(state.injects, 1)
  state:completeInject(true)
  assertEqual(ok2, true)
  assertEqual(err2, nil)
  assertEqual(#state.sends, 4)
  assertEqual(state.sends[3].payload, "follow")
  assertEqual(state.sends[4].payload, "switch 6")
end)

test("queued switches supersede older pending switches and honor cancellation", function()
  local state = harness({ loaded = false })
  local firstOk, firstErr, secondOk, secondErr, thirdOk, thirdErr
  local cancelFirst = state.dock.switch(2, function(ok, err)
    firstOk, firstErr = ok, err
  end)
  assertEqual(type(cancelFirst), "function")
  state.dock.switch(3, function(ok, err)
    secondOk, secondErr = ok, err
  end)
  assertEqual(firstOk, false)
  assertEqual(firstErr, "superseded")

  local cancelSecond = state.dock.switch(4, function(ok, err)
    thirdOk, thirdErr = ok, err
  end)
  assertEqual(secondOk, false)
  assertEqual(secondErr, "superseded")
  cancelSecond()

  state:completeInject(true)
  assertEqual(#state.sends, 1, "superseded and cancelled switches are never sent")
  assertEqual(state.sends[1].payload, "follow")
  assertEqual(thirdOk, nil)
  assertEqual(thirdErr, nil)
end)

test("Dock error reply fails fast while keeping cached port open", function()
  local state = harness()
  state.onSend = function()
    return true, "Space 99 not found in Dock"
  end

  local ok, err
  state.dock.switch(99, function(status, msg)
    ok, err = status, msg
  end)
  assertEqual(ok, false)
  assertEqual(err, "Space 99 not found in Dock")
  assertEqual(state.deletes, 0)
  assertEqual(state.injects, 0)
end)

test("cold load queues multiple callers behind one inject and stop cleans up", function()
  local state = harness({ loaded = false })
  assertEqual(state.injects, 1)
  assertEqual(#state.tasks, 1)

  local results = {}
  state.dock.switch(4, function(ok, err)
    results[1] = { ok, err }
  end)
  state.dock.move(7, 4, function(ok, err)
    results[2] = { ok, err }
  end)
  assertEqual(state.injects, 1, "still one inject task")
  state:completeInject(true)
  assertEqual(results[1][1], true)
  assertEqual(results[2][1], true)
  assertEqual(state.sends[1].payload, "follow")
  assertEqual(state.sends[2].payload, "switch 4")
  assertEqual(state.sends[3].payload, "7 4")

  state.handles[1].valid = false
  state.loaded = false
  state.dock.switch(5, function() end)
  local pendingTask = state.tasks[1]
  state.dock.stop()
  assertEqual(pendingTask.terminated, true)
  assertEqual(state.handles[1].deleted, true)
end)

test(
  "helper declining follow reports once per reason via logger while Space switching keeps working",
  function()
    local followReply = "workspaces-auto-swoosh is disabled"
    local state = harness({
      onSend = function(_, payload)
        return true, payload == "follow" and followReply or ""
      end,
    })
    local function assertSwitch(space)
      local ok, failure
      state.dock.switch(space, function(status, message)
        ok, failure = status, message
      end)
      assertEqual(ok, true, "Space switching still succeeds")
      assertEqual(failure, nil)
    end

    assertEqual(#state.errors, 1, "reports follow decline once on connect")
    assertEqual(
      state.errors[1],
      "Dock helper did not take over Space follow: workspaces-auto-swoosh is disabled"
    )
    assertEqual(state.deletes, 0, "keeps port open when follow is declined")

    assertSwitch(8)
    assertEqual(#state.errors, 1, "does not repeat follow error on switches")

    state.handles[1].valid = false
    assertSwitch(9)
    assertEqual(#state.errors, 1, "does not repeat identical decline on reconnect")

    followReply = "Dock Spaces selectors unavailable"
    state.handles[2].valid = false
    assertSwitch(10)
    assertEqual(#state.errors, 2, "reports distinct decline reason on reconnect")
    assertEqual(
      state.errors[2],
      "Dock helper did not take over Space follow: Dock Spaces selectors unavailable"
    )

    followReply = ""
    state.handles[3].valid = false
    assertSwitch(11)
    assertEqual(#state.errors, 2, "recovery logs no error")

    followReply = "Dock Spaces selectors unavailable"
    state.handles[4].valid = false
    assertSwitch(12)
    assertEqual(#state.errors, 3, "reports decline again after a healthy reconnect")
    assertEqual(
      state.errors[3],
      "Dock helper did not take over Space follow: Dock Spaces selectors unavailable"
    )
  end
)

test("unanswered follow probe keeps the port open without reinjecting", function()
  local failAll = false
  local state = harness({
    onSend = function(_, payload)
      if failAll or payload == "follow" then
        return false, "receive timed out"
      end
      return true, ""
    end,
  })
  assertEqual(state.deletes, 0, "keeps port open after unanswered follow probe")
  assertEqual(state.injects, 0, "does not reinject after unanswered follow probe")
  assertEqual(#state.errors, 0, "does not report decline on unanswered follow probe")

  local ok, failure
  state.dock.switch(8, function(status, message)
    ok, failure = status, message
  end)
  assertEqual(ok, true, "switch succeeds on the opened port")
  assertEqual(failure, nil)
  assertEqual(state.opens, 1)

  failAll = true
  state.handles[1].valid = false
  state.dock.switch(9, function(status, message)
    ok, failure = status, message
  end)
  assertEqual(ok, false, "stalled switch still fails fast")
  assertEqual(failure, "receive timed out")
  assertEqual(state.injects, 0, "stalled probe on reconnect does not reinject")
  assertEqual(#state.errors, 0)
end)

print("RESULT " .. passed .. " passed, 0 failed")

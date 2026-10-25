-- Run with Lua 5.4: lua window_profiles_test.lua /path/to/lib
local root = assert(arg[1], "pass a lib directory")
local tasks, errors, reportRaises = {}, {}, false
local openOrFocusWindow = assert(loadfile(
  root .. "/../window_profiles.lua",
  "t",
  setmetatable({
    hs = {
      application = {
        applicationsForBundleID = function()
          return {}
        end,
      },
      spaces = {
        focusedSpace = function()
          return 1
        end,
      },
      task = {
        new = function(_, callback)
          local task = { callback = callback }
          function task:start()
            self.started = true
            return self
          end
          tasks[#tasks + 1] = task
          return task
        end,
      },
    },
    print = function() end,
    require = function(name)
      assert(name == "lib.logger")
      return {
        -- Its print reportRaises while a dead CLI is registered.
        error = function(message)
          errors[#errors + 1] = message
          if reportRaises then
            error("ipc port is no longer valid")
          end
        end,
      }
    end,
  }, { __index = _G })
))()
local passed = 0
local function test(name, body)
  for _, profile in ipairs({
    { bundleId = "com.example.app" },
    { bundleId = "com.example.windowed", match = "Main" },
  }) do
    tasks, errors = {}, {}
    openOrFocusWindow(profile)
    local task = assert(tasks[1], "no launch task")
    assert(task.started, "launch not started")
    body(task, profile.bundleId, profile)
  end
  passed = passed + 1
  print("PASS " .. name)
end
test("failed launches report the bundle id, exit code, and reason", function(task, bundleId)
  task.callback(1, "", "Unable to find application\n")
  assert(#errors == 1, bundleId)
  assert(errors[1]:find(bundleId, 1, true) and errors[1]:find("exit 1", 1, true), errors[1])
  assert(errors[1]:find("Unable to find application", 1, true), errors[1])
end)
test("successful launches report nothing", function(task, bundleId)
  task.callback(0, "", "")
  assert(#errors == 0, bundleId)
end)
test("a failed launch can be retried even when reporting raises", function(task, bundleId, profile)
  reportRaises = true
  pcall(task.callback, 1, "", "")
  reportRaises = false
  openOrFocusWindow(profile)
  assert(tasks[2], bundleId).callback(0, "", "")
end)
print("RESULT " .. passed .. " passed, 0 failed")

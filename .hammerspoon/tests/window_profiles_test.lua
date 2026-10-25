-- Run with Lua 5.4: lua window_profiles_test.lua /path/to/lib
local root = assert(arg[1], "pass a lib directory")
local tasks, errors = {}, {}
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
        error = function(message)
          errors[#errors + 1] = message
        end,
      }
    end,
  }, { __index = _G })
))()
local passed = 0
local function test(name, fn)
  for _, profile in ipairs({
    { bundleId = "com.example.app" },
    { bundleId = "com.example.windowed", match = "Main" },
  }) do
    tasks, errors = {}, {}
    openOrFocusWindow(profile)
    local task = assert(tasks[1], "no launch task")
    assert(task.started, "launch not started")
    fn(task, profile.bundleId)
  end
  passed = passed + 1
  print("PASS " .. name)
end
test("failed launches log and alert with the bundle id and reason", function(task, id)
  task.callback(1, "", "Unable to find application\n")
  assert(#errors == 1, id)
  assert(errors[1]:find(id, 1, true) and errors[1]:find("exit 1", 1, true), errors[1])
  assert(errors[1]:find("Unable to find application", 1, true), errors[1])
end)
test("successful launches report nothing", function(task, id)
  task.callback(0, "", "")
  assert(#errors == 0, id)
end)
print("RESULT " .. passed .. " passed, 0 failed")

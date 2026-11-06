-- Run with Lua 5.4: lua window_profiles_test.lua /path/to/lib
local root = assert(arg[1], "pass a lib directory")
local tasks, errors, calls, reportRaises = {}, {}, {}, false
local apps, rows, failure, filters, timers = {}, {}, nil, {}, {}
local environment = setmetatable({
  hs = {
    application = {
      applicationsForBundleID = function()
        return apps
      end,
    },
    spaces = {
      focusedSpace = function()
        return 1
      end,
      windowSpaces = function()
        return { 1 }
      end,
    },
    timer = {
      doAfter = function(_, fn)
        local timer = { fn = fn }
        function timer:stop()
          self.stopped = true
        end
        timers[#timers + 1] = timer
        return timer
      end,
    },
    task = {
      new = function(_, callback, arguments)
        local task = { callback = callback, arguments = arguments }
        function task:start()
          self.started = true
          return self
        end
        tasks[#tasks + 1] = task
        return task
      end,
    },
    json = {
      decode = function()
        return {
          profile = {
            info_cache = { Default = { name = "Personal" }, ["Profile 1"] = { name = "Work" } },
          },
        }
      end,
    },
  },
  io = {
    open = function()
      return {
        read = function() end,
        close = function() end,
      }
    end,
  },
  os = {
    getenv = function()
      return "/Users/test"
    end,
  },
  print = function() end,
}, { __index = _G })
local modules = {
  ["lib.logger"] = {
    -- Its print raises while a dead CLI is registered.
    error = function(message)
      errors[#errors + 1] = message
      if reportRaises then
        error("ipc port is no longer valid")
      end
    end,
  },
  ["lib.window_filter"] = {
    windowCreated = "windowCreated",
    windowTitleChanged = "windowTitleChanged",
    new = function(predicate)
      local filter = { predicate = predicate, callbacks = {} }
      function filter:subscribe(events, callback)
        for _, event in ipairs(events) do
          self.callbacks[event] = callback
        end
      end
      function filter:delete()
        self.deleted = true
      end
      filters[#filters + 1] = filter
      return filter
    end,
  },
  ["lib.window_manager"] = {
    windows = function(done)
      done(true, nil, rows)
    end,
    spaceOf = function(id)
      for _, row in ipairs(rows) do
        if row.id == id then
          return row.space
        end
      end
    end,
    focus = function(pid, id, done, minimized)
      calls[#calls + 1] = "focus " .. pid .. " " .. id .. (minimized and " minimized" or "")
      done(not failure, failure)
    end,
  },
}
function environment.require(name)
  if not modules[name] then
    assert(name == "lib.window_adapters.chromium", name)
    modules[name] = assert(loadfile(root .. "/window_adapters/chromium.lua", "t", environment))()
  end
  return modules[name]
end
local openOrFocusWindow = assert(loadfile(root .. "/../window_profiles.lua", "t", environment))()
local chromium = environment.require("lib.window_adapters.chromium")
local work = chromium.window({ bundleID = "net.imput.helium", profile = "Work" })
local personal = chromium.window({ bundleID = "net.imput.helium", profile = "Personal" })

local passed = 0
local function reset()
  tasks, errors, calls, apps, rows, failure, filters, timers = {}, {}, {}, {}, {}, nil, {}, {}
end
---@param main? table
---@param windows? table[] this Space, front to back
local function helium(main, windows)
  return {
    {
      pid = function()
        return 7
      end,
      mainWindow = function()
        return main
      end,
      allWindows = function()
        return windows or {}
      end,
      activate = function()
        calls[#calls + 1] = "activate"
      end,
    },
  }
end
local function window(id, title)
  return {
    id = function()
      return id
    end,
    title = function()
      return title
    end,
    isStandard = function()
      return true
    end,
    isMinimized = function()
      return false
    end,
    focus = function()
      calls[#calls + 1] = "window " .. id
    end,
  }
end
---@param event? string
local function appear(bundleId, title, event)
  local created = {
    application = function()
      return {
        bundleID = function()
          return bundleId
        end,
      }
    end,
    title = function()
      return title
    end,
  }
  for _, filter in ipairs(filters) do
    local callback = filter.callbacks[event or "windowCreated"]
    if not filter.deleted and callback and filter.predicate(created) then
      callback(created)
    end
  end
end
local function row(id, title, fields)
  fields = fields or {}
  fields.id, fields.title = id, title
  fields.pid = fields.pid or 7
  fields.space = fields.space or 2
  fields.subrole = fields.subrole or "AXStandardWindow"
  fields.root = fields.root ~= false
  fields.minimized = fields.minimized or false
  return fields
end
local function test(name, body)
  for _, profile in ipairs({
    { bundleId = "com.example.app" },
    { bundleId = "com.example.windowed", match = "Main" },
  }) do
    reset()
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
  appear(bundleId, "Main")
  assert(#errors == 0, bundleId)
end)
test("a failed launch can be retried even when reporting raises", function(task, bundleId, profile)
  reportRaises = true
  pcall(task.callback, 1, "", "")
  reportRaises = false
  openOrFocusWindow(profile)
  assert(tasks[2], bundleId).callback(0, "", "")
end)

local function check(name, body)
  reset()
  body()
  passed = passed + 1
  print("PASS " .. name)
end
check("a launch is deduplicated until its window appears, else reports", function()
  local ghostty =
    { bundleId = "com.mitchellh.ghostty", match = "local", args = { "--title=local" } }
  openOrFocusWindow(work)
  tasks[1].callback(0, "", "")
  openOrFocusWindow(work)
  openOrFocusWindow(ghostty)
  appear("net.imput.helium", "New Tab - Helium - Personal")
  appear("com.example.other", "New Tab - Helium - Work")
  openOrFocusWindow(work)
  assert(#tasks == 2)
  assert(
    table.concat(tasks[1].arguments, " ")
      == "-n -b net.imput.helium --args --profile-directory=Profile 1"
  )
  appear("net.imput.helium", "New Tab - Helium - Work")
  appear("com.mitchellh.ghostty", "")
  openOrFocusWindow(work)
  openOrFocusWindow(ghostty)
  assert(#tasks == 3 and #errors == 0)
  appear("com.mitchellh.ghostty", "local", "windowTitleChanged")
  openOrFocusWindow(ghostty)
  assert(#tasks == 4 and #errors == 0)
  for _, timer in ipairs(timers) do
    if not timer.stopped then
      timer.fn()
    end
  end
  assert(#errors == 2 and errors[1]:find("No window appeared", 1, true))
  openOrFocusWindow(work)
  assert(#tasks == 5)
end)
check("this Space's windows are focused front to back before any scan", function()
  apps = helium(window(1, "Home - Helium - Personal"), {
    window(1, "Home - Helium - Personal"),
    window(2, "Plan - Helium - Work"),
    window(3, "Mail - Helium - Work"),
  })
  openOrFocusWindow(work)
  openOrFocusWindow(personal)
  assert(table.concat(calls, ", ") == "window 2, activate", table.concat(calls, ", "))
end)
check("a profile's window on another Space or minimized is restored, never relaunched", function()
  apps = helium()
  rows = {
    row(1, "Docs - Work - Helium - Personal"),
    row(2, "Mail - Helium - Work", { minimized = true }),
    row(3, "Song - Helium - Work 🔊"),
    row(4, "Other app - Helium - Work", { pid = 9, space = 1 }),
    row(5, "Save - Helium - Work", { subrole = "AXDialog", space = 1 }),
  }
  openOrFocusWindow(work)
  table.remove(rows, 3)
  openOrFocusWindow(work)
  openOrFocusWindow(personal)
  assert(#tasks == 0 and #errors == 0)
  assert(
    table.concat(calls, ", ") == "focus 7 3, focus 7 2 minimized, focus 7 1",
    table.concat(calls, ", ")
  )
end)
check("a focus superseded by a newer Space jump stays quiet; other failures report", function()
  apps, rows = helium(), { row(1, "Plan - Helium - Work") }
  failure = "superseded"
  openOrFocusWindow(work)
  assert(#errors == 0)
  failure = "window unavailable"
  openOrFocusWindow(work)
  assert(#errors == 1 and errors[1]:find("window unavailable", 1, true))
end)
check("a missing browser profile reports and launches nothing", function()
  openOrFocusWindow(chromium.window({ bundleID = "net.imput.helium", profile = "Missing" }))
  assert(#tasks == 0 and #errors == 1 and errors[1]:find("Missing", 1, true))
end)
print("RESULT " .. passed .. " passed, 0 failed")

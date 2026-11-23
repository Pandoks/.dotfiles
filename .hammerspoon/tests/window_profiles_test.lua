-- Run with Lua 5.4: lua window_profiles_test.lua /path/to/lib
local root = assert(arg[1], "pass a lib directory")
local tasks, errors, calls, reportRaises = {}, {}, {}, false
local apps, rows, failure, filters, timers = {}, {}, nil, {}, {}
local scans, scanArgs, pendingScans, focusLive, focusSpaces, deferScans = {}, {}, {}, {}, {}, false
local mainWindowCalls, allWindowsCalls = 0, 0
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
    windowDestroyed = "windowDestroyed",
    windowTitleChanged = "windowTitleChanged",
    windowMinimized = "windowMinimized",
    windowUnminimized = "windowUnminimized",
    windowFocused = "windowFocused",
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
    windows = function(done, ...)
      local pids = ...
      scans[#scans + 1] = pids
      scanArgs[#scanArgs + 1] = select("#", ...) + 1
      if deferScans then
        pendingScans[#pendingScans + 1] = done
        return
      end
      done(true, nil, rows)
    end,
    spaceOf = function(id)
      for _, row in ipairs(rows) do
        if row.id == id then
          return row.space
        end
      end
    end,
    focus = function(pid, id, done, minimized, live, space)
      calls[#calls + 1] = "focus " .. pid .. " " .. id .. (minimized and " minimized" or "")
      focusLive[#focusLive + 1] = live
      focusSpaces[#focusSpaces + 1] = space
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
local openOrFocusWindow
local chromium = environment.require("lib.window_adapters.chromium")
local work = chromium.window({ bundleID = "net.imput.helium", profile = "Work" })
local personal = chromium.window({ bundleID = "net.imput.helium", profile = "Personal" })

local passed = 0
local function reset()
  tasks, errors, calls, apps, rows, failure, filters, timers = {}, {}, {}, {}, {}, nil, {}, {}
  scans, scanArgs, pendingScans, focusLive, focusSpaces, deferScans = {}, {}, {}, {}, {}, false
  mainWindowCalls, allWindowsCalls = 0, 0
  modules["lib.window_manager"].native = nil
  openOrFocusWindow = assert(loadfile(root .. "/../window_profiles.lua", "t", environment))()
end
---@param main? table
---@param windows? table[] this Space, front to back
---@param pid? integer
local function helium(main, windows, pid)
  pid = pid or 7
  return {
    {
      pid = function()
        return pid
      end,
      mainWindow = function()
        mainWindowCalls = mainWindowCalls + 1
        return main
      end,
      allWindows = function()
        allWindowsCalls = allWindowsCalls + 1
        return windows or {}
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
  }
end
---@param event? string
---@param pid? integer
---@param options? { standard?: boolean, minimized?: boolean }
local function appear(bundleId, title, id, event, pid, options)
  event = event or "windowCreated"
  options = options or {}
  local standard = options.standard ~= false
  local minimized = options.minimized ~= nil and options.minimized or event == "windowMinimized"
  local app = {
    bundleID = function()
      return bundleId
    end,
    pid = function()
      return pid or 7
    end,
  }
  local state = {
    id = id,
    pid = pid or 7,
    standard = standard,
    title = title,
    minimized = minimized,
  }
  local created
  if event == "windowFocused" then
    created = {}
    for _, method in ipairs({
      "id",
      "title",
      "subrole",
      "isStandard",
      "isMinimized",
      "isFullScreen",
      "frame",
      "role",
      "application",
    }) do
      created[method] = function()
        error("synchronous Accessibility read on focus: " .. method)
      end
    end
  else
    created = {
      application = function()
        return app
      end,
      title = function()
        return title
      end,
      isStandard = function()
        return standard
      end,
      isMinimized = function()
        return event == "windowMinimized"
      end,
    }
  end
  for _, filter in ipairs(filters) do
    local callback = filter.callbacks[event]
    local allowed = not filter.predicate
      or event == "windowDestroyed"
      or event == "windowFocused"
      or filter.predicate(created, app, state)
    if not filter.deleted and callback and allowed then
      callback(created, "App", event, id, state)
    end
  end
end
---@param id integer
local function destroy(id)
  for _, filter in ipairs(filters) do
    local callback = filter.callbacks.windowDestroyed
    if not filter.deleted and callback then
      callback(nil, "App", "windowDestroyed", id)
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
check("launches focus their window once it appears, else report", function()
  local ghostty =
    { bundleId = "com.mitchellh.ghostty", match = "local", args = { "--title=local" } }
  local slack = { bundleId = "com.tinyspeck.slackmacgap" }
  openOrFocusWindow(work)
  tasks[1].callback(0, "", "")
  openOrFocusWindow(work)
  openOrFocusWindow(ghostty)
  openOrFocusWindow(slack)
  appear("net.imput.helium", "New Tab - Helium - Personal", 1)
  appear("com.example.other", "New Tab - Helium - Work", 2)
  openOrFocusWindow(work)
  openOrFocusWindow(slack)
  assert(#tasks == 3 and #calls == 0)
  assert(
    table.concat(tasks[1].arguments, " ")
      == "-n -b net.imput.helium --args --profile-directory=Profile 1"
  )
  assert(
    table.concat(tasks[2].arguments, " ") == "-n -b com.mitchellh.ghostty --args --title=local"
  )
  assert(table.concat(tasks[3].arguments, " ") == "-b com.tinyspeck.slackmacgap")
  appear("net.imput.helium", "New Tab - Helium - Work", 3)
  appear("com.tinyspeck.slackmacgap", "Slack", 4)
  appear("com.mitchellh.ghostty", "", 5)
  openOrFocusWindow(work)
  openOrFocusWindow(ghostty)
  assert(#tasks == 4 and #errors == 0)
  appear("com.mitchellh.ghostty", "local", 5, "windowTitleChanged")
  openOrFocusWindow(ghostty)
  assert(#tasks == 5 and #errors == 0)
  assert(table.concat(calls, ", ") == "focus 7 3, focus 7 4, focus 7 5", table.concat(calls, ", "))
  for _, timer in ipairs(timers) do
    if not timer.stopped then
      timer.fn()
    end
  end
  assert(#errors == 2 and errors[1]:find("No window appeared", 1, true))
  openOrFocusWindow(work)
  assert(#tasks == 6)
end)
check("this Space's windows are focused front to back before any scan", function()
  apps = helium(window(1, "Home - Helium - Personal"), {
    window(1, "Home - Helium - Personal"),
    window(2, "Plan - Helium - Work"),
    window(3, "Mail - Helium - Work"),
  })
  openOrFocusWindow(work)
  openOrFocusWindow(personal)
  assert(table.concat(calls, ", ") == "focus 7 2, focus 7 1", table.concat(calls, ", "))
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
check("rapid switches drop stale window scans and cancel superseded focuses", function()
  apps, rows, deferScans = helium(), { row(1, "Plan - Helium - Work") }, true
  openOrFocusWindow(work)
  openOrFocusWindow(personal)
  assert(#pendingScans == 2 and #calls == 0)
  rows = { row(2, "Home - Helium - Personal") }
  pendingScans[1](true, nil, { row(1, "Plan - Helium - Work") })
  assert(#calls == 0, "stale scan must not steal focus")
  pendingScans[2](true, nil, rows)
  assert(#calls == 1 and calls[1] == "focus 7 2")
  assert(focusLive[1]() == true)
  openOrFocusWindow(work)
  assert(focusLive[1]() == false, "superseded focus live() must return false")
  deferScans, failure = false, "cancelled"
  rows = { row(1, "Plan - Helium - Work") }
  openOrFocusWindow(work)
  assert(#errors == 0)
  appear("net.imput.helium", "Plan - Helium - Work", 1, "windowFocused")
  failure = nil
  local before = #scans
  openOrFocusWindow(work)
  assert(#scans == before and calls[#calls] == "focus 7 1")
end)
check(
  "repeat switches hit the cache for observed windows and revalidate scan-only titles",
  function()
    apps = helium()
    rows = { row(1, "Home - Helium - Personal"), row(2, "Mail - Helium - Work") }
    openOrFocusWindow(work)
    assert(
      #scans == 1 and mainWindowCalls == 1 and allWindowsCalls == 1 and calls[1] == "focus 7 2"
    )
    appear("net.imput.helium", "Mail - Helium - Work", 2, "windowFocused")
    mainWindowCalls, allWindowsCalls = 0, 0
    -- Window 1 was only seen via scan (not observed by tracker), so a title change is caught.
    rows[1] = row(1, "Renamed - Helium - Work")
    openOrFocusWindow(personal)
    assert(
      #scans == 2 and #tasks == 1,
      "unobserved scan-only title is revalidated instead of trusted"
    )

    reset()
    apps = helium()
    rows = { row(10, "Draft - Helium - Work", { space = 2 }) }
    appear("net.imput.helium", "Draft - Helium - Work", 10, "windowCreated")
    appear("net.imput.helium", "Draft - Helium - Work", 10, "windowMinimized")
    openOrFocusWindow(work)
    assert(#scans == 0 and mainWindowCalls == 0 and allWindowsCalls == 0)
    assert(calls[1] == "focus 7 10 minimized")
    -- Stale minimized=true on windowTitleChanged must not overwrite focus()'s minimized=false.
    appear("net.imput.helium", "Renamed - Helium - Work", 10, "windowTitleChanged", 7, {
      minimized = true,
    })
    openOrFocusWindow(work)
    assert(#scans == 0 and calls[2] == "focus 7 10")
    appear("net.imput.helium", "Draft - Helium - Work", 10, "windowUnminimized")
    appear("net.imput.helium", "Inbox - Helium - Work", 10, "windowTitleChanged")
    openOrFocusWindow(work)
    assert(#scans == 0 and mainWindowCalls == 0 and allWindowsCalls == 0)
    assert(calls[3] == "focus 7 10")
  end
)
check(
  "windowFocused and launch predicates read cached state without synchronous AX calls",
  function()
    apps = helium()
    rows = {
      row(11, "Plan - Helium - Work", { space = 2 }),
      row(12, "Save - Helium - Work", { subrole = "AXDialog", space = 2 }),
    }
    -- Pre-existing window not yet in `known` (e.g. tracked before window_profiles loaded).
    appear("net.imput.helium", "Plan - Helium - Work", 11, "windowFocused")
    -- Non-standard window is ignored on focus without touching `window`.
    appear("net.imput.helium", "Save - Helium - Work", 12, "windowFocused", 7, { standard = false })
    openOrFocusWindow(work)
    assert(#scans == 0 and mainWindowCalls == 0 and allWindowsCalls == 0)
    assert(calls[1] == "focus 7 11")
    -- Becoming non-standard evicts a previously cached entry from `known`.
    appear("net.imput.helium", "Plan - Helium - Work", 11, "windowFocused", 7, { standard = false })
    rows[1].subrole = "AXDialog"
    openOrFocusWindow(work)
    assert(#scans == 1)

    -- Launch filter predicate also uses cached app/state instead of reading `window`.
    openOrFocusWindow(personal)
    local launchFilter = filters[#filters]
    assert(launchFilter and launchFilter.predicate)
    local forbidden = {}
    for _, method in ipairs({ "title", "application", "isStandard", "isMinimized", "id" }) do
      forbidden[method] = function()
        error("synchronous Accessibility read in launch predicate: " .. method)
      end
    end
    local app = {
      bundleID = function()
        return "net.imput.helium"
      end,
      pid = function()
        return 7
      end,
    }
    assert(launchFilter.predicate(forbidden, app, {
      id = 13,
      pid = 7,
      standard = true,
      title = "Home - Helium - Personal",
      minimized = false,
    }) == true)
  end
)
check("cache invalidates on windowDestroyed or missing Space", function()
  apps = helium()
  rows = { row(1, "Plan - Helium - Work"), row(2, "Mail - Helium - Work") }
  appear("net.imput.helium", "Plan - Helium - Work", 1, "windowCreated")
  appear("net.imput.helium", "Mail - Helium - Work", 2, "windowCreated")
  openOrFocusWindow(work)
  assert(#scans == 0 and calls[1] == "focus 7 1")
  destroy(1)
  openOrFocusWindow(work)
  assert(#scans == 0 and calls[2] == "focus 7 2")
  rows = {}
  openOrFocusWindow(work)
  assert(#scans == 1 and #tasks == 1)
end)
check("windowManager.windows receives deduplicated targeted pids for matching apps", function()
  apps = { helium(nil, nil, 7)[1], helium(nil, nil, 11)[1], helium(nil, nil, 7)[1] }
  rows = { row(5, "Mail - Helium - Work", { pid = 11 }) }
  openOrFocusWindow(work)
  assert(#scans == 1 and type(scans[1]) == "table")
  assert(#scans[1] == 2 and scans[1][1] == 7 and scans[1][2] == 11)
  assert(calls[1] == "focus 11 5")
end)
check("forwards resolved space and keeps cache on transient focus failures", function()
  apps, rows = helium(), { row(1, "Plan - Helium - Work", { space = 4 }) }
  appear("net.imput.helium", "Plan - Helium - Work", 1, "windowCreated")
  openOrFocusWindow(work)
  assert(#scans == 0 and focusSpaces[1] == 4)

  failure = "Space switch already in progress"
  openOrFocusWindow(work)
  assert(#errors == 1 and #scans == 0 and focusSpaces[2] == 4)

  failure = nil
  openOrFocusWindow(work)
  assert(#scans == 0, "transient failure keeps cached window")

  failure = "window unavailable"
  openOrFocusWindow(work)
  assert(#errors == 2 and #scans == 0)

  failure = nil
  openOrFocusWindow(work)
  assert(#scans == 1, "window unavailable evicts cached window")
end)
print("RESULT " .. passed .. " passed, 0 failed")

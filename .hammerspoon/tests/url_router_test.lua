local root = assert(arg[1])
local passed = 0
local function test(name, run)
  run()
  passed = passed + 1
  print("PASS " .. name)
end

local function browser(options)
  local settings = options or {}
  local state = {
    logs = {},
    prints = {},
    ports = {},
    tasks = {},
    reads = 0,
    lookups = 0,
    documents = {},
    publications = {},
  }
  local generation = 0
  local environment = setmetatable({
    print = function(message)
      state.prints[#state.prints + 1] = message
    end,
    io = {
      open = function(path)
        local contents
        if path:match("/state%.json$") then
          if settings.missingState then
            return nil, "not installed", settings.stateCode
          end
          contents = "installation"
        elseif path == "/var/tmp/router-test/status.json" then
          if settings.missingStatus then
            return nil, "status missing", settings.statusCode
          end
          contents = "status"
        else
          state.reads = state.reads + 1
          contents = "browser"
        end
        return {
          read = function()
            return contents
          end,
          close = function() end,
        }
      end,
    },
    hs = {
      application = {
        pathForBundleID = function(identifier)
          state.lookups = state.lookups + 1
          if settings.missingApp then
            return nil
          end
          return identifier == "local.pandoks.HammerspoonURLRouter" and "/Applications/Router.app"
            or "/Applications/Browser.app"
        end,
        infoForBundlePath = function()
          return { CFBundleExecutable = "Browser" }
        end,
      },
      http = {
        urlParts = function(url)
          local scheme, host = url:match("^([%a][%w+.-]*)://([^/:?#]+)")
          return { scheme = scheme, host = host }
        end,
      },
      host = {
        uuid = function()
          generation = generation + 1
          return "generation-" .. generation
        end,
      },
      hash = {
        SHA256 = function(contents)
          return "hash:" .. contents
        end,
      },
      fs = {
        attributes = function()
          return not settings.missingDirectory
              and (settings.fileDirectory and "file" or "directory")
            or nil
        end,
        mkdir = function()
          return not settings.mkdirFailure, "creation failed"
        end,
      },
      json = {
        encode = function(document)
          if settings.encodeFailure then
            error("encoding failed")
          end
          local contents = "snapshot:" .. document.generation
          state.documents[contents] = document
          return contents
        end,
        decode = function(contents)
          if contents == "installation" then
            return not settings.invalidState
                and {
                  statusPath = "/var/tmp/router-test/status.json",
                  phase = settings.installationPhase,
                }
              or {}
          elseif contents == "status" then
            if settings.invalidStatus then
              error("invalid JSON")
            end
            return state.status
          elseif contents:match("^notion:") then
            local domain = contents:sub(8)
            return { spaceDomain = domain ~= "" and domain or nil }
          end
          return {
            profile = {
              last_used = "Missing",
              info_cache = {
                Default = { name = "Personal" },
                ["Profile 1"] = not settings.missingProfile and { name = "Work" } or nil,
              },
            },
          }
        end,
      },
      task = {
        new = function(path, callback, arguments)
          state.tasks[#state.tasks + 1] =
            { path = path, callback = callback, arguments = arguments }
          if settings.missingTask then
            return nil
          end
          return {
            start = function()
              return not settings.startFailure
            end,
          }
        end,
      },
      urlevent = {},
      ipc = {
        localPort = function(name, callback)
          if settings.portFailure then
            error("local port name already in use")
          end
          state.ports[#state.ports + 1] = { name = name, callback = callback }
          return {}
        end,
      },
      osascript = {
        javascript = function()
          error("URL routing must not use window matching")
        end,
      },
      window = setmetatable({}, {
        __index = function()
          error("URL routing must not query windows")
        end,
      }),
      timer = setmetatable({}, {
        __index = function()
          error("URL routing must not poll")
        end,
      }),
    },
  }, { __index = _G })
  local modules = {
    ["lib.utils"] = {
      native = function(name)
        assert(name == "url_router")
        return {
          read = function(path)
            local file, error, code = environment.io.open(path)
            if not file then
              return nil, error, code
            end
            local contents = file:read("a")
            file:close()
            return contents
          end,
          publish = function(path, contents)
            if settings.publishFailure then
              return false, "publication failed"
            end
            local document = state.documents[contents]
            state.publications[#state.publications + 1] =
              { path = path, contents = contents, document = document }
            if not settings.pending then
              state.status = {
                version = 1,
                kind = "ready",
                generation = document.generation,
                sha256 = "hash:" .. contents,
                count = #document.rules,
                pid = 100,
              }
            end
            return true
          end,
          watch = function(_, changed)
            if settings.watchFailure then
              return nil, "watch failed"
            end
            state.changed = changed
            return function()
              state.canceled = (state.canceled or 0) + 1
            end
          end,
          process = function(pid, path, stopped)
            assert(path == "/usr/libexec/swcd")
            if settings.deadProcess then
              return false
            elseif settings.processFailure then
              return nil, "watch failed"
            end
            state.watched, state.stopped = pid, stopped
            return function()
              state.processCanceled = (state.processCanceled or 0) + 1
            end
          end,
        }
      end,
    },
    ["lib.logger"] = {
      error = function(message)
        if settings.loggerFailure then
          error("print failed")
        end
        state.logs[#state.logs + 1] = message
      end,
    },
  }
  environment.require = function(name)
    if not modules[name] then
      assert(
        name == "lib.url_router"
          or name == "lib.url_router.match"
          or name == "lib.url_adapters.notion"
          or name == "lib.window_adapters.chromium",
        name
      )
      modules[name] =
        assert(loadfile(root .. "/" .. name:sub(5):gsub("%.", "/") .. ".lua", "t", environment))()
    end
    return modules[name]
  end
  local router = environment.require("lib.url_router")
  if settings.rules then
    state.installed = router.install(settings.rules)
  else
    state.installed = assert(loadfile(root .. "/../url_router/init.lua", "t", environment))()
  end
  state.route, state.callback = environment.RouteHTTPURL, environment.hs.urlevent.httpCallback
  state.request = state.ports[1]
    and function(data, id)
      return state.ports[1].callback({}, id or 1, data)
    end
  state.router, state.environment, state.settings = router, environment, settings
  return state
end

test("unmatched URLs decline before resolving apps, profiles, or windows", function()
  for _, url in ipairs({
    "http://localhost:3000/",
    "http://127.0.0.1:8000/",
    "https://example.com/",
  }) do
    local state = browser({ missingApp = true, missingProfile = true })
    assert(state.installed and state.route(url) == "native")
    assert(state.lookups == 0 and state.reads == 0 and #state.tasks == 0 and #state.logs == 0)
  end
end)
test("Ramp domains explicitly launch Work without window matching", function()
  for _, host in ipairs({
    "ramp.com",
    "app.ramp.com",
    "login.app.ramp.com",
    "APP.RAMP.COM",
    "app.ramp.com.",
  }) do
    local state = browser()
    local url = "https://" .. host
    assert(
      state.route(url) == true and #state.tasks == 1 and state.tasks[1].path == "/usr/bin/open"
    )
    assert(
      table.concat(state.tasks[1].arguments, " ")
        == "-n -b net.imput.helium --args --profile-directory=Profile 1 " .. url
    )
  end
end)
test("lookalikes and embedded Ramp URLs remain native", function()
  for _, host in ipairs({ "notramp.com", "ramp.com.example.test", "example.test" }) do
    local state = browser()
    assert(state.route("https://" .. host .. "/ramp.com?redirect=https://app.ramp.com") == "native")
    assert(#state.tasks == 0 and state.reads == 0)
  end
end)
test("Notion links open in their workspace's browser profile", function()
  for url, directory in pairs({
    ["https://app.notion.com/p/sieve-data/document"] = "Profile 1",
    ["https://www.notion.so/sieve-data/Page-3382e03c6a5880368090d9fa3b706f16"] = "Profile 1",
    ["https://app.notion.com/p/pandoks/document"] = "Default",
    ["https://app.notion.com/p/kwok/document"] = "Default",
    ["https://www.notion.so/michelle/document"] = "Default",
  }) do
    local state = browser()
    assert(state.route(url) == true and #state.tasks == 1)
    assert(state.tasks[1].arguments[5] == "--profile-directory=" .. directory)
  end
end)
test("page-ID-only Notion links open in the workspace Notion reports", function()
  for _, case in ipairs({
    { "Codenames-3382e03c6a5880368090d9fa3b706f16", "sieve-data", "Profile 1" },
    { "Codenames-3382E03C6A5880368090D9FA3B706F16", "sieve-data", "Profile 1" },
    { "3382e03c6a5880368090d9fa3b706f16", "kwok", "Default" },
  }) do
    local url, domain, directory = "https://app.notion.com/p/" .. case[1], case[2], case[3]
    local state = browser()
    assert(state.route(url) == true and #state.tasks == 1)
    local lookup = state.tasks[1]
    assert(lookup.path == "/usr/bin/curl")
    assert(
      table
        .concat(lookup.arguments, " ")
        :find('"blockId":"3382e03c-6a58-8036-8090-d9fa3b706f16"', 1, true)
    )
    lookup.callback(0, "notion:" .. domain, "")
    assert(#state.tasks == 2 and state.tasks[2].arguments[5] == "--profile-directory=" .. directory)
    assert(state.tasks[2].arguments[6] == url and #state.logs == 0)
  end
end)
test("router.by reports actions that finish later exactly once", function()
  for _, action in ipairs({
    function()
      return false
    end,
    function() end,
    function()
      error("action failed")
    end,
    function()
      error({ reason = "action failed" })
    end,
  }) do
    local finish, reports = nil, {}
    local open = browser().router.by(function(_, done)
      finish = done
    end, {}, action)
    assert(open("https://example.com/", function(message)
      reports[#reports + 1] = message
    end) == true)
    assert(finish)("key")
    assert(#reports == 1 and reports[1]:match("^URL rule failed: "))
  end
end)
test("failed Notion lookups report once without opening a profile", function()
  local state = browser()
  assert(state.route("https://app.notion.com/p/3382e03c6a5880368090d9fa3b706f16") == true)
  state.tasks[1].callback(28, "", "Operation timed out")
  assert(#state.tasks == 1 and #state.logs == 1)
  assert(state.logs[1] == "Notion workspace lookup failed: Operation timed out")
  state = browser()
  assert(state.route("https://app.notion.com/p/3382e03c6a5880368090d9fa3b706f16") == true)
  state.tasks[1].callback(0, "notion:", "")
  assert(#state.tasks == 1 and #state.logs == 1)
  assert(state.logs[1] == "Notion workspace lookup failed: no workspace for this page")
  state = browser({ startFailure = true })
  assert(state.route("https://app.notion.com/p/3382e03c6a5880368090d9fa3b706f16") == false)
  assert(#state.tasks == 1 and #state.logs == 1)
  assert(state.logs[1] == "Could not start the Notion workspace lookup")
end)
test("the first explicit rule wins and can handle a different app", function()
  local calls = 0
  local state = browser({
    rules = {
      {
        host = "Example.COM",
        open = function(url)
          calls = calls + 1
          assert(url == "https://example.com/")
          return true
        end,
      },
      {
        pattern = ".",
        open = function()
          error("second rule must not run")
        end,
      },
    },
  })
  assert(state.route("https://example.com/") == true and calls == 1 and #state.tasks == 0)
end)
test("failed rules never fall through to native or another rule", function()
  for index, handler in ipairs({
    function(_, _)
      return false
    end,
    function(_, report)
      report("selected action failed")
      return false
    end,
    function(_, report)
      report("selected action failed")
      error("additional exception")
    end,
    function(_, report)
      report("selected action failed")
    end,
  }) do
    local calls = 0
    local state = browser({
      rules = {
        {
          host = "example.com",
          open = function(...)
            calls = calls + 1
            return handler(...)
          end,
        },
        {
          pattern = ".",
          open = function()
            error("second rule must not run")
          end,
        },
      },
    })
    assert(state.route("https://example.com/") == false and calls == 1 and #state.tasks == 0)
    assert(#state.logs == 1)
    if index == 1 then
      assert(state.logs[1]:find("returned false", 1, true))
    else
      assert(state.logs[1] == "selected action failed")
    end
  end
end)
test("reports that throw reach the helper instead of failing silently", function()
  local state = browser({
    loggerFailure = true,
    rules = {
      {
        host = "example.com",
        open = function(_, report)
          report("selected action failed")
          return false
        end,
      },
    },
  })
  assert(not pcall(state.request, "generation-1\nhttps://example.com/"))
end)
test("handler exceptions and missing results fail explicitly", function()
  for _, handler in ipairs({
    function()
      error("rule exploded")
    end,
    function() end,
  }) do
    local state = browser({ rules = { { host = "example.com", open = handler } } })
    assert(state.route("https://example.com/") == false and #state.logs == 1 and #state.tasks == 0)
  end
end)
test("invalid rules fail installation", function()
  for _, rule in ipairs({
    { host = "example.com" },
    {
      pattern = "[",
      open = function()
        return true
      end,
    },
    {
      host = "example.com",
      pattern = ".",
      open = function()
        return true
      end,
    },
    {
      open = function()
        return true
      end,
    },
  }) do
    local state = browser({ rules = { rule } })
    assert(not state.installed and state.route == nil and #state.logs == 1)
  end
  local state = browser({
    rules = {
      ramp = {
        host = "ramp.com",
        open = function()
          return true
        end,
      },
    },
  })
  assert(not state.installed and state.route == nil and #state.logs == 1)
end)
test("an empty configuration leaves every web URL native", function()
  local state = browser({ rules = {} })
  assert(state.route("https://app.ramp.com/") == "native" and state.lookups == 0)
end)
test("invalid HTTP URLs fail before any action", function()
  for _, url in ipairs({ "ftp://app.ramp.com/", "https:///missing", "not a URL" }) do
    local state = browser()
    assert(state.route(url) == false and #state.logs == 1 and state.lookups == 0)
  end
  local state = browser()
  assert(state.route(nil) == false and #state.logs == 1)
end)
test("missing explicit browser or profile fails without native fallback", function()
  for _, options in ipairs({ { missingApp = true }, { missingProfile = true } }) do
    local state = browser(options)
    assert(state.route("https://app.ramp.com/") == false and #state.logs == 1 and #state.tasks == 0)
  end
end)
test("direct Chromium actions retain their default failure reporter", function()
  local state = browser({ missingProfile = true })
  local open = state.environment.require("lib.window_adapters.chromium").url({
    bundleID = "net.imput.helium",
    profile = "Work",
  })
  assert(open("https://example.com/") == false and #state.logs == 1 and #state.tasks == 0)
  assert(state.logs[1] == "Chromium URL routing failed: missing profile Work")
end)
test("browser task creation and start failures are not retried", function()
  for _, options in ipairs({ { missingTask = true }, { startFailure = true } }) do
    local state = browser(options)
    assert(state.route("https://app.ramp.com/") == false and #state.tasks == 1 and #state.logs == 1)
  end
end)
test("browser process failure reports once after dispatch", function()
  local state = browser()
  assert(state.route("https://app.ramp.com/") == true)
  state.tasks[1].callback(1, "", "profile process failed")
  assert(
    #state.tasks == 1 and #state.logs == 1 and state.logs[1]:find("profile process failed", 1, true)
  )
end)
test("quotes and Unicode remain a single process argument", function()
  local state = browser()
  local url = 'https://app.ramp.com/path?quote="&value=\\&title=工作#test'
  assert(state.route(url) == true)
  assert(#state.tasks[1].arguments == 6 and state.tasks[1].arguments[6] == url)
end)
test("direct Hammerspoon HTTP events invoke the native helper once", function()
  local state = browser()
  local url = 'http://localhost:3000/path?quote="&value=\\#test'
  state.callback("http", "localhost", {}, url)
  assert(#state.tasks == 1 and state.reads == 0)
  assert(state.tasks[1].path == "/Applications/Router.app/Contents/MacOS/HammerspoonURLRouter")
  assert(state.tasks[1].arguments[1] == "--native" and state.tasks[1].arguments[2] == url)
end)
test("direct matched HTTP events do not invoke native handling", function()
  local state = browser()
  state.callback("https", "app.ramp.com", {}, "https://app.ramp.com/")
  assert(#state.tasks == 1 and state.tasks[1].arguments[5] == "--profile-directory=Profile 1")
end)
test("native helper failures log without reopening", function()
  for _, options in ipairs({
    { missingApp = true },
    { missingTask = true },
    { startFailure = true },
  }) do
    local state = browser(options)
    state.callback("http", "localhost", {}, "http://localhost:3000/")
    assert(#state.logs == 1 and #state.tasks == (options.missingApp and 0 or 1))
  end
  local state = browser()
  state.callback("http", "localhost", {}, "http://localhost:3000/")
  state.tasks[1].callback(1, "", "native process failed")
  assert(#state.tasks == 1 and #state.logs == 1)
end)
test("selectors preserve order without serializing action functions", function()
  local open = function()
    return true
  end
  local state = browser({
    rules = { { pattern = "^https://b/", open = open }, { host = "A.example", open = open } },
  })
  local publication = state.publications[1]
  assert(publication.path:match("/HammerspoonURLRouter/selectors/rules%.json$"))
  local rules = publication.document.rules
  assert(publication.document.version == 1 and #rules == 2)
  assert(rules[1].pattern == "^https://b/" and rules[2].host == "a.example")
  for _, rule in ipairs(rules) do
    assert(next(rule, next(rule)) == nil)
  end
end)
test("pending selectors cannot dispatch until their exact generation is acknowledged", function()
  local opened = 0
  local state = browser({
    pending = true,
    rules = {
      {
        host = "app.ramp.com",
        open = function()
          opened = opened + 1
          return true
        end,
      },
    },
  })
  assert(state.installed and not state.router.status().ready)
  assert(state.route("https://app.ramp.com/", "generation-1") == false and #state.tasks == 0)
  state.status = {
    version = 1,
    kind = "ready",
    generation = "older",
    sha256 = "hash:snapshot:generation-1",
    count = 1,
    pid = 100,
  }
  state.changed()
  assert(not state.router.status().ready)
  state.status.generation = "generation-1"
  state.changed()
  assert(
    state.router.status().ready and state.route("https://app.ramp.com/", "generation-1") == true
  )
  assert(state.route("https://app.ramp.com/", "older") == false and opened == 1)
end)
test("selector acknowledgement rejects wrong versions, kinds, bytes, counts, and PIDs", function()
  for _, change in ipairs({
    { version = 2 },
    { kind = "other" },
    { sha256 = "different" },
    { count = 99 },
    { pid = 0 },
    { pid = 1.5 },
    { pid = 0x80000000 },
  }) do
    local state = browser()
    for key, value in pairs(change) do
      state.status[key] = value
    end
    state.changed()
    assert(not state.router.status().ready)
    assert(state.route("https://app.ramp.com/") == false and #state.tasks == 0)
  end
end)
test("readiness and process watch errors report once", function()
  for _, options in ipairs({
    { invalidStatus = true },
    { missingStatus = true },
    { processFailure = true },
    { invalidState = true },
    { missingState = true },
    { watchFailure = true },
  }) do
    local state = browser(options)
    assert(not state.router.status().ready and #state.logs == 1)
    if state.changed then
      state.changed()
    end
    assert(#state.logs == 1)
  end
  local state = browser()
  state.status = { version = 1, kind = "error", stage = "hook", error = "unavailable" }
  state.changed()
  state.changed()
  assert(not state.router.status().ready and #state.logs == 1)
end)
test("idle swcd exit pauses quietly until launchd republishes readiness", function()
  local state = browser()
  assert(state.router.status().ready and state.watched == 100)
  state.stopped("Universal Link interception process exited")
  assert(not state.router.status().ready and not state.router.status().error)
  assert(#state.logs == 0 and #state.prints == 1)
  state.settings.deadProcess = true
  state.changed()
  assert(not state.router.status().ready and #state.logs == 0 and #state.prints == 1)
  state.settings.deadProcess, state.status.pid = false, 101
  state.changed()
  assert(state.router.status().ready and state.watched == 101 and #state.logs == 0)
  assert(state.request("generation-1\nhttps://app.ramp.com/") == "true" and #state.tasks == 1)
end)
test("a ready status from an exited or reused swcd ID waits quietly", function()
  local state = browser({ deadProcess = true })
  assert(state.installed and not state.router.status().ready and not state.router.status().error)
  state.changed()
  assert(#state.logs == 0 and #state.prints == 0)
  assert(state.route("https://app.ramp.com/") == false and #state.tasks == 0)
end)
test("the helper port routes encoded requests with the current generation", function()
  local state = browser()
  assert(#state.ports == 1 and state.ports[1].name == "local.pandoks.HammerspoonURLRouter.route")
  assert(state.request("generation-1\nhttps://app.ramp.com/") == "true" and #state.tasks == 1)
  assert(state.request("generation-1\nhttps://example.com/") == "native" and #state.logs == 0)
  assert(state.request("older\nhttps://app.ramp.com/") == "false" and #state.logs == 1)
  for _, request in ipairs({
    { "generation-1\nhttps://app.ramp.com/", 2 },
    { nil, 1 },
    { "https://app.ramp.com/", 1 },
    { "generation-1\n", 1 },
    { "\nhttps://app.ramp.com/", 1 },
    { "generation-1\nhttps://app.ramp.com/\nhttps://example.com/", 1 },
    { "generation-1\nfile:///var/tmp/test", 1 },
  }) do
    local logs = #state.logs
    assert(state.request(request[1], request[2]) == "false" and #state.logs == logs + 1)
  end
  assert(#state.tasks == 1)
end)
test("port creation failure fails installation once", function()
  local state = browser({ portFailure = true })
  assert(
    not state.installed and #state.logs == 1 and state.logs[1]:find("could not listen", 1, true)
  )
  assert(state.router.status().error and #state.ports == 0)
end)
test("live installs wait quietly for their first status and report its deletion", function()
  for _, phase in ipairs({ "staged", "activating", "awaiting-login", "ready" }) do
    local state = browser({ missingStatus = true, statusCode = 2, installationPhase = phase })
    assert(state.installed and not state.router.status().ready and #state.logs == 0)
    state.changed()
    assert(not state.router.status().ready and #state.logs == 0 and not state.canceled)
    state.settings.missingStatus = false
    state.changed()
    assert(state.router.status().ready and #state.logs == 0)
    state.settings.missingStatus = true
    state.changed()
    assert(not state.router.status().ready and #state.logs == 1)
  end
end)
test("intentional uninstall cancels interception watchers without a failure popup", function()
  for _, phase in ipairs({ "uninstalling", "restored", "removed" }) do
    local state = browser()
    state.settings.installationPhase = phase
    if phase == "removed" then
      state.settings.missingState, state.settings.stateCode = true, 2
    end
    state.stopped("process exited")
    assert(not state.router.status().ready and not state.router.status().error and #state.logs == 0)
    assert(state.canceled == 1 and state.processCanceled == 1)
    assert(state.route("https://app.ramp.com/") == false and #state.tasks == 0 and #state.logs == 1)
  end
end)
test("publication failures preserve the last acknowledged actions", function()
  for _, option in ipairs({ "encodeFailure", "publishFailure", "mkdirFailure", "fileDirectory" }) do
    local state = browser()
    state.settings[option] = true
    if option == "mkdirFailure" then
      state.settings.missingDirectory = true
    end
    assert(not state.router.install({
      {
        host = "example.com",
        open = function()
          error("new action")
        end,
      },
    }))
    assert(state.router.status().generation == "generation-1" and state.router.status().ready)
    assert(state.route("https://app.ramp.com/") == true and #state.tasks == 1)
    assert(#state.publications == 1 and #state.logs == 1)
  end
end)
test("reinstallation revokes old readiness and isolates rules from caller mutation", function()
  local old, new = 0, 0
  local rules = {
    {
      host = "example.com",
      open = function()
        old = old + 1
        return true
      end,
    },
  }
  local state = browser({ rules = rules })
  rules[1].host = "different.com"
  rules[1].open = function()
    error("mutated caller rules")
  end
  assert(state.route("https://example.com/") == true and old == 1)
  state.settings.pending = true
  assert(state.router.install({
    {
      host = "example.com",
      open = function()
        new = new + 1
        return true
      end,
    },
  }))
  assert(state.canceled == 1 and state.processCanceled == 1 and not state.router.status().ready)
  assert(state.environment.RouteHTTPURL("https://example.com/", "generation-1") == false)
  state.status = {
    version = 1,
    kind = "ready",
    generation = "generation-2",
    sha256 = "hash:snapshot:generation-2",
    count = 1,
    pid = 100,
  }
  state.changed()
  assert(state.environment.RouteHTTPURL("https://example.com/", "generation-2") == true)
  assert(state.request("generation-2\nhttps://example.com/") == "true" and #state.ports == 1)
  assert(old == 1 and new == 2)
end)
test("malformed pattern suffixes fail explicitly without poisoning valid routing", function()
  local state = browser({
    rules = {
      {
        pattern = "^https://example%.com/[",
        open = function()
          error("invalid pattern action")
        end,
      },
    },
  })
  assert(state.installed and state.route("https://example.com/test") == false)
  assert(#state.logs == 1 and #state.tasks == 0)
  assert(state.route("https://other.com/") == "native")
end)
print("RESULT " .. passed .. " passed, 0 failed")

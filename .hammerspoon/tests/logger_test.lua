local root = assert(arg[1])
for _, failure in ipairs({ "mkdir", "open", "write", "close" }) do
  local logs, alerts, attempts = {}, {}, 0
  local environment = setmetatable({
    print = function(message)
      logs[#logs + 1] = message
    end,
    hs = {
      fs = {
        attributes = function()
          return failure ~= "mkdir"
        end,
        mkdir = function()
          return nil, "mkdir failed"
        end,
      },
    },
    require = function(name)
      assert(name == "lib.toast")
      return {
        show = function(message)
          alerts[#alerts + 1] = message
        end,
      }
    end,
    io = {
      open = function()
        attempts = attempts + 1
        if failure == "open" then
          return nil, "open failed"
        end
        return {
          write = function()
            if failure == "write" then
              return nil, "write failed"
            end
            return true
          end,
          close = function()
            if failure == "close" then
              return nil, "close failed"
            end
            return true
          end,
        }
      end,
    },
  }, { __index = _G })
  local logger = assert(loadfile(root .. "/logger.lua", "t", environment))()
  logger.install()
  environment.print("first")
  environment.print("second")
  assert(#alerts == 1 and #logs == 3 and attempts <= 1, failure)
  assert(alerts[1]:find(failure .. " failed", 1, true))
  print("PASS file logger " .. failure .. " failure logs, alerts, and never retries")
end
local function loadLogger(fakePrint, fakeShow)
  return assert(loadfile(
    root .. "/logger.lua",
    "t",
    setmetatable({
      print = fakePrint,
      require = function(name)
        assert(name == "lib.toast")
        return { show = fakeShow }
      end,
    }, { __index = _G })
  ))()
end
local alerts = {}
local logger = loadLogger(function()
  error("ipc port is no longer valid")
end, function(message, options)
  assert(type(message) == "string", "no text")
  alerts[#alerts + 1] = message
  assert(options.failure and options.seconds == 5, "not a 5 s failure toast")
end)
assert(pcall(logger.error, "Tiling: no window\ndetail") and alerts[1] == "Tiling: no window")
print("PASS an error alerts even when print raises")
for _, message in ipairs({ "", "\nstack traceback:" }) do
  assert(pcall(logger.error, message), "raised on " .. ("%q"):format(message))
end
assert(alerts[2] == "" and alerts[3] == "stack traceback:", tostring(alerts[3]))
print("PASS an empty or line-break-first error still alerts")
local logs = {}
local loggerWithRaisingToast = loadLogger(function(message)
  logs[#logs + 1] = message
end, function()
  error("no glass")
end)
local ok, problem = pcall(loggerWithRaisingToast.error, "Tiling: no window")
assert(not ok and tostring(problem):find("no glass", 1, true), "the toast's error was lost")
assert(logs[1] == "Tiling: no window", "not logged before a toast that raised")
print("PASS an error is logged before its toast, which may raise")
print("RESULT 7 passed, 0 failed")

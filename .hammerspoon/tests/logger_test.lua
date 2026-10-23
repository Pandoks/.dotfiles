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
        show = function(message, options)
          alerts[#alerts + 1] = (options.failure and "failure: " or "") .. message
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
  assert(alerts[1]:find("^failure: ") and alerts[1]:find(failure .. " failed", 1, true))
  print("PASS file logger " .. failure .. " failure logs, alerts, and never retries")
end
local alerts = {}
local logger = assert(loadfile(
  root .. "/logger.lua",
  "t",
  setmetatable({
    print = function()
      error("ipc port is no longer valid") -- hs.ipc's, with a dead `hs` CLI registered
    end,
    require = function(name)
      assert(name == "lib.toast")
      return {
        show = function(message)
          alerts[#alerts + 1] = message
        end,
      }
    end,
  }, { __index = _G })
))()
assert(pcall(logger.error, "Tiling: no window\ndetail") and alerts[1] == "Tiling: no window")
print("PASS an error alerts even when print raises")
for _, message in ipairs({ "", "\nstack traceback:" }) do
  assert(pcall(logger.error, message), "raised on " .. ("%q"):format(message))
end
assert(alerts[2] == "" and alerts[3] == "stack traceback:", tostring(alerts[3]))
print("PASS an empty or line-break-first error still alerts")
print("RESULT 6 passed, 0 failed")

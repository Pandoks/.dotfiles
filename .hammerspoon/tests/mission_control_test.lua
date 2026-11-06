local root = assert(arg[1])
local passed = 0
local function test(name, body)
  body()
  passed = passed + 1
  print("PASS " .. name)
end
-- The Dock's children carry the "mc" element only while Mission Control is open.
local function harness(options)
  local desktop = { reads = 0, logs = {}, open = false, broken = false, running = {}, now = 0 }
  options = options or {}
  local function app(pid)
    desktop.running[pid] = true
    return {
      pid = function()
        return pid
      end,
      isRunning = function()
        return desktop.running[pid]
      end,
    }
  end
  desktop.dock = not options.missing and app(10) or nil
  local hs = {
    application = {
      applicationsForBundleID = function()
        return desktop.dock and { desktop.dock } or {}
      end,
    },
    axuielement = {
      applicationElement = function(dock)
        return {
          attributeValue = function(_, key)
            assert(key == "AXChildren")
            assert(dock == desktop.dock, "read through a replaced Dock")
            desktop.reads = desktop.reads + 1
            if desktop.broken then
              return nil, "Messaging failed"
            end
            local identifiers = { "dock", desktop.open and "mc" or nil }
            local children = {}
            for _, identifier in ipairs(identifiers) do
              children[#children + 1] = {
                attributeValue = function(_, name)
                  assert(name == "AXIdentifier")
                  return identifier
                end,
              }
            end
            return children
          end,
        }
      end,
    },
    timer = setmetatable({
      secondsSinceEpoch = function()
        return desktop.now
      end,
    }, {
      __index = function()
        error("no Mission Control polling")
      end,
    }),
  }
  local environment = setmetatable({
    hs = hs,
    require = function(name)
      assert(name == "lib.logger")
      return {
        error = function(message)
          desktop.logs[#desktop.logs + 1] = message
        end,
      }
    end,
  }, { __index = _G })
  desktop.module = assert(loadfile(root .. "/mission_control.lua", "t", environment))()
  function desktop:restart()
    if self.dock then
      self.running[self.dock.pid()] = false
    end
    self.dock = app((self.dock and self.dock.pid() or 10) + 10)
  end
  return desktop
end

test("reports Mission Control from the Dock at each call, without notifications", function()
  local desktop = harness()
  assert(desktop.module.isActive() == false)
  desktop.open = true
  assert(desktop.module.isActive() == true)
  desktop.open = false
  assert(desktop.module.isActive() == false)
end)

test("a missing or relaunched Dock is found at the next read", function()
  local desktop = harness({ missing = true })
  assert(desktop.module.isActive() == false and desktop.reads == 0)
  desktop:restart()
  desktop.open = true
  assert(desktop.module.isActive() == true)
  desktop:restart()
  assert(desktop.module.isActive() == true, "the relaunched Dock is read, not the old one")
end)

test("a relaunched Dock reads as inactive until it answers, then fails loudly", function()
  local desktop = harness()
  desktop:restart()
  desktop.broken = true
  assert(desktop.module.isActive() == false and desktop.module.isActive() == false)
  assert(#desktop.logs == 0)
  desktop.broken = false
  assert(desktop.module.isActive() == false)
  desktop.broken = true
  assert(not pcall(desktop.module.isActive))
  assert(#desktop.logs == 1)
end)

test("a relaunched Dock that never answers fails loudly after a second", function()
  local desktop = harness()
  desktop:restart()
  desktop.broken = true
  assert(desktop.module.isActive() == false and #desktop.logs == 0)
  desktop.now = 1
  assert(not pcall(desktop.module.isActive))
  assert(#desktop.logs == 1)
end)

test("a failed read logs once, then fails until the Dock relaunches", function()
  local desktop = harness()
  desktop.broken = true
  assert(not pcall(desktop.module.isActive))
  assert(not pcall(desktop.module.isActive))
  assert(#desktop.logs == 1 and desktop.reads == 1)
  desktop.broken = false
  desktop:restart()
  assert(desktop.module.isActive() == false and #desktop.logs == 1)
end)

test("shutdown reads nothing afterwards", function()
  local desktop = harness()
  desktop.open = true
  desktop.module.stop()
  assert(desktop.module.isActive() == false and desktop.reads == 0)
end)
print("RESULT " .. passed .. " passed, 0 failed")

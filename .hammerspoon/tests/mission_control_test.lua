local root = assert(arg[1])
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
-- The Dock's children carry the "mc" element only while Mission Control is open.
local function harness(options)
  local h = { reads = 0, logs = {}, open = false, broken = false }
  local o = options or {}
  local function app(pid)
    return {
      pid = function()
        return pid
      end,
      bundleID = function()
        return "com.apple.dock"
      end,
    }
  end
  h.dock = not o.missing and app(10) or nil
  local watcher
  local hs = {
    application = {
      applicationsForBundleID = function()
        return h.dock and { h.dock } or {}
      end,
      watcher = {
        launched = 1,
        terminated = 2,
        new = function(callback)
          watcher = { callback = callback }
          function watcher:start()
            self.started = true
            return self
          end
          function watcher:stop()
            self.started = false
          end
          return watcher
        end,
      },
    },
    axuielement = {
      applicationElement = function(dock)
        return {
          attributeValue = function(_, key)
            assert(key == "AXChildren")
            assert(dock == h.dock, "read through a replaced Dock")
            h.reads = h.reads + 1
            if h.broken then
              return nil, "unavailable"
            end
            local identifiers = { "dock", h.open and "mc" or nil }
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
    timer = setmetatable({}, {
      __index = function()
        error("no Mission Control polling")
      end,
    }),
  }
  local env = setmetatable({
    hs = hs,
    require = function(name)
      assert(name == "lib.logger")
      return {
        error = function(message)
          h.logs[#h.logs + 1] = message
        end,
      }
    end,
  }, { __index = _G })
  h.module = assert(loadfile(root .. "/mission_control.lua", "t", env))()
  function h:restart()
    watcher.callback(nil, 2, self.dock)
    self.dock = app(20)
    watcher.callback(nil, 1, self.dock)
  end
  h.watcher = watcher
  return h
end

test("reports Mission Control from the Dock at each call, without notifications", function()
  local h = harness()
  assert(h.module.isActive() == false)
  h.open = true
  assert(h.module.isActive() == true)
  h.open = false
  assert(h.module.isActive() == false)
end)

test("a missing or restarting Dock reads as inactive and attaches on launch", function()
  local h = harness({ missing = true })
  assert(h.module.isActive() == false and h.reads == 0)
  h:restart()
  h.open = true
  assert(h.module.isActive() == true)
  h:restart()
  assert(h.module.isActive() == true, "the relaunched Dock is read, not the old one")
end)

test("a failed read logs once, then fails until the Dock relaunches", function()
  local h = harness()
  h.broken = true
  assert(not pcall(h.module.isActive))
  assert(not pcall(h.module.isActive))
  assert(#h.logs == 1 and h.reads == 1)
  h.broken = false
  h:restart()
  assert(h.module.isActive() == false and #h.logs == 1)
end)

test("shutdown stops the watcher and reads nothing afterwards", function()
  local h = harness()
  h.open = true
  h.module.stop()
  assert(not h.watcher.started)
  assert(h.module.isActive() == false and h.reads == 0)
end)
print("RESULT " .. passed .. " passed, 0 failed")

local root = assert(arg[1])
local passed = 0
local function test(name, fn)
  fn()
  passed = passed + 1
  print("PASS " .. name)
end
local function harness(options)
  local h = { reads = 0, observers = {}, logs = {} }
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
      applicationElement = function()
        return {
          attributeValue = function(_, key)
            h.reads = h.reads + 1
            assert(key == "AXChildren")
            if o.seedError then
              return nil, "unavailable"
            end
            return {
              {
                attributeValue = function(_, name)
                  h.reads = h.reads + 1
                  assert(name == "AXIdentifier")
                  return o.active and "mc" or "dock"
                end,
              },
            }
          end,
        }
      end,
      observer = {
        new = function(pid)
          local observer = { pid = pid, names = {} }
          function observer:callback(fn)
            self.fn = fn
            self.saved = fn or self.saved
            return self
          end
          function observer:addWatcher(_, name)
            if o.registrationError then
              error("registration rejected")
            end
            self.names[name] = true
            return self
          end
          function observer:start()
            self.started = true
            return self
          end
          function observer:stop()
            self.started = false
          end
          h.observers[#h.observers + 1] = observer
          return observer
        end,
      },
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
  function h:event(name, index)
    local observer = self.observers[index or #self.observers]
    assert(observer.names[name])
    observer.saved(observer, nil, name)
  end
  function h:restart()
    watcher.callback(nil, 2, self.dock)
    self.dock = app(20)
    watcher.callback(nil, 1, self.dock)
  end
  h.watcher = watcher
  return h
end

test("ordinary Dock is inactive and repeated reads perform no Accessibility calls", function()
  local h = harness()
  local reads = h.reads
  for _ = 1, 100 do
    assert(h.module.isActive() == false)
  end
  assert(h.reads == reads)
end)

test("startup seeds an already open Mission Control overview", function()
  local h = harness({ active = true })
  assert(h.module.isActive())
  h:event("AXExposeExit")
  assert(not h.module.isActive())
end)

test("Dock notifications update all overview modes without reading Accessibility", function()
  local h = harness()
  local reads = h.reads
  for _, mode in ipairs({
    "AXExposeShowAllWindows",
    "AXExposeShowFrontWindows",
    "AXExposeShowDesktop",
  }) do
    h:event(mode)
    assert(h.module.isActive())
    h:event("AXExposeExit")
    assert(not h.module.isActive())
  end
  assert(h.reads == reads)
end)

test("Dock restart replaces subscriptions and ignores old callbacks", function()
  local h = harness()
  h:event("AXExposeShowAllWindows")
  h:restart()
  assert(not h.module.isActive())
  assert(not h.observers[1].started and h.observers[2].started)
  h:event("AXExposeShowAllWindows", 1)
  assert(not h.module.isActive())
  h:event("AXExposeShowAllWindows")
  assert(h.module.isActive())
end)

test("missing Dock waits for its launch without timers", function()
  local h = harness({ missing = true })
  assert(not h.module.isActive() and #h.observers == 0)
  h:restart()
  h:event("AXExposeShowAllWindows")
  assert(h.module.isActive() and #h.observers == 1)
end)

test("registration and seed failures log once and never retry on reads", function()
  for _, options in ipairs({ { registrationError = true }, { seedError = true } }) do
    local h = harness(options)
    assert(#h.logs == 1)
    assert(not h.observers[1].started)
    assert(not pcall(h.module.isActive))
    assert(not pcall(h.module.isActive))
    assert(#h.observers == 1 and #h.logs == 1)
  end
end)

test("shutdown removes subscriptions and rejects late notifications", function()
  local h = harness()
  h.module.stop()
  assert(not h.watcher.started and not h.observers[1].started)
  h:event("AXExposeShowAllWindows")
  assert(not h.module.isActive())
end)
print("RESULT " .. passed .. " passed, 0 failed")

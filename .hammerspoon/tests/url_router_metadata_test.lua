local native, root, state, status, json, pid, finish = ...
local logs = {}
package.loaded["lib.utils"] = {
  native = function()
    return native
  end,
}
package.loaded["lib.logger"] = {
  error = function(message)
    logs[#logs + 1] = message
  end,
}
package.loaded["lib.url_router.match"] = assert(loadfile(root .. "/url_router/match.lua"))()
local environment = setmetatable({
  hs = {
    host = {
      uuid = function()
        return "metadata-test"
      end,
    },
    hash = {
      SHA256 = function()
        return "digest"
      end,
    },
    fs = {
      attributes = function()
        return "directory"
      end,
    },
    json = {
      encode = function()
        return "{}"
      end,
      decode = function(contents)
        if contents == "installation" then
          return { statusPath = status, phase = "staged" }
        end
        error("unexpected metadata")
      end,
    },
    urlevent = {},
  },
}, { __index = _G })

local router = assert(loadfile(root .. "/url_router.lua", "t", environment))()
assert(not router.install({}))
assert(#logs == 1 and logs[1]:find("regular", 1, true) and not router.status().ready)
print("PASS actual Lua installation rejects FIFO state with one failure report")

assert(native.publish(state, "installation"))
logs = {}
assert(router.install({}))
assert(#logs == 1 and logs[1]:find("regular", 1, true) and not router.status().ready)
assert(environment.RouteHTTPURL("https://ramp.com/", "metadata-test") == false)
print("PASS actual Lua readiness rejects FIFO status before dispatch while staged")

local events, canceled, stopped, quiescent, mode, generation, receipt
local weak, exiting
local selectors = state:gsub("state%.json$", "selectors/rules.json")
package.loaded["lib.utils"] = {
  native = function()
    return {
      publish = native.publish,
      read = native.read,
      watch = function(path, changed)
        local callback = function(error)
          events = events + 1
          changed(error)
          if not quiescent and not exiting then
            finish()
          end
        end
        weak.watch = callback
        local cancel = assert(native.watch(path, callback))
        return function()
          canceled = canceled + 1
          cancel()
        end
      end,
      process = function(process, executable, changed)
        assert(executable == "/usr/libexec/swcd")
        local callback = function(error)
          changed(error)
          if not quiescent then
            finish()
          end
        end
        weak.process = callback
        local cancel = assert(native.process(process, "/bin/sleep", callback))
        return function()
          stopped = stopped + 1
          cancel()
        end
      end,
    }
  end,
}
environment.hs.json = json
environment.hs.hash.SHA256 = json.hash
environment.hs.host.uuid = function()
  return generation
end
router = assert(loadfile(root .. "/url_router.lua", "t", environment))()
local fixture = {}

function fixture.start(value)
  mode, generation = value, "metadata-" .. value
  events, canceled, stopped, quiescent, exiting = 0, 0, 0, false, false
  weak, logs = setmetatable({}, { __mode = "v" }), {}
  assert(native.publish(state, json.encode({ statusPath = status, phase = "ready" })))
  receipt =
    { version = 1, kind = "ready", generation = "older", sha256 = "older", count = 1, pid = pid }
  if mode == "pending" then
    os.remove(status)
  else
    assert(native.publish(status, json.encode(receipt)))
  end
  assert(router.install({
    {
      host = "ramp.com",
      open = function()
        return true
      end,
    },
  }))
  assert(not router.status().ready and not router.status().error and #logs == 0)
  canceled, stopped = 0, 0
end

function fixture.acknowledge()
  receipt.generation = generation
  receipt.sha256 = json.hash(assert(native.read(selectors)))
  assert(native.publish(status, json.encode(receipt)))
end

function fixture.ready()
  assert(router.status().ready and #logs == 0 and weak.process)
end

function fixture.change()
  local phase = mode == "restored" and "restored" or "uninstalling"
  if mode == "unexpected" or mode == "pending" then
    phase = "ready"
  end
  assert(native.publish(
    state,
    json.encode({
      statusPath = mode == "mismatch" and status .. ".other" or status,
      phase = phase,
    })
  ))
  if mode == "removed" then
    assert(os.remove(state))
  elseif mode == "corrupt" then
    assert(native.publish(state, "{"))
  elseif mode == "deniedState" then
    json.permissions(state, 0)
  end
  if mode == "processCleanup" then
    exiting = true
    return
  elseif mode == "deniedStatus" then
    json.permissions(status, 0)
    assert(native.publish(status .. ".signal", "changed"))
  elseif mode == "pending" then
    assert(native.publish(status .. ".signal", "changed"))
  else
    assert(os.remove(status))
  end
end

local function verify()
  local quiet = mode == "uninstalling"
    or mode == "restored"
    or mode == "removed"
    or mode == "readyCleanup"
    or mode == "processCleanup"
  local value = router.status()
  assert(not value.ready)
  if quiet then
    assert(not value.error and #logs == 0 and canceled == 1)
    assert(stopped == ((mode == "readyCleanup" or mode == "processCleanup") and 1 or 0))
    collectgarbage("collect")
    assert(not weak.watch and not weak.process)
  elseif mode == "pending" then
    assert(not value.error and #logs == 0 and canceled == 0 and weak.watch)
  else
    assert(type(value.error) == "string" and #logs == 1 and canceled == 0 and weak.watch)
    if mode == "corrupt" then
      assert(value.error == "invalid Universal Link installation state")
    elseif mode == "deniedState" or mode == "deniedStatus" then
      assert(value.error:find("Permission denied", 1, true))
    else
      assert(value.error:find("could not read interception status:", 1, true))
    end
  end
  return quiet
end

function fixture.verify()
  assert(events > 0)
  verify()
end

local previous
function fixture.touch()
  previous, quiescent = events, true
  assert(native.publish(status .. ".signal", "another file event"))
end

function fixture.repeated()
  if verify() then
    assert(events == previous)
  else
    assert(events > previous)
  end
  json.permissions(state, 0x180)
  json.permissions(status, 0x180)
  print("PASS actual Lua vnode cleanup/control " .. mode)
end

function fixture.close()
  quiescent = false
  assert(native.publish(state, json.encode({ statusPath = status, phase = "uninstalling" })))
  assert(native.publish(status .. ".signal", "final cleanup"))
end

function fixture.closed()
  assert(not router.status().ready and not router.status().error and #logs == 0 and canceled == 1)
  collectgarbage("collect")
  assert(not weak.watch and not weak.process)
end

return fixture

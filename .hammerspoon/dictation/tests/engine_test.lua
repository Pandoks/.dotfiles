local root, frameworks = assert(arg[1], "pass the dictation directory"), arg[2]
local json = assert(package.loadlib(frameworks .. "/hs/libjson.dylib", "luaopen_hs_libjson"))()
local passed, alerts, output, exit, printed, inputs, ipcDead = 0, {}, nil, nil, {}, {}, false
local terminated, reason, argv

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

local environment = setmetatable({
  print = function(text)
    printed[#printed + 1] = text
    assert(not ipcDead, "ipc port is no longer valid") -- hs.ipc's, with a dead `hs` CLI registered
  end,
  hs = {
    fs = {
      attributes = function()
        return { mode = "file" }
      end,
      temporaryDirectory = function()
        return "/tmp/"
      end,
    },
    host = {
      uuid = function()
        return "UUID"
      end,
    },
    json = json,
    alert = {
      show = function(text)
        alerts[#alerts + 1] = text
      end,
    },
    task = {
      new = function(_, onExit, stream, arguments)
        output, exit, argv = stream, onExit, arguments
        return {
          start = function(self)
            return self
          end,
          isRunning = function()
            return true
          end,
          setInput = function(_, data)
            inputs[#inputs + 1] = json.decode(data)
          end,
          terminate = function()
            terminated = true
          end,
          terminationReason = function()
            return reason
          end,
        }
      end,
    },
  },
}, { __index = _G })
function environment.require(name)
  if name == "lib.toast" then
    return { show = environment.hs.alert.show }
  elseif name == "lib.logger" then
    return assert(loadfile(root .. "/../lib/logger.lua", "t", environment))()
  end
  return require(name)
end
local engine = assert(loadfile(root .. "/engine.lua", "t", environment))()

test("a handler's error is reported and later results are still read", function()
  local finals, failed = {}, {}
  local backend = assert(engine.new({}, {
    onFinal = function(result)
      finals[#finals + 1] = result.id
      if result.id == 1 then
        error("disk full")
      end
    end,
    onError = function(_, id, heard)
      failed[#failed + 1] = id .. heard
      error("no window")
    end,
  }))
  assert(backend and output, "no backend task")
  local lines = '{"event":"ready"}\n{"event":"final","id":1,"text":"a"}\n'
    .. '{"event":"error","id":2,"msg":"no speech","heard":"um"}\n'
  assert(output(nil, lines, "") == true, "stopped reading")
  assert(output(nil, '{"event":"final","id":3,"text":"b"}\n', "") == true, "stopped reading")
  assert(#finals == 2 and finals[2] == 3 and failed[1] == "2um", "a later result was lost")
  assert(alerts[1] and alerts[1]:find("disk full", 1, true), tostring(alerts[1]))
  assert(alerts[2] and alerts[2]:find("no window", 1, true), tostring(alerts[2]))
end)

test("load chatter stays out of the console; what the backend prints once ready goes in", function()
  assert(engine.new({}, { onFinal = function() end, onError = function() end }))
  local feed = assert(output, "no backend task")
  printed = {}
  feed(nil, "", "Downloading: 100%\n")
  feed(nil, '{"event":"ready"}\n', "")
  feed(nil, "", "[WARNING] Generating with a model that requires 9000 MB\n")
  local console = table.concat(printed, "\n")
  assert(not console:find("Downloading", 1, true), "load chatter in the console")
  assert(console:find("requires 9000 MB", 1, true), console)
end)

test("a print that raises leaves later replies read", function()
  local finals = {}
  assert(engine.new({}, {
    onFinal = function(result)
      finals[#finals + 1] = result.id
      error("no window")
    end,
    onError = function() end,
  }))
  local feed = assert(output, "no backend task")
  ipcDead = true
  local ok = pcall(feed, nil, '{"event":"ready"}\n', "Loaded\n")
  local later = ok and pcall(feed, nil, '{"event":"final","id":1,"text":"a"}\n', "warning\n")
  ipcDead = false
  assert(ok and later and #finals == 1, "stopped reading")
end)

test("a long reply is read in one pass", function()
  local finals = {}
  assert(engine.new({}, {
    onFinal = function(result)
      finals[#finals + 1] = #result.text
    end,
    onError = function() end,
  }))
  local line = '{"event":"final","id":1,"text":"' .. ("word "):rep(40000) .. '"}\n'
  local feed, start = assert(output, "no backend task"), os.clock()
  feed(nil, '{"event":"ready"}\n', "")
  feed(nil, line:sub(1, 100000), "")
  feed(nil, line:sub(100001), "")
  assert(finals[1] == 200000 and os.clock() - start < 0.5, ("%.2f s"):format(os.clock() - start))
end)

test("a line waits until the backend has read the one before it, never written over it", function()
  local backend = assert(engine.new({}, { onFinal = function() end, onError = function() end }))
  local feed = assert(output, "no backend task")
  assert(argv[3] == backend.socket and backend.socket:find("^/tmp/dictation%-"), tostring(argv[3]))
  feed(nil, '{"event":"ready"}\n', "")
  inputs = {}
  local first = assert(backend:start(4242, "com.apple.Notes"))
  assert(backend:transcribe(first, "/tmp/a.wav"))
  local second = assert(backend:start(4343))
  assert(first ~= second, "two takes share an id")
  assert(#inputs == 1, "a second line written before the first was read")
  assert(inputs[1].pid == 4242 and inputs[1].app == "com.apple.Notes", "wrong start line")
  feed(nil, '{"event":"final","id":' .. first .. ',"text":"a"}\n', "")
  assert(#inputs == 1, "a reply, not a read, sent the next line")
  feed(nil, '{"event":"rece', "")
  feed(nil, 'ived"}\n', "")
  assert(#inputs == 2 and inputs[2].id == first and inputs[2].wav == "/tmp/a.wav", "lost a line")
  assert(inputs[2].pid == nil and inputs[2].app == nil, "the stop line is not {id, wav}")
  feed(nil, '{"event":"received"}\n', "")
  assert(#inputs == 3 and inputs[3].id == second and inputs[3].pid == 4343, "lost a take")
  feed(nil, '{"event":"received"}\n', "")
  assert(#inputs == 3, "a line sent twice")
  assert(backend:transcribe(second, "/tmp/b.wav") and #inputs == 4, "idle backend kept waiting")
end)

test("a backend that fails, dies, or says something unknown fails once and says why", function()
  for _, case in ipairs({
    { '{"event":"error","msg":"load failed"}\n', "KeyError" }, -- the traceback printed before it
    { '{"event":"ready"}\nTraceback\n', "Traceback" },
    { '{"event":"ready"}\n{"event":"x"}\n', '"x"' },
    { '{"event":"ready"}\n', "KeyError", 1 },
    { '{"event":"ready"}\n', "killed by signal 9", 9, true }, -- SIGKILL, as jetsam sends
  }) do
    local said, why, code, killed = table.unpack(case)
    local failures = {}
    terminated, reason = nil, killed and "interrupt" or "exit"
    local backend = assert(engine.new({}, {
      onFinal = function() end,
      onError = function(message, id)
        failures[#failures + 1] = id or message
      end,
    }))
    local feed, die = assert(output), assert(exit)
    if code then
      feed(nil, said, "")
      die(code, "", "KeyError: 'speech'\n")
    else
      feed(nil, said, "KeyError: 'speech'\n")
    end
    die(1, "", "")
    assert(#failures == 1 and tostring(failures[1]):find(why, 1, true), tostring(failures[1]))
    assert(not backend:start(1, "x"), "a dead backend took a take")
    assert(code or terminated, "the failed backend was left running")
  end
end)

test("a config JSON cannot encode starts no backend and says why", function()
  local backend, problem = engine.new({ minLevel = 0 / 0 }, {})
  assert(not backend and tostring(problem):find("JSON", 1, true), tostring(problem))
end)

print("RESULT " .. passed .. " passed, 0 failed")

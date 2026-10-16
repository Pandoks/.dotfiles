local root, frameworks = assert(arg[1], "pass the dictation directory"), arg[2]
local json = assert(package.loadlib(frameworks .. "/hs/libjson.dylib", "luaopen_hs_libjson"))()
local passed, alerts, output, exit, printed, inputs = 0, {}, nil, nil, {}, {}

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

-- engine.lua with its backend task stubbed: the tests feed the task's output callback.
local engine = assert(loadfile(
  root .. "/engine.lua",
  "t",
  setmetatable({
    require = function(name)
      return name == "dictation.recorder" and { ffmpeg = "/usr/bin/ffmpeg" } or require(name)
    end,
    print = function(text)
      printed[#printed + 1] = text
    end,
    hs = {
      fs = {
        attributes = function()
          return { mode = "file" }
        end,
      },
      json = json,
      alert = {
        show = function(text)
          alerts[#alerts + 1] = text
        end,
      },
      task = {
        new = function(_, onExit, stream)
          output, exit = stream, onExit
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
            terminate = function() end,
          }
        end,
      },
    },
  }, { __index = _G })
))()

test("a handler's error is reported and later results are still read", function()
  local finals, failed = {}, {}
  local backend = assert(engine.new({}, {
    onFinal = function(result)
      finals[#finals + 1] = result.id
      if result.id == 1 then
        error("disk full")
      end
    end,
    onError = function(_, id)
      failed[#failed + 1] = id
      error("no window")
    end,
  }))
  assert(backend and output, "no backend task")
  local lines = '{"event":"ready"}\n{"event":"final","id":1,"text":"a"}\n'
    .. '{"event":"error","id":2,"msg":"no speech"}\n'
  assert(output(nil, lines, "") == true, "stopped reading")
  assert(output(nil, '{"event":"final","id":3,"text":"b"}\n', "") == true, "stopped reading")
  assert(#finals == 2 and finals[2] == 3 and failed[1] == 2, "a later result was lost")
  assert(alerts[1] and alerts[1]:find("disk full", 1, true), tostring(alerts[1]))
  assert(alerts[2] and alerts[2]:find("no window", 1, true), tostring(alerts[2]))
end)

test("what the backend prints once ready reaches the console", function()
  assert(engine.new({}, { onFinal = function() end, onError = function() end }))
  local feed = assert(output, "no backend task")
  printed = {}
  feed(nil, "", "Downloading: 100%\n") -- load chatter
  feed(nil, '{"event":"ready"}\n', "")
  feed(nil, "", "[WARNING] Generating with a model that requires 9000 MB\n")
  local console = table.concat(printed, "\n")
  assert(not console:find("Downloading", 1, true), "load chatter in the console")
  assert(console:find("requires 9000 MB", 1, true), console)
end)

test("a take waits for the one before it, never written over it", function()
  local backend = assert(engine.new({}, { onFinal = function() end, onError = function() end }))
  local feed = assert(output, "no backend task")
  feed(nil, '{"event":"ready"}\n', "")
  inputs = {}
  local first = assert(backend:transcribe("/tmp/a.wav", "com.apple.Notes"))
  local second = assert(backend:transcribe("/tmp/b.wav"))
  local third = assert(backend:transcribe("/tmp/c.wav"))
  assert(#inputs == 1 and inputs[1].id == first, "a second request written before an answer")
  local keys = {}
  for key in pairs(inputs[1]) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  assert(table.concat(keys, " ") == "app id wav", "the request is not {id, wav, app}")
  assert(inputs[1].wav == "/tmp/a.wav" and inputs[1].app == "com.apple.Notes", "wrong request")
  feed(nil, '{"event":"error","id":99,"msg":"stray"}\n', "")
  assert(#inputs == 1, "an answer to another request sent the next")
  feed(nil, '{"event":"final","id":' .. first .. ',"text":"a"}\n', "")
  assert(#inputs == 2 and inputs[2].id == second, "the next request not sent once answered")
  feed(nil, '{"event":"error","id":' .. second .. ',"msg":"no speech"}\n', "")
  assert(#inputs == 3 and inputs[3].id == third and inputs[3].wav == "/tmp/c.wav", "lost a take")
  feed(nil, '{"event":"final","id":' .. third .. ',"text":"c"}\n', "")
  assert(#inputs == 3, "a request sent twice")
  assert(backend:transcribe("/tmp/d.wav") and #inputs == 4, "idle backend kept waiting")
end)

test("a backend that fails, dies, or says something unknown fails once and says why", function()
  for _, case in ipairs({
    { '{"event":"error","msg":"load failed"}\n', "KeyError" }, -- the traceback printed before it
    { '{"event":"ready"}\nTraceback\n', "Traceback" },
    { '{"event":"ready"}\n{"event":"x"}\n', '"x"' },
    { '{"event":"ready"}\n', "KeyError", 1 }, -- exits with code 1
  }) do
    local said, why, code = table.unpack(case)
    local failures = {}
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
    assert(#failures == 1 and tostring(failures[1]):find(why, 1, true), tostring(failures[1]))
    assert(not backend:transcribe("/tmp/x.wav"), "a dead backend took a take")
  end
end)

print(passed .. " engine tests passed")

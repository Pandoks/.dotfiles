local root, frameworks = assert(arg[1], "pass the dictation directory"), arg[2]
local json = assert(package.loadlib(frameworks .. "/hs/libjson.dylib", "luaopen_hs_libjson"))()
local passed, alerts, output = 0, {}, nil

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
    print = function() end,
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
        new = function(_, _, stream)
          output = stream
          return {
            start = function(self)
              return self
            end,
            isRunning = function()
              return true
            end,
            setInput = function() end,
            terminate = function() end,
          }
        end,
      },
    },
  }, { __index = _G })
))()

test("a handler's error is reported and later results are still read", function()
  local finals = {}
  local backend = assert(engine.new({ stt = {}, cleanup = {} }, {
    onFinal = function(result)
      finals[#finals + 1] = result.id
      if result.id == 1 then
        error("disk full")
      end
    end,
    onError = function() end,
  }))
  assert(backend and output, "no backend task")
  local lines = '{"event":"ready"}\n{"event":"final","id":1,"text":"a"}\n'
  assert(output(nil, lines, "") == true, "stopped reading")
  assert(output(nil, '{"event":"final","id":2,"text":"b"}\n', "") == true, "stopped reading")
  assert(#finals == 2 and finals[2] == 2, "the second result was lost")
  assert(alerts[1] and alerts[1]:find("disk full", 1, true), tostring(alerts[1]))
end)

print(passed .. " engine tests passed")

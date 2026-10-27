local root, scratch = arg[1], arg[3]
local passed, rest, slept = 0, "", 0
local task, receive

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

-- recorder.lua with ffmpeg and the native stream as stubs to drive.
local stream = {
  listen = function(_, callback)
    receive = callback
    return function()
      local left = rest
      rest = ""
      return left
    end
  end,
}
local hs = {
  fs = {
    temporaryDirectory = function()
      return scratch .. "/"
    end,
    pathToAbsolute = function() end,
  },
  timer = {
    usleep = function(microseconds)
      slept = slept + microseconds
    end,
  },
  host = {
    uuid = function()
      return "take"
    end,
  },
  task = {
    new = function(_, exit, output)
      task = { exit = exit, stream = output, interrupts = 0, polls = 0, running = 0 }
      function task.start()
        return true
      end
      function task.interrupt()
        task.interrupts = task.interrupts + 1
      end
      function task.isRunning()
        task.polls = task.polls + 1
        return task.polls <= task.running
      end
      function task.terminate()
        task.terminated = true
      end
      return task
    end,
  },
}
local recorder = assert(loadfile(
  root .. "/recorder.lua",
  "t",
  setmetatable({
    hs = hs,
    require = function()
      return {
        native = function()
          return stream
        end,
      }
    end,
  }, { __index = _G })
))()

-- `count` samples of a 440 Hz sine at `amplitude` (0..1), as s16le.
local function pcm(amplitude, count)
  local samples = {}
  for i = 1, count do
    samples[i] =
      string.pack("<i2", math.floor(amplitude * 32767 * math.sin(i * 2 * math.pi * 440 / 16000)))
  end
  return table.concat(samples)
end

test("a frame shows bands only once a full window has streamed, and only for new audio", function()
  local recording = assert(recorder.start(8, error))
  receive(pcm(0.5, 512))
  assert(recorder.analyze(recording) == nil, "bands before a full window")
  receive(pcm(0.5, 1024))
  local bands = assert(recorder.analyze(recording), "no bands for a full window")
  assert(#bands == 8, #bands)
  for _, band in ipairs(bands) do
    assert(band >= 0 and band <= 1, band)
  end
  -- 440 Hz fills its band (437-781 Hz) and leaves the highest dim.
  assert(bands[4] > 0.9 and bands[8] < 0.2, table.concat(bands, " "))
  assert(recorder.analyze(recording) == nil, "bands with nothing new")
end)

test("every window since the last frame, and audio unread at exit, counts", function()
  local recording = assert(recorder.start(8, error))
  local peak, duration
  receive(pcm(0, 16000))
  recorder.analyze(recording)
  rest = pcm(0.5, 1024) .. pcm(0, 3072)
  recorder.stop(recording, function(_, loudest, seconds)
    peak, duration = loudest, seconds
  end)
  task.exit(255, "", "")
  assert(peak == 1 and duration == 20096 / 16000, ("%s %s"):format(peak, duration))
end)

test("cleanup deletes the recording and cancels a stop still waiting on ffmpeg", function()
  local recording, sent = assert(recorder.start(8, error)), false
  assert(io.open(recording.wav, "w")):close()
  recorder.stop(recording, function()
    sent = true
  end)
  recorder.cleanup(recording)
  assert(not io.open(recording.wav), "the recording is left") -- a reload skips the exit callback
  task.exit(255, "", "")
  assert(not sent and task.terminated, "the cancelled take was sent, or ffmpeg left recording")
end)

test("finalize waits for ffmpeg to finish the wav, signalling it once, for up to 2 s", function()
  for _, case in ipairs({
    { stopped = true, running = 3, finished = true },
    { stopped = false, running = 3, finished = true },
    { stopped = false, running = 1000, finished = false },
  }) do
    local running = case.running
    local recording, sent = assert(recorder.start(8, error)), false
    if case.stopped then
      recorder.stop(recording, function()
        sent = true
      end)
    end
    task.running, slept = running, 0
    assert(recorder.finalize(recording) == case.finished, "finished")
    task.exit(255, "", "")
    assert(task.interrupts == 1 and not sent, "signalled twice or sent")
    assert(slept == math.min(running, 200) * 10000, ("%d us asleep"):format(slept))
  end
end)

test("ffmpeg failing or ending unasked fails the take once and deletes its wav", function()
  for _, case in ipairs({
    { "No such device\n", 1, "", "No such device" }, -- while recording
    { "", 1, "Error opening input\n", "Error opening input" }, -- as it exits
    { "", 0, "", "capture exited (code 0)" },
  }) do
    local live, code, last, want = table.unpack(case)
    local failures = {}
    local recording = assert(recorder.start(8, function(problem)
      failures[#failures + 1] = problem
    end))
    assert(io.open(recording.wav, "w")):close()
    task.stream(nil, "", live)
    task.exit(code, "", last)
    assert(#failures == 1 and failures[1] == want, table.concat(failures, "; "))
    assert(not io.open(recording.wav), "the recording is left")
  end
end)

test("ffmpeg's output after it exits fails nothing", function()
  local failed
  local recording = assert(recorder.start(8, function(problem)
    failed = problem
  end))
  recorder.stop(recording, function() end)
  task.exit(255, "", "")
  task.stream(nil, "", "Broken pipe\n")
  assert(failed == nil, tostring(failed))
end)

test("a stream failure fails the take through onError", function()
  local message
  assert(recorder.start(8, function(problem)
    message = problem
  end))
  receive(nil, "could not read the stream: Broken pipe")
  assert(message == "could not read the stream: Broken pipe", tostring(message))
end)

test("a socket it can't listen on fails the take before an ffmpeg task exists", function()
  local listen, created = stream.listen, task
  stream.listen = function()
    return nil, "socket path too long"
  end
  local recording, problem = recorder.start(8, error)
  stream.listen = listen
  assert(not recording and problem == "socket path too long", tostring(problem))
  assert(task == created, "an unstarted ffmpeg task leaks its pipes")
end)

print("RESULT " .. passed .. " passed, 0 failed")

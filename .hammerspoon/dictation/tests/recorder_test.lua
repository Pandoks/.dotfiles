local root, scratch = arg[1], arg[3]
local passed, rest, sleeps = 0, "", 0
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
    usleep = function()
      sleeps = sleeps + 1
    end,
  },
  host = {
    uuid = function()
      return "take"
    end,
  },
  task = {
    new = function(_, exit, stream)
      task = { exit = exit, stream = stream, interrupts = 0, polls = 0, running = 0 }
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
      function task.terminate() end
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
  assert(recorder.analyze(recording) == nil, "bands with nothing new")
end)

test("every window streamed between frames counts toward the peak", function()
  local recording = assert(recorder.start(8, error))
  receive(pcm(0.5, 1024) .. pcm(0, 3072))
  recorder.analyze(recording)
  assert(recording.peak == 1, recording.peak)
end)

test("audio still unread when ffmpeg exits counts in the duration and peak", function()
  local recording = assert(recorder.start(8, error))
  local peak, duration
  receive(pcm(0, 16000))
  recorder.analyze(recording)
  rest = pcm(0.5, 1024)
  recorder.stop(recording, function(_, loudest, seconds)
    peak, duration = loudest, seconds
  end)
  task.exit(255, "", "")
  assert(peak == 1 and duration == 17024 / 16000, ("%s %s"):format(peak, duration))
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
  assert(not sent, "the cancelled take was sent")
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
    task.running, sleeps = running, 0
    assert(recorder.finalize(recording) == case.finished, "finished")
    task.exit(255, "", "")
    assert(task.interrupts == 1 and not sent, "signalled twice or sent")
    assert(sleeps == math.min(running, 200), ("%d sleeps"):format(sleeps))
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

print(passed .. " recorder tests passed")

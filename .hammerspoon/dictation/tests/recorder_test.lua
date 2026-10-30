local root, scratch = arg[1], arg[3]
local passed, undelivered = 0, ""
local backend = scratch .. "/backend.sock"
local task, receive

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

local stream = {
  listen = function(_, callback)
    receive = callback
    return function()
      local left = undelivered
      undelivered = ""
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
  host = {
    uuid = function()
      return "take"
    end,
  },
  task = {
    new = function(_, exit, output, arguments)
      task = { exit = exit, stream = output, running = false, arguments = arguments }
      function task.start()
        return true
      end
      function task.pid()
        return 4242
      end
      function task.interrupt() end
      function task.isRunning()
        return task.running
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

local function pcm(amplitude, count)
  local samples = {}
  for sample = 1, count do
    samples[sample] = string.pack(
      "<i2",
      math.floor(amplitude * 32767 * math.sin(sample * 2 * math.pi * 440 / 16000))
    )
  end
  return table.concat(samples)
end

test("a frame shows bands only once a full window has streamed, and only for new audio", function()
  local recording, sine = assert(recorder.start(8, backend, error)), pcm(0.5, 1024)
  receive(sine:sub(1, 1024))
  assert(recorder.analyze(recording) == nil, "bands before a full window")
  receive(sine:sub(1025))
  local bands = assert(recorder.analyze(recording), "no bands for a full window")
  assert(#bands == 8, #bands)
  for _, band in ipairs(bands) do
    assert(band >= 0 and band <= 1, band)
  end
  -- 440 Hz fills its band (437-781 Hz) and leaves the highest dim.
  assert(bands[4] > 0.9 and bands[8] < 0.2, table.concat(bands, " "))
  assert(recorder.analyze(recording) == nil, "bands with nothing new")
end)

test("the bars follow the room: flat once it is steady, up for quiet speech over it", function()
  local recording = assert(recorder.start(8, backend, error))
  receive(pcm(0.01, 1024))
  for _, band in ipairs(assert(recorder.analyze(recording), "no bands")) do
    assert(band == 0, band)
  end
  receive(pcm(0.005, 1024)) -- a quieter moment: the floor falls to it
  for _ = 1, 150 do -- 5 s of frames in the room: the floor rises back
    recorder.analyze(recording)
    receive(pcm(0.01, 1024))
  end
  assert(recorder.analyze(recording)[4] == 0, "the bars stayed up in a steady room")
  receive(pcm(0.02, 1024)) -- 6 dB over the room
  assert(recorder.analyze(recording)[4] > 0, "quiet speech left the bars flat")
end)

test("every window since the last frame, and audio unread at exit, counts", function()
  -- A 0.05 sine is -29 dBFS: 0.52 on minLevel's -50..-10 dBFS scale.
  for _, unread in ipairs({ pcm(0.05, 1024) .. pcm(0, 3072), pcm(0, 3072) .. pcm(0.05, 1024) }) do
    local recording = assert(recorder.start(8, backend, error))
    local peak, duration
    receive(pcm(0, 16000))
    recorder.analyze(recording)
    undelivered = unread
    recorder.stop(recording, function(_, loudest, seconds)
      peak, duration = loudest, seconds
    end)
    task.exit(255, "", "")
    assert(peak > 0.5 and peak < 0.55, peak)
    assert(duration == 20096 / 16000, duration)
  end
end)

test("cleanup kills ffmpeg, cancels a stop, and deletes the wav unless kept with audio", function()
  for _, case in ipairs({ { false, pcm(0.5, 1024) }, { true, "" }, { true, pcm(0.5, 1024) } }) do
    local recording, sent = assert(recorder.start(8, backend, error)), false
    local asked, audio = table.unpack(case)
    local kept = asked and audio ~= ""
    -- ffmpeg whose input stopped delivering: it ignores SIGINT and SIGTERM.
    local deaf =
      assert(io.popen("trap '' INT TERM; sleep 5 & echo $!; wait $! 2>/dev/null; echo $?"))
    local pid = deaf:read("l")
    function task.pid()
      return pid
    end
    task.running = true
    local function left()
      local file = io.open(recording.wav)
      return file ~= nil and file:close()
    end
    assert(io.open(recording.wav, "w")):close()
    receive(audio)
    recorder.analyze(recording)
    recorder.stop(recording, function()
      sent = true
    end)
    recorder.cleanup(recording, asked)
    assert(left() == kept, "the wav") -- a reload skips the exit callback
    task.exit(9, "", "")
    assert(left() == kept and not sent, "the cancelled take was sent, or the kept wav deleted")
    assert(deaf:read("l") == "137" and deaf:close(), "ffmpeg left recording") -- 128 + SIGKILL
  end
end)

test("ffmpeg failing or ending unasked fails the take once", function()
  for _, case in ipairs({
    { "No such device\n", 1, "", "No such device" }, -- while recording
    { "", 1, "Error opening input\n", "Error opening input" }, -- as it exits
    { "", 0, "", "capture exited (code 0)" },
  }) do
    local live, code, last, want = table.unpack(case)
    local failures = {}
    assert(recorder.start(8, backend, function(problem)
      failures[#failures + 1] = problem
    end))
    task.stream(nil, "", live)
    task.exit(code, "", last)
    assert(#failures == 1 and failures[1] == want, table.concat(failures, "; "))
  end
end)

test("ffmpeg's output after it exits fails nothing", function()
  local failed
  local recording = assert(recorder.start(8, backend, function(problem)
    failed = problem
  end))
  recorder.stop(recording, function() end)
  task.exit(255, "", "")
  task.stream(nil, "", "Broken pipe\n")
  assert(failed == nil, tostring(failed))
end)

test("a stream failure fails the take through onError", function()
  local message
  assert(recorder.start(8, backend, function(problem)
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
  local recording, problem = recorder.start(8, backend, error)
  stream.listen = listen
  assert(not recording and problem == "socket path too long", tostring(problem))
  assert(task == created, "an unstarted ffmpeg task leaks its pipes")
end)

test("ffmpeg streams the backend exactly the audio it writes to the wav", function()
  local recording = assert(recorder.start(8, backend, error))
  assert(recording.pid == 4242, "the take is not paired with its ffmpeg")
  -- The real arguments, with a 48 kHz tone for the microphone, SIGINT after 1 s as a stop.
  local command = { "ffmpeg", "-re" }
  for _, argument in ipairs(task.arguments) do
    argument = ({ avfoundation = "lavfi", [":default"] = "sine=frequency=440:sample_rate=48000" })[argument]
      or argument
    command[#command + 1] = "'" .. argument:gsub("'", "'\\''") .. "'"
  end
  local equalizer = recording.wav:gsub("%.wav$", ".sock")
  os.remove(recording.wav)
  local script = [[cd %q
nc -lU %q > eq.pcm 2> /dev/null < /dev/null & first=$!
nc -lU %q > backend.pcm 2> /dev/null < /dev/null & second=$!
sleep 0.3
%s & sleep 1; kill -INT $!; wait $!
sleep 0.3; kill $first $second 2> /dev/null; true]]
  assert(os.execute(script:format(scratch, equalizer, backend, table.concat(command, " "))))
  local function read(path)
    local file = assert(io.open(path, "rb"))
    local data = file:read("a")
    file:close()
    return data
  end
  local wav, streamed = read(recording.wav), read(scratch .. "/backend.pcm")
  local data = assert(wav:find("data", 13, true), "no data chunk")
  assert(#streamed > 16000, "the backend got " .. #streamed .. " bytes")
  assert(
    wav:sub(data + 8) == streamed,
    ("wav %d bytes, stream %d"):format(#wav - data - 7, #streamed)
  )
end)

print("RESULT " .. passed .. " passed, 0 failed")

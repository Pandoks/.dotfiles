---@class DictationRecorderOptions
---@field config DictationConfig
---@field onBars? fun(bands: number[])
---@field onError fun(message: string)

---@class DictationRecording
---@field wav string
---@field peak number
---@field started number
---@field buffer string
---@field task? hs.task
---@field finished? boolean
---@field stopping? boolean
---@field discarded? boolean
---@field error? string
---@field duration? number
---@field deadline? hs.timer
---@field done? fun(wav: string?, peak: number, duration: number)

local recorder = {}
local directory = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"

---@param options DictationRecorderOptions
---@return DictationRecording?, string?
function recorder.start(options)
  local paths = {
    os.getenv("HOME") .. "/.local/share/mise/installs/ffmpeg/latest/.mise-bins",
    "/opt/homebrew/bin",
    "/usr/local/bin",
  }
  for path in (os.getenv("PATH") or ""):gmatch("[^:]+") do
    paths[#paths + 1] = path
  end
  local ffmpeg
  for _, path in ipairs(paths) do
    if hs.fs.attributes(path .. "/ffmpeg", "mode") == "file" then
      ffmpeg = path .. "/ffmpeg"
      break
    end
  end
  if not ffmpeg then
    return nil, "ffmpeg unavailable"
  end
  local python = directory .. ".venv/bin/python"
  if not hs.fs.attributes(python) then
    return nil, "backend venv missing; run dictation/setup.sh"
  end

  local wav = os.tmpname()
  local highpass = "highpass=f=90"
  local filter = highpass
  if options.config.noiseReduction then
    filter = highpass
      .. ",afftdn=nf=-25,silenceremove="
      .. "start_periods=1:start_threshold=-40dB:start_silence=0.1:"
      .. "stop_periods=-1:stop_threshold=-40dB:stop_silence=0.2"
  end
  ---@type DictationRecording
  local recording =
    { wav = wav, peak = 0, started = assert(hs.timer.secondsSinceEpoch()), buffer = "" }
  local function failure(message)
    if recording.error or recording.discarded then
      return
    end
    recording.error = message
    options.onError(message)
  end
  local function stream(_, output, errors)
    if recording.finished or recording.discarded then
      return true
    end
    if errors and errors ~= "" then
      failure(errors:gsub("%s+$", ""))
    end
    recording.buffer = recording.buffer .. (output or "")
    while true do
      local newline = recording.buffer:find("\n")
      if not newline then
        break
      end
      local line = recording.buffer:sub(1, newline - 1)
      recording.buffer = recording.buffer:sub(newline + 1)
      local ok, frame = pcall(hs.json.decode, line)
      if
        not ok
        or type(frame) ~= "table"
        or type(frame.l) ~= "number"
        or type(frame.b) ~= "table"
      then
        failure("invalid audio meter response")
        return true
      end
      recording.peak = math.max(recording.peak, frame.l)
      if options.onBars then
        options.onBars(frame.b)
      end
    end
    return true
  end
  local task = hs.task.new(
    python,
    function(code, output, errors)
      stream(nil, output, errors)
      recording.finished = true
      if recording.deadline then
        recording.deadline:stop()
      end
      if code ~= 0 or not recording.stopping then
        failure("capture exited (code " .. tostring(code) .. ")")
      end
      if recording.discarded or recording.error then
        os.remove(wav)
      end
      if recording.done then
        recording.done(
          not recording.error and not recording.discarded and wav or nil,
          recording.peak,
          recording.duration or hs.timer.secondsSinceEpoch() - recording.started
        )
      end
    end,
    stream,
    {
      directory .. "analyzer.py",
      "--bands",
      tostring(options.config.eqBands),
      "--capture",
      ffmpeg,
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "avfoundation",
      "-i",
      ":default",
      "-filter:a",
      filter,
      "-ac",
      "1",
      "-ar",
      "16000",
      "-y",
      "-f",
      "wav",
      wav,
      "-filter:a",
      highpass,
      "-f",
      "s16le",
      "-ac",
      "1",
      "-ar",
      "16000",
      "pipe:1",
    }
  )
  if not task then
    os.remove(wav)
    return nil, "could not create capture task"
  end
  recording.task = task
  if not task:start() then
    os.remove(wav)
    return nil, "could not start capture task"
  end
  return recording
end

---@param recording DictationRecording
---@param done fun(wav: string?, peak: number, duration: number)
function recorder.stop(recording, done)
  if recording.stopping then
    return
  end
  recording.stopping, recording.done = true, done
  recording.duration = hs.timer.secondsSinceEpoch() - recording.started
  if recording.finished then
    done(nil, recording.peak, hs.timer.secondsSinceEpoch() - recording.started)
    return
  end
  -- The completion callback runs only after ffmpeg has finalized the WAV.
  recording.task:setInput("q\n")
  recording.deadline = hs.timer.doAfter(2, function()
    recording.error = "timed out stopping microphone capture"
    recording.task:terminate()
    done(nil, recording.peak, hs.timer.secondsSinceEpoch() - recording.started)
    recording.done = nil
  end)
end

---@param recording? DictationRecording
function recorder.cleanup(recording)
  if not recording then
    return
  end
  recording.discarded, recording.done = true, nil
  if recording.deadline then
    recording.deadline:stop()
  end
  if recording.finished then
    os.remove(recording.wav)
  elseif recording.task then
    recording.task:terminate()
  end
end

return recorder

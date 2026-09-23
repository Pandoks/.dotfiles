-- Microphone capture. hs.task owns one ffmpeg process on the system's current
-- default input, writing two outputs: the cleaned 16 kHz wav for the speech
-- model, and a raw PCM file (flushed per packet) that `poll()` reads for the
-- equalizer. Audio goes through a file rather than a pipe because Hammerspoon
-- decodes task output as UTF-8 text (dropping PCM bytes) and io.popen would
-- block the main thread; a page-cached read costs ~13 µs per frame.
--
-- Hammerspoon has no native recording API; ffmpeg's microphone access is
-- attributed to Hammerspoon (grant it in Privacy & Security > Microphone).

local Spectrum = require("dictation.spectrum")

---@class DictationRecorderOptions
---@field config DictationConfig
---@field onError fun(message: string)

---@class DictationRecording
---@field wav string output wav path
---@field pcm string raw PCM path read by poll()
---@field offset integer bytes of pcm consumed so far
---@field tail string most recent PCM bytes (one analysis window)
---@field spectrum DictationSpectrum
---@field peak number highest level (0..1) seen so far
---@field started number epoch seconds when capture started
---@field task hs.task
---@field finished? boolean
---@field stopping? boolean
---@field discarded? boolean
---@field error? string
---@field duration? number
---@field done? fun(wav: string?, peak: number, duration: number)

local recorder = {}

local RATE = 16000
local SIZE = 1024

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

  local base = os.tmpname()
  os.remove(base) -- tmpname creates the file; only the suffixed paths are used
  local wav, pcm = base .. ".wav", base .. ".pcm"
  local highpass = "highpass=f=90"
  local filter = highpass
  if options.config.noiseReduction then
    filter = highpass
      .. ",afftdn=nf=-25,silenceremove="
      .. "start_periods=1:start_threshold=-40dB:start_silence=0.1:"
      .. "stop_periods=-1:stop_threshold=-40dB:stop_silence=0.2"
  end
  ---@type DictationRecording
  local recording = {
    wav = wav,
    pcm = pcm,
    offset = 0,
    tail = "",
    spectrum = Spectrum.new(RATE, options.config.eqBands, SIZE),
    peak = 0,
    started = assert(hs.timer.secondsSinceEpoch()),
    task = nil, ---@diagnostic disable-line: assign-type-mismatch -- assigned below
  }
  local function failure(message)
    if recording.error or recording.discarded then
      return
    end
    recording.error = message
    options.onError(message)
  end
  local task = hs.task.new(ffmpeg, function(code, _, errors)
    recording.finished = true
    if errors and errors ~= "" then
      failure((errors:gsub("%s+$", "")))
    elseif not recording.stopping or (code ~= 0 and code ~= 255) then
      failure("capture exited (code " .. tostring(code) .. ")")
    end
    os.remove(pcm)
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
  end, {
    "-hide_banner", "-loglevel", "error", "-nostdin",
    "-f", "avfoundation", "-i", ":default",
    "-filter:a", filter, "-ac", "1", "-ar", tostring(RATE), "-y", "-f", "wav", wav,
    "-filter:a", highpass, "-f", "s16le", "-ac", "1", "-ar", tostring(RATE),
    "-flush_packets", "1", "-y", pcm,
  })
  if not task then
    return nil, "could not create capture task"
  end
  recording.task = task
  if not task:start() then
    return nil, "could not start capture task"
  end
  return recording
end

-- Read any new PCM and analyze the latest window. Call on the animation tick.
---@param recording DictationRecording
---@return number[]? bands nil until a full window of audio exists
function recorder.poll(recording)
  if recording.finished or recording.discarded then
    return nil
  end
  local file = io.open(recording.pcm, "rb")
  if not file then
    return nil
  end
  file:seek("set", recording.offset)
  local new = file:read("a") or ""
  file:close()
  if #new == 0 then
    return nil
  end
  recording.offset = recording.offset + #new
  recording.tail = (recording.tail .. new):sub(-SIZE * 2)
  if #recording.tail < SIZE * 2 then
    return nil
  end
  local bands, level = recording.spectrum:analyze(recording.tail)
  recording.peak = math.max(recording.peak, level)
  return bands
end

-- Stop capture. SIGINT lets ffmpeg finalize the wav; the completion callback
-- then delivers the path (nil on failure), peak level, and duration.
---@param recording DictationRecording
---@param done fun(wav: string?, peak: number, duration: number)
function recorder.stop(recording, done)
  if recording.stopping then
    return
  end
  recording.stopping, recording.done = true, done
  recording.duration = hs.timer.secondsSinceEpoch() - recording.started
  if recording.finished then
    done(nil, recording.peak, recording.duration)
    return
  end
  recording.task:interrupt()
end

---@param recording? DictationRecording
function recorder.cleanup(recording)
  if not recording then
    return
  end
  recording.discarded, recording.done = true, nil
  if recording.finished then
    os.remove(recording.wav)
    os.remove(recording.pcm)
  else
    recording.task:terminate()
  end
end

return recorder

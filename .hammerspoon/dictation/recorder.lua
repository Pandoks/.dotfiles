local Spectrum = require("dictation.spectrum")

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

local rate = 16000
local size = 1024

-- First ffmpeg on mise, Homebrew, or PATH; the backend also needs it on its PATH.
local path = table.concat({
  os.getenv("HOME") .. "/.local/share/mise/installs/ffmpeg/latest/.mise-bins",
  "/opt/homebrew/bin",
  "/usr/local/bin",
  os.getenv("PATH") or "",
}, ":")
local ffmpeg
for directory in path:gmatch("[^:]+") do
  if hs.fs.attributes(directory .. "/ffmpeg", "mode") == "file" then
    ffmpeg = directory .. "/ffmpeg"
    break
  end
end
recorder.ffmpeg = ffmpeg

---@param bands integer equalizer bands
---@param onError fun(message: string)
---@return DictationRecording?, string?
function recorder.start(bands, onError)
  if not ffmpeg then
    return nil, "ffmpeg unavailable"
  end
  local base = os.tmpname()
  os.remove(base) -- tmpname creates the file; only the suffixed paths are used
  local wav, pcm = base .. ".wav", base .. ".pcm"
  -- High-pass only: denoise and silence trimming erase quiet speakers.
  local highpass = "highpass=f=90"
  ---@type DictationRecording
  local recording
  local function failure(message)
    if recording.error or recording.discarded then
      return
    end
    recording.error = message
    onError(message)
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
    "-hide_banner",
    "-loglevel",
    "error",
    "-nostdin",
    "-f",
    "avfoundation",
    "-i",
    ":default",
    "-filter:a",
    highpass,
    "-ac",
    "1",
    "-ar",
    tostring(rate),
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
    tostring(rate),
    "-flush_packets",
    "1",
    "-y",
    pcm,
  })
  if not task then
    return nil, "could not create capture task"
  end
  recording = {
    wav = wav,
    pcm = pcm,
    offset = 0,
    tail = "",
    spectrum = Spectrum.new(rate, bands, size),
    peak = 0,
    started = assert(hs.timer.secondsSinceEpoch()),
    task = task,
  }
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
  recording.tail = (recording.tail .. new):sub(-size * 2)
  if #recording.tail < size * 2 then
    return nil
  end
  local bands, level = recording.spectrum:analyze(recording.tail)
  recording.peak = math.max(recording.peak, level)
  return bands
end

-- SIGINT lets ffmpeg finalize the wav before `done` gets it (nil on failure).
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

local Spectrum = require("dictation.spectrum")

---@class DictationRecording
---@field wav string output wav path
---@field pcm string raw PCM path read by poll()
---@field offset integer bytes of pcm consumed so far
---@field tail string most recent PCM bytes (one analysis window)
---@field spectrum DictationSpectrum
---@field peak number highest level (0..1) seen so far
---@field task? hs.task nil once ffmpeg exits
---@field stopping? boolean
---@field discarded? boolean
---@field error? string
---@field done? fun(wav: string, peak: number, duration: number)

local recorder = {}

local rate = 16000
local size = 1024

-- First ffmpeg on mise (the one its shim runs, wherever MISE_DATA_DIR puts it), Homebrew, or
-- PATH; the backend also needs it on its PATH. The shim is resolved once here: run on every take,
-- it would add ~15 ms before the mic opens.
local mise = os.getenv("MISE_DATA_DIR") or os.getenv("HOME") .. "/.local/share/mise"
local binary = hs.fs.pathToAbsolute(mise .. "/shims/ffmpeg") -- the shim links to mise itself
local which = binary and hs.execute(("cd / && '%s' which ffmpeg"):format(binary)) or ""
local path = table.concat({
  which:match("^(/.*)/ffmpeg%s*$") or mise .. "/installs/ffmpeg/latest/.mise-bins",
  "/opt/homebrew/bin",
  "/usr/local/bin",
  os.getenv("PATH"),
}, ":")
local ffmpeg
for directory in path:gmatch("[^:]+") do
  if hs.fs.attributes(directory .. "/ffmpeg", "mode") == "file" then
    ffmpeg = directory .. "/ffmpeg"
    break
  end
end
recorder.ffmpeg = ffmpeg

-- Per-user 0700 temp dir, not the shared /tmp.
local temporary = hs.fs.temporaryDirectory()
-- Reload and quit remove their takes; anything left here is from a crash.
for entry in hs.fs.dir(temporary) do
  local extension = entry:match("^dictation%-[%x%-]+%.(%a+)$")
  if extension == "wav" or extension == "pcm" then
    os.remove(temporary .. entry)
  end
end

---@param bands integer equalizer bands
---@param onError fun(message: string)
function recorder.start(bands, onError)
  local base = temporary .. "dictation-" .. hs.host.uuid()
  local wav, pcm = base .. ".wav", base .. ".pcm"
  -- High-pass only: denoise and silence trimming erase quiet speakers.
  local highpass = "highpass=f=90"
  ---@type DictationRecording
  local recording
  local function failure(message)
    message = message:gsub("%s+$", "")
    if message == "" or recording.error or recording.discarded then
      return
    end
    recording.error, recording.done = message, nil
    onError(message)
  end
  -- sh execs ffmpeg in its place; its child SIGINTs ffmpeg when stdin closes (Hammerspoon exited).
  local watchdog = 'exec 3<&0; (read _ <&3; kill -INT $$) >/dev/null 2>&1 & exec "$0" "$@" 3<&-'
  local task = hs.task.new("/bin/sh", function(code, _, errors)
    recording.task = nil -- frees the task, which holds these callbacks
    failure(errors or "")
    if not recording.stopping or (code ~= 0 and code ~= 255) then
      failure("capture exited (code " .. tostring(code) .. ")")
    end
    -- The last chunk arrives after the final tick: count it in the duration and peak.
    if recording.done then
      recorder.poll(recording)
    end
    os.remove(pcm)
    if recording.discarded or recording.error then
      os.remove(wav)
    end
    if recording.done then
      recording.done(wav, recording.peak, recording.offset / (2 * rate))
    end
  end, function(_, _, errors)
    failure(errors or "") -- a streaming task keeps stdin open
    return true
  end, {
    "-c",
    watchdog,
    ffmpeg,
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
  local data = recording.tail .. new
  recording.tail = data:sub(-size * 2)
  if #recording.tail < size * 2 then
    return nil
  end
  -- Every window since the last tick counts toward the peak, not only the one shown: a busy
  -- main thread can leave several.
  for last = #data, size * 2, -size * 2 do
    local level = recording.spectrum:loudness(data, last - size * 2 + 1)
    recording.peak = math.max(recording.peak, level)
  end
  return (recording.spectrum:analyze(recording.tail))
end

-- SIGINT lets ffmpeg finalize the wav; `done` gets it and the seconds polled (failures: onError).
---@param recording DictationRecording
---@param done fun(wav: string, peak: number, duration: number)
function recorder.stop(recording, done)
  recording.stopping, recording.done = true, done
  assert(recording.task):interrupt()
end

---@param recording? DictationRecording
function recorder.cleanup(recording)
  if not recording then
    return
  end
  recording.discarded, recording.done = true, nil
  if recording.task then
    recording.task:terminate()
  end
  -- Remove now; a reload skips the exit callback (unlinking is safe while ffmpeg writes).
  os.remove(recording.wav)
  os.remove(recording.pcm)
end

return recorder

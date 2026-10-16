---@class DictationRecording
---@field wav string
---@field pcm string raw copy read by poll()
---@field offset integer bytes of pcm read so far
---@field tail string the latest analysis window
---@field peak number loudest window so far (0..1)
---@field peaks number[] per-band slow-decaying maximum, for auto-gain
---@field floor? number room loudness (0..1): falls instantly, rises slowly
---@field bins integer[] band edges in FFT bins, 0..bands
---@field task? hs.task nil once ffmpeg exits
---@field stopping? boolean
---@field discarded? boolean cancelled or failed: its wav is deleted
---@field done? fun(wav: string, peak: number, duration: number)

local recorder = {}

local rate = 16000
local size = 1024 -- FFT window, in samples

-- Hann window.
local window = {}
for i = 1, size do
  window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (size - 1))
end

-- mise's own binary, through its ffmpeg shim (a symlink): resolved once, as the shim adds ~15 ms.
local mise = hs.fs.pathToAbsolute(os.getenv("HOME") .. "/.local/share/mise/shims/ffmpeg")
local which = mise and hs.execute(("cd / && '%s' which ffmpeg"):format(mise)) --[[@as string?]]
recorder.ffmpeg = which and which:match("^(/.*/ffmpeg)%s*$")

-- In-place iterative radix-2 FFT.
---@param real number[]
---@param imaginary number[]
local function fft(real, imaginary)
  local n = #real
  local j = 1
  for i = 1, n - 1 do
    if i < j then
      real[i], real[j] = real[j], real[i]
      imaginary[i], imaginary[j] = imaginary[j], imaginary[i]
    end
    local m = n // 2
    while m >= 1 and j > m do
      j = j - m
      m = m // 2
    end
    j = j + m
  end
  local span = 2
  while span <= n do
    local angle = -2 * math.pi / span
    local wr, wi = math.cos(angle), math.sin(angle)
    for start = 1, n, span do
      local cr, ci = 1, 0
      for k = 0, span // 2 - 1 do
        local a, b = start + k, start + k + span // 2
        local tr = real[b] * cr - imaginary[b] * ci
        local ti = real[b] * ci + imaginary[b] * cr
        real[b], imaginary[b] = real[a] - tr, imaginary[a] - ti
        real[a], imaginary[a] = real[a] + tr, imaginary[a] + ti
        cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
      end
    end
    span = span * 2
  end
end

-- Samples (-1..1) of the window starting at byte `from`, and its loudness 0..1 (-50..-10 dBFS).
---@param pcm string s16le mono
---@param from integer
local function samples(pcm, from)
  local values, energy = {}, 0
  for i = 1, size do
    local value = string.unpack("<i2", pcm, from + 2 * i - 2) / 32768
    values[i], energy = value, energy + value * value
  end
  local rms = math.sqrt(energy / size) + 1e-9
  return values, math.max(0, math.min(1, (20 * math.log(rms, 10) + 50) / 40)), energy
end

---@param bands integer equalizer bands
---@param onError fun(message: string)
function recorder.start(bands, onError)
  -- Per-user 0700 temp dir, not the shared /tmp.
  local base = hs.fs.temporaryDirectory() .. "dictation-" .. hs.host.uuid()
  local wav, pcm = base .. ".wav", base .. ".pcm"
  -- High-pass only: denoise and silence trimming erase quiet speakers.
  local highpass = "highpass=f=90"
  ---@type DictationRecording
  local recording
  local function failure(message)
    message = message:gsub("%s+$", "")
    if message == "" or recording.discarded then
      return
    end
    recording.discarded, recording.done = true, nil
    onError(message)
  end
  -- sh execs ffmpeg; its child SIGINTs ffmpeg when stdin closes (Hammerspoon exited). Owner-only.
  local watchdog =
    'umask 077; exec 3<&0; (read _ <&3; kill -INT $$) >/dev/null 2>&1 & exec "$0" "$@" 3<&-'
  local task = hs.task.new("/bin/sh", function(code, _, errors)
    recording.task = nil -- frees the task, which holds these callbacks
    failure(errors or "")
    -- Stopping, SIGINT exits ffmpeg 255, or 2 if it came before ffmpeg set its handler.
    if not recording.stopping or (code ~= 0 and code ~= 255 and code ~= 2) then
      failure("capture exited (code " .. tostring(code) .. ")")
    end
    -- The last chunk arrives after the final tick: count it in the duration and peak.
    if recording.done then
      recorder.poll(recording)
    end
    os.remove(pcm)
    if recording.discarded then
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
    recorder.ffmpeg,
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
    pcm,
  })
  -- Log-spaced bands from 80 Hz to just under Nyquist.
  local bins, nyquist = {}, rate / 2
  for i = 0, bands do
    local hz = 80 * (nyquist * 0.98 / 80) ^ (i / bands)
    bins[i] = math.max(1, math.min(size // 2, math.floor(hz / nyquist * (size // 2))))
  end
  recording = {
    wav = wav,
    pcm = pcm,
    offset = 0,
    tail = "",
    peak = 0,
    peaks = {},
    bins = bins,
    task = task,
  }
  if not task:start() then
    return nil, "could not start capture task"
  end
  return recording
end

-- Read new PCM and analyze the latest window; nil until a full window exists. Called per frame.
---@param recording DictationRecording
---@return number[]? bands each 0..1: auto-gained shape times loudness over the room
function recorder.poll(recording)
  -- A file, not hs.task's stream: it drops output that is not UTF-8.
  local file = io.open(recording.pcm, "rb")
  if not file then
    return nil
  end
  file:seek("set", recording.offset)
  local new = file:read("a") or ""
  file:close()
  recording.offset = recording.offset + #new
  local data = recording.tail .. new
  recording.tail = data:sub(-size * 2)
  if #new == 0 or #recording.tail < size * 2 then
    return nil
  end
  -- Every window since the last frame counts toward the peak: a busy main thread can leave several.
  for last = #data, size * 2, -size * 2 do
    local _, level = samples(data, last - size * 2 + 1)
    recording.peak = math.max(recording.peak, level)
  end
  local real, level, energy = samples(recording.tail, 1)
  local imaginary = {}
  for i = 1, size do
    real[i], imaginary[i] = real[i] * window[i], 0
  end
  -- Bars move only above the room's floor, which starts at most ~-38 dBFS: speech may open a take.
  if energy > 0 then
    recording.floor = math.min(level, recording.floor and recording.floor + 0.002 or 0.3)
  end
  -- Full at ~11 dB over the room.
  local gain = math.max(0, math.min(1, (level - (recording.floor or level) - 0.08) / 0.2))
  fft(real, imaginary)
  local bands, top, bins, peaks = {}, 0, recording.bins, recording.peaks
  for band = 1, #bins do
    local low, high = bins[band - 1], math.max(bins[band - 1] + 1, bins[band])
    local sum = 0
    for bin = low, high - 1 do
      sum = sum + math.sqrt(real[bin + 1] ^ 2 + imaginary[bin + 1] ^ 2)
    end
    bands[band] = math.sqrt(sum / (high - low)) -- perceptual compression
    peaks[band] = math.max((peaks[band] or 1e-4) * 0.999, bands[band])
    top = math.max(top, peaks[band])
  end
  -- Peaks floored at 0.4 of the loudest, or the first word after silence fills every band.
  for band = 1, #bins do
    bands[band] = gain * math.min(1, bands[band] / (math.max(peaks[band], top * 0.4) + 1e-6)) ^ 0.5
  end
  return bands
end

-- SIGINT lets ffmpeg finalize the wav; `done` gets it and the seconds read (failures: onError).
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
  -- Now: a reload skips the exit callback (unlinking is safe while ffmpeg writes).
  os.remove(recording.wav)
  os.remove(recording.pcm)
end

return recorder

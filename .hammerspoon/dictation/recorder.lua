local utils = require("lib.utils")

---@class DictationRecording
---@field wav string
---@field close fun(): string, string? ends the PCM stream: its undelivered bytes, and any error
---@field fresh string PCM streamed since the last analysis
---@field offset integer bytes of PCM analyzed so far
---@field tail string the latest analysis window
---@field peak number loudest window so far (0..1)
---@field peaks number[] per-band slow-decaying maximum, for auto-gain
---@field floor? number room loudness (0..1): falls instantly, rises slowly
---@field bins integer[] band edges in FFT bins, 0..bands
---@field task? hs.task nil once ffmpeg exits
---@field discarded? boolean cancelled or failed
---@field done? fun(wav: string, peak: number, duration: number)

local recorder = {}

---@class StreamNative
---@field listen fun(path: string, callback: fun(chunk?: string, problem?: string)): (fun(): string, string?)?, string?

-- A socket, not hs.task's stream: it drops output that is not UTF-8.
local stream = utils.native("stream") --[[@as StreamNative]]

local rate = 16000
local size = 1024 -- FFT window, in samples

-- Hann window.
local window = {}
for i = 1, size do
  window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (size - 1))
end

-- mise's own binary, through its ffmpeg shim (a symlink): resolved once, as the shim adds ~15 ms.
local mise = hs.fs.pathToAbsolute(os.getenv("HOME") .. "/.local/share/mise/shims/ffmpeg")
local which = mise and hs.execute("cd / && " .. utils.quote(mise) .. " which ffmpeg")
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
  local wav, socket = base .. ".wav", base .. ".sock"
  -- High-pass only: denoise and silence trimming erase quiet speakers.
  local highpass = "highpass=f=90"
  ---@type DictationRecording
  local recording
  local function failure(message)
    message = (message or ""):gsub("%s+$", "")
    if message == "" or recording.discarded then
      return
    end
    recording.discarded, recording.done = true, nil
    onError(message)
  end
  -- Listening before ffmpeg starts, so it can connect.
  local close, reason = stream.listen(socket, function(chunk, problem)
    if chunk then
      recording.fresh = recording.fresh .. chunk
    else
      failure(problem)
    end
  end)
  if not close then
    return nil, reason
  end
  -- If Hammerspoon dies, ffmpeg's socket writes fail and it exits.
  local task = hs.task.new(recorder.ffmpeg, function(code, _, errors)
    recording.task = nil -- frees the task, which holds these callbacks
    failure(errors)
    -- Stopping, SIGINT exits ffmpeg 255, or 2 if it came before ffmpeg set its handler.
    if not recording.done or (code ~= 0 and code ~= 255 and code ~= 2) then
      failure("capture exited (code " .. code .. ")")
    end
    -- The last chunk arrives after the final tick: count it in the duration and peak.
    local rest, problem = recording.close()
    failure(problem)
    if recording.done then
      recording.fresh = recording.fresh .. rest
      recorder.analyze(recording)
      recording.done(wav, recording.peak, recording.offset / (2 * rate))
    end
  end, function(_, _, errors)
    -- Output after the exit fails nothing.
    if recording.task then
      failure(errors)
    end
    return true
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
    -- Per packet: a killed ffmpeg (a stalled input) leaves on disk all it got.
    "-flush_packets",
    "1",
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
    "unix:" .. socket,
  })
  -- Log-spaced bands from 80 Hz to just under Nyquist.
  local bins, nyquist = {}, rate / 2
  for i = 0, bands do
    local hz = 80 * (nyquist * 0.98 / 80) ^ (i / bands)
    bins[i] = math.max(1, math.min(size // 2, math.floor(hz / nyquist * (size // 2))))
  end
  recording = {
    wav = wav,
    close = close,
    fresh = "",
    offset = 0,
    tail = "",
    peak = 0,
    peaks = {},
    bins = bins,
    task = task,
  }
  if not task:start() then
    close()
    return nil, "could not start capture task"
  end
  return recording
end

---@param recording DictationRecording
---@return number[]? bands each 0..1: auto-gained shape times loudness over the room
function recorder.analyze(recording)
  local new = recording.fresh
  recording.fresh = ""
  recording.offset = recording.offset + #new
  local data = recording.tail .. new
  recording.tail = data:sub(-size * 2)
  if #new == 0 or #recording.tail < size * 2 then
    return nil
  end
  local real, level, energy = samples(recording.tail, 1)
  -- Every window since the last frame counts toward the peak: a busy main thread can leave several.
  recording.peak = math.max(recording.peak, level)
  for last = #data - size * 2, size * 2, -size * 2 do
    local _, older = samples(data, last - size * 2 + 1)
    recording.peak = math.max(recording.peak, older)
  end
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
  recording.done = done
  assert(recording.task):interrupt()
end

---@param recording? DictationRecording
---@param kept? boolean its wav is left for history
function recorder.cleanup(recording, kept)
  if not recording then
    return
  end
  recording.discarded, recording.done = true, nil
  -- SIGKILL: ffmpeg ignores 3 signals once its input stops delivering (an unplugged mic).
  if recording.task and recording.task:isRunning() then
    os.execute("kill -KILL " .. recording.task:pid())
  end
  -- Now: a reload skips the exit callback (unlinking is safe while ffmpeg writes).
  recording.close()
  if not kept then
    os.remove(recording.wav)
  end
end

return recorder

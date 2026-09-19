-- Turns raw 16-bit mono PCM into equalizer bands, in pure Lua. One 1024-point
-- FFT per call costs ~2 ms, well inside the 33 ms frame at 30 fps.

---@class DictationSpectrum
---@field size integer FFT size (samples per analysis window)
---@field bands integer number of output bands
---@field bins integer[] band edge FFT bins, index 0..bands
---@field window number[] Hann window, 1..size
---@field peak number[] per-band slow-decaying maximum for auto-gain
local spectrum = {}
spectrum.__index = spectrum

---@param rate integer sample rate in Hz
---@param bands integer number of log-spaced bands from 80 Hz to just under Nyquist
---@param size? integer FFT size, power of two (default 1024)
---@return DictationSpectrum
function spectrum.new(rate, bands, size)
  size = size or 1024
  local self = setmetatable({ size = size, bands = bands, bins = {}, window = {}, peak = {} }, spectrum)
  local nyquist = rate / 2
  for i = 0, bands do
    local hz = 80 * (nyquist * 0.98 / 80) ^ (i / bands)
    self.bins[i] = math.max(1, math.min(size // 2, math.floor(hz / nyquist * (size // 2))))
  end
  for i = 1, size do
    self.window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * (i - 1) / (size - 1))
  end
  for i = 1, bands do
    self.peak[i] = 1e-4
  end
  return self
end

-- In-place iterative radix-2 FFT.
---@param re number[]
---@param im number[]
local function fft(re, im)
  local n = #re
  local j = 1
  for i = 1, n - 1 do
    if i < j then
      re[i], re[j] = re[j], re[i]
      im[i], im[j] = im[j], im[i]
    end
    local m = n // 2
    while m >= 1 and j > m do
      j = j - m
      m = m // 2
    end
    j = j + m
  end
  local len = 2
  while len <= n do
    local angle = -2 * math.pi / len
    local wr, wi = math.cos(angle), math.sin(angle)
    for start = 1, n, len do
      local cr, ci = 1, 0
      for k = 0, len // 2 - 1 do
        local a, b = start + k, start + k + len // 2
        local tr = re[b] * cr - im[b] * ci
        local ti = re[b] * ci + im[b] * cr
        re[b], im[b] = re[a] - tr, im[a] - ti
        re[a], im[a] = re[a] + tr, im[a] + ti
        cr, ci = cr * wr - ci * wi, cr * wi + ci * wr
      end
    end
    len = len * 2
  end
end

-- Analyze the most recent window of PCM.
---@param pcm string at least `size * 2` bytes of little-endian signed 16-bit mono samples; the last window is used
---@return number[] bands each 0..1 (auto-gained)
---@return number level overall loudness 0..1 (-50..-10 dBFS)
function spectrum:analyze(pcm)
  local size = self.size
  local re, im = {}, {}
  local base = #pcm - size * 2
  local energy = 0
  for i = 1, size do
    local lo, hi = pcm:byte(base + 2 * i - 1, base + 2 * i)
    local sample = hi * 256 + lo
    if sample >= 32768 then
      sample = sample - 65536
    end
    sample = sample / 32768
    energy = energy + sample * sample
    re[i] = sample * self.window[i]
    im[i] = 0
  end
  local rms = math.sqrt(energy / size) + 1e-9
  local level = math.max(0, math.min(1, (20 * math.log(rms, 10) + 50) / 40))
  fft(re, im)
  local bands = {}
  for b = 1, self.bands do
    local lo, hi = self.bins[b - 1], math.max(self.bins[b - 1] + 1, self.bins[b])
    local sum = 0
    for k = lo, hi - 1 do
      sum = sum + math.sqrt(re[k + 1] ^ 2 + im[k + 1] ^ 2)
    end
    local magnitude = math.sqrt(sum / (hi - lo)) -- perceptual compression
    self.peak[b] = math.max(self.peak[b] * 0.999, magnitude)
    bands[b] = math.max(0, math.min(1, magnitude / (self.peak[b] + 1e-6)))
  end
  return bands, level
end

return spectrum

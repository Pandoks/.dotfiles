---@class DictationOverlay
---@field baseline number[] idle diamond envelope per bar (0..1)
---@field thinking boolean true while transcribing (shimmer animation)
---@field warming boolean true from show() until the first audio frame (listening pulse)
---@field phase number animation phase for the shimmer
---@field bars number[] current per-bar equalizer heights (0..1), smoothed
---@field canvas hs.canvas? the drawn pill; nil after :delete()
---@field width number pill width in points
---@field height number pill height in points
---@field barWidth number bar width in points
local overlay = {}
overlay.__index = overlay

local BARS = 29
local ASPECT = 3.32
local STROKE = 1
local BAR_W = 0.038 -- of height
local BAR_SPAN = 0.80 -- fraction of width the bars occupy
local BAR_PEAK = 0.34 -- tallest bar as fraction of height

---@param height? number pill height in points (default 30)
---@return DictationOverlay
function overlay.new(height)
  ---@type DictationOverlay
  local self = setmetatable({}, overlay)
  self.height = height or 30
  self.thinking = false
  self.phase = 0
  -- Baseline diamond envelope so an idle pill still looks like Raycast's.
  self.baseline = {}
  self.bars = {}
  local half = (BARS - 1) / 2
  for i = 1, BARS do
    local t = math.abs(i - (BARS + 1) / 2) / half
    self.baseline[i] = math.max(0, (1 - t)) ^ 2.4
    self.bars[i] = 0
  end

  height = self.height
  local width = height * ASPECT
  local radius = (height - STROKE) / 2
  local canvas =
    assert(hs.canvas.new({ x = 0, y = 0, w = width, h = height }), "hs.canvas.new failed")
  canvas:level(hs.canvas.windowLevels.status)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)

  canvas:appendElements({
    type = "rectangle",
    action = "strokeAndFill",
    roundedRectRadii = { xRadius = radius, yRadius = radius },
    padding = STROKE / 2, -- Keep the centered stroke inside the canvas.
    fillColor = { white = 0.13, alpha = 0.98 },
    strokeColor = { white = 0.24, alpha = 1.0 },
    strokeWidth = STROKE,
  })
  local barWidth = height * BAR_W
  for _ = 1, BARS do
    canvas:appendElements({
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = barWidth / 2, yRadius = barWidth / 2 },
      fillColor = { white = 0.976, alpha = 1.0 },
      frame = { x = 0, y = 0, w = barWidth, h = barWidth },
    })
  end
  self.canvas = canvas
  self.width, self.barWidth = width, barWidth
  self:_layout()
  return self
end

-- Recompute every bar's frame from the current state.
function overlay:_layout()
  local canvas = self.canvas
  if not canvas then
    return
  end
  local height, width, barWidth = self.height, self.width, self.barWidth
  local span = width * BAR_SPAN
  local pitch = span / (BARS - 1)
  local cx, cy = width / 2, height / 2
  for i = 1, BARS do
    local amplitude
    if self.thinking then
      -- gentle traveling shimmer while transcribing
      amplitude = (0.25 + 0.35 * (0.5 + 0.5 * math.sin(self.phase + i * 0.5))) * self.baseline[i]
    elseif self.warming then
      -- "listening" breath from the first millisecond, until the microphone
      -- delivers its first frame (opening the device takes ~0.4 s)
      amplitude = (0.35 + 0.25 * math.sin(self.phase * 0.6)) * self.baseline[i]
    else
      -- real equalizer: per-bar band height, floored by the idle envelope
      amplitude = math.max(self.baseline[i] * 0.12, self.bars[i])
    end
    local h = math.max(barWidth, height * BAR_PEAK * amplitude + barWidth * 0.85)
    local x = cx - span / 2 + (i - 1) * pitch
    -- element 1 is the pill; bars are elements 2..BARS+1
    canvas:elementAttribute(
      i + 1,
      "frame",
      { x = x - barWidth / 2, y = cy - h / 2, w = barWidth, h = h }
    )
  end
end

-- Feed frequency-band magnitudes (0..1). The analyzer sends N bands (low->high);
-- we mirror them around the center so the pill stays symmetric like Raycast:
-- center bars are the lowest bands, outer bars the highest.
---@param bands number[] per-band magnitudes, low to high frequency
function overlay:setBars(bands)
  if type(bands) ~= "table" or #bands == 0 then
    return
  end
  self.warming = false
  local center = (BARS + 1) / 2
  for i = 1, BARS do
    local distance = math.floor(math.abs(i - center)) -- 0 at center
    local band = bands[math.min(#bands, distance + 1)] or 0
    -- attack fast, release slow for a natural equalizer bounce
    local target = math.max(0, math.min(1, band))
    local current = self.bars[i]
    local smoothing = target > current and 0.6 or 0.25
    self.bars[i] = current + (target - current) * smoothing
  end
  self:_layout()
end

-- Advance the shimmer animation; call at ~30 fps while visible.
function overlay:tick()
  self.phase = self.phase + 0.35
  if self.thinking or self.warming then
    self:_layout()
  end
end

-- Show centered horizontally, near the bottom of the screen with the mouse.
function overlay:show()
  self.thinking = false
  self.warming = true
  for i = 1, BARS do
    self.bars[i] = 0
  end
  local canvas = self.canvas
  if not canvas then
    return
  end
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  if screen then
    local f = screen:frame()
    canvas:topLeft({
      x = f.x + (f.w - self.width) / 2,
      y = f.y + f.h - self.height - math.floor(f.h * 0.10),
    })
  end
  self:_layout()
  canvas:show(0.12)
end

function overlay:setThinking()
  self.thinking = true
  self:_layout()
end

function overlay:hide()
  if self.canvas then
    self.canvas:hide(0.12)
  end
end

function overlay:delete()
  if self.canvas then
    self.canvas:delete()
    self.canvas = nil
  end
end

return overlay

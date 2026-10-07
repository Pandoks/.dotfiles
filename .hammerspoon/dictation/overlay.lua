---@class DictationOverlay
---@field baseline number[] idle diamond envelope per bar (0..1)
---@field thinking boolean true while transcribing (shimmer animation)
---@field warmth number 1 = ripple intro (mic opening), fading to 0 = live equalizer
---@field phase number animation phase (intro ripple, shimmer); 0 at show()
---@field bars number[] current per-bar equalizer heights (0..1), smoothed
---@field canvas hs.canvas the drawn pill
---@field width number pill width in points
---@field height number pill height in points
---@field barWidth number bar width in points
local overlay = {}
overlay.__index = overlay

local aspect = 3.32
local stroke = 1
local thickness = 0.038 -- bar width as a fraction of height
local spread = 0.80 -- fraction of width the bars occupy
local peak = 0.34 -- tallest bar as a fraction of height
local fade = 12 -- frames (~0.4 s at 30 fps) from the ripple intro to the live equalizer

---@param height number pill height in points
---@param bands integer spectrum bands, mirrored around the center bar
function overlay.new(height, bands)
  local self = setmetatable({}, overlay)
  self.height = height
  -- Baseline diamond envelope so an idle pill still looks like Raycast's.
  self.baseline = {}
  self.bars = {}
  local bars = 2 * bands - 1
  for i = 1, bars do
    local t = math.abs(i - bands) / (bands - 1)
    self.baseline[i] = math.max(0, (1 - t)) ^ 2.4
    self.bars[i] = 0
  end

  local width = height * aspect
  local radius = (height - stroke) / 2
  local canvas =
    assert(hs.canvas.new({ x = 0, y = 0, w = width, h = height }), "hs.canvas.new failed")
  canvas:level(hs.canvas.windowLevels.status)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)

  canvas:appendElements({
    type = "rectangle",
    action = "strokeAndFill",
    roundedRectRadii = { xRadius = radius, yRadius = radius },
    padding = stroke / 2, -- Keep the centered stroke inside the canvas.
    fillColor = { white = 0.13, alpha = 0.98 },
    strokeColor = { white = 0.24, alpha = 1.0 },
    strokeWidth = stroke,
  })
  local barWidth = height * thickness
  for _ = 1, bars do
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
  return self
end

-- Recompute every bar's frame from the current state.
function overlay:_layout()
  local canvas = self.canvas
  local height, width, barWidth = self.height, self.width, self.barWidth
  local bars = #self.bars
  local span = width * spread
  local pitch = span / (bars - 1)
  local cx, cy = width / 2, height / 2
  local warmth = self.warmth * self.warmth * (3 - 2 * self.warmth) -- smoothstep ease
  local center = (bars + 1) / 2
  for i = 1, bars do
    local amplitude
    local glow = 1 -- bar brightness
    if self.thinking then
      -- gentle traveling shimmer while transcribing
      local wave = 0.5 + 0.5 * math.sin(self.phase + i * 0.5)
      amplitude = (0.25 + 0.35 * wave) * self.baseline[i]
      glow = 0.4 + 0.6 * wave ^ 2 -- brightness travels with the shimmer
    else
      -- Ripple intro from the center bar, crossfading into the live equalizer.
      local distance = math.abs(i - center)
      local bloom = math.max(0, math.min(1, (self.phase * 4.6 - distance) / 4))
      local ripple = (0.5 + 0.5 * math.sin(self.phase * 1.3 - distance * 0.6)) ^ 2
      local intro = bloom * (0.25 + 0.75 * self.baseline[i]) * (0.2 + 0.8 * ripple)
      local live = math.max(self.baseline[i] * 0.12, self.bars[i])
      amplitude = warmth * intro + (1 - warmth) * live
      -- Intro: bars light up as the wave passes. Live: louder bars glow brighter.
      local lit = 1 - 0.6 * (1 - ripple * bloom)
      glow = warmth * lit + (1 - warmth) * (0.45 + 0.55 * math.min(1, self.bars[i] * 1.8))
    end
    local h = math.max(barWidth, height * peak * amplitude + barWidth * 0.85)
    local x = cx - span / 2 + (i - 1) * pitch
    -- element 1 is the pill; bars are elements 2..bars+1
    canvas:elementAttribute(
      i + 1,
      "frame",
      { x = x - barWidth / 2, y = cy - h / 2, w = barWidth, h = h }
    )
    canvas:elementAttribute(i + 1, "fillColor", { white = 0.976, alpha = glow })
  end
end

-- Mirror spectrum.lua's bands around the center: lowest in the middle, highest outside.
---@param bands number[] per-band magnitudes (0..1), low to high frequency
function overlay:setBars(bands)
  if self.warmth > 0 then
    self.warmth = math.max(0, self.warmth - 1 / fade)
    self.phase = self.phase + 0.35 -- keep the ripple moving while it fades out
  end
  local center = (#self.bars + 1) // 2
  for i = 1, #self.bars do
    local band = bands[math.abs(i - center) + 1]
    -- attack fast, release slow for a natural equalizer bounce
    local target = math.max(0, math.min(1, band))
    local current = self.bars[i]
    local smoothing = target > current and 0.6 or 0.25
    self.bars[i] = current + (target - current) * smoothing
  end
  self:_layout()
end

-- Advance the ripple intro or shimmer; call at ~30 fps while visible.
function overlay:tick()
  self.phase = self.phase + 0.35
  if self.thinking or self.warmth > 0 then
    self:_layout()
  end
end

-- Show centered horizontally, near the bottom of the screen with the mouse.
function overlay:show()
  self.thinking = false
  self.warmth = 1
  self.phase = 0 -- the intro blooms from the center at phase 0
  for i = 1, #self.bars do
    self.bars[i] = 0
  end
  local canvas = self.canvas
  local screen = hs.mouse.getCurrentScreen() or hs.screen.mainScreen()
  if screen then
    local frame = screen:frame()
    canvas:topLeft({
      x = frame.x + (frame.w - self.width) / 2,
      y = frame.y + frame.h - self.height - math.floor(frame.h * 0.10),
    })
  end
  self:_layout()
  canvas:show()
end

function overlay:setThinking()
  self.thinking = true
  self:_layout()
end

function overlay:hide()
  self.canvas:hide()
end

function overlay:delete()
  self.canvas:delete()
end

return overlay

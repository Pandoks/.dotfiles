local overlay = {}
overlay.__index = overlay
-- Equalizer bands, mirrored into 2n - 1 bars; the spacing below is tuned for 15.
overlay.bands = 15

local aspect = 3.32
local stroke = 1
local thickness = 0.038 -- bar width as a fraction of height
local spread = 0.80 -- fraction of width the bars occupy
local peak = 0.34 -- tallest bar as a fraction of height
local fade = 12 -- frames (~0.4 s at 30 fps) from the ripple intro to the live equalizer

-- A pill shown near the bottom of the screen with the focused window.
---@param height number
function overlay.new(height)
  local width, barWidth = height * aspect, height * thickness
  local canvas = hs.canvas.new({ x = 0, y = 0, w = width, h = height }) --[[@as hs.canvas]]
  local self = setmetatable({
    canvas = canvas,
    height = height,
    width = width,
    barWidth = barWidth,
    baseline = {}, -- an idle pill's diamond envelope, like Raycast's
    bars = {}, -- live heights, smoothed
    thinking = false, -- shimmer while transcribing
    warmth = 1, -- 1 = ripple intro, fading to 0 = live equalizer
    phase = 0, -- the intro blooms from the center at 0
  }, overlay)
  local bands = overlay.bands
  for i = 1, 2 * bands - 1 do
    self.baseline[i] = math.max(0, 1 - math.abs(i - bands) / (bands - 1)) ^ 2.4
    self.bars[i] = 0
  end

  local radius = (height - stroke) / 2
  canvas:level(hs.canvas.windowLevels.status)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:appendElements({
    type = "rectangle",
    action = "strokeAndFill",
    roundedRectRadii = { xRadius = radius, yRadius = radius },
    padding = stroke / 2, -- the centered stroke stays inside the canvas
    fillColor = { white = 0.13, alpha = 0.98 },
    strokeColor = { white = 0.24, alpha = 1.0 },
    strokeWidth = stroke,
  })
  for _ = 1, #self.bars do
    canvas:appendElements({
      type = "rectangle",
      action = "fill",
      roundedRectRadii = { xRadius = barWidth / 2, yRadius = barWidth / 2 },
      fillColor = { white = 0.976, alpha = 1.0 },
      frame = { x = 0, y = 0, w = barWidth, h = barWidth },
    })
  end

  -- The screen with the focused window, not the mouse's.
  local screen = hs.screen.mainScreen()
  if screen then
    local frame = screen:frame()
    canvas:topLeft({
      x = frame.x + (frame.w - width) / 2,
      y = frame.y + frame.h - height - math.floor(frame.h * 0.10),
    })
  end
  self:layout()
  canvas:show()
  return self
end

-- Recompute every bar's frame from the current state.
function overlay:layout()
  local height, width, barWidth = self.height, self.width, self.barWidth
  local count = #self.bars
  local span = width * spread
  local pitch = span / (count - 1)
  local warmth = self.warmth * self.warmth * (3 - 2 * self.warmth) -- smoothstep
  local center = (count + 1) / 2
  for i = 1, count do
    local amplitude, glow
    if self.thinking then
      -- A shimmer travels along the bars, brightness with it.
      local wave = 0.5 + 0.5 * math.sin(self.phase + i * 0.5)
      amplitude = (0.25 + 0.35 * wave) * self.baseline[i]
      glow = 0.4 + 0.6 * wave ^ 2
    else
      -- A ripple from the center bar crossfades into the live equalizer; louder bars glow brighter.
      local distance = math.abs(i - center)
      local bloom = math.max(0, math.min(1, (self.phase * 4.6 - distance) / 4))
      local ripple = (0.5 + 0.5 * math.sin(self.phase * 1.3 - distance * 0.6)) ^ 2
      local intro = bloom * (0.25 + 0.75 * self.baseline[i]) * (0.2 + 0.8 * ripple)
      local live = math.max(self.baseline[i] * 0.12, self.bars[i])
      amplitude = warmth * intro + (1 - warmth) * live
      glow = warmth * (1 - 0.6 * (1 - ripple * bloom))
        + (1 - warmth) * (0.45 + 0.55 * math.min(1, self.bars[i] * 1.8))
    end
    local h = math.max(barWidth, height * peak * amplitude + barWidth * 0.85)
    local x = width / 2 - span / 2 + (i - 1) * pitch
    -- Element 1 is the pill.
    self.canvas:elementAttribute(
      i + 1,
      "frame",
      { x = x - barWidth / 2, y = height / 2 - h / 2, w = barWidth, h = h }
    )
    self.canvas:elementAttribute(i + 1, "fillColor", { white = 0.976, alpha = glow })
  end
end

-- One frame: the ripple or shimmer moves on; live `bands` (low to high) mirror out from the center.
---@param bands? number[]|false
function overlay:update(bands)
  self.phase = self.phase + 0.35
  if bands then
    self.warmth = math.max(0, self.warmth - 1 / fade)
    local center = (#self.bars + 1) // 2
    for i = 1, #self.bars do
      -- Fast attack, slow release: a natural equalizer bounce.
      local target = math.max(0, math.min(1, bands[math.abs(i - center) + 1]))
      local current = self.bars[i]
      self.bars[i] = current + (target - current) * (target > current and 0.6 or 0.25)
    end
  end
  if bands or self.thinking or self.warmth > 0 then
    self:layout()
  end
end

return overlay

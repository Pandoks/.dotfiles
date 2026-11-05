local overlay = {}
overlay.__index = overlay
-- Mirrored into 2n - 1 bars; the spacing below is tuned for 15.
overlay.bands = 15

local height = 44
local aspect = 3.32
local stroke = 1
local thickness = 0.038
local spread = 0.80
local peak = 0.34
local fadeFrames = 12
local width, barWidth = height * aspect, height * thickness

---@param glass? GlassNative Liquid Glass instead of the flat pill.
function overlay.new(glass)
  local canvas = hs.canvas.new({ x = 0, y = 0, w = width, h = height }) --[[@as hs.canvas]]
  local dark = not glass or hs.host.interfaceStyle() == "Dark"
  local self = setmetatable({
    canvas = canvas,
    ink = dark and 0.976 or 0, -- bar gray
    baseline = {}, -- idle diamond envelope
    bars = {},
    thinking = false,
    warmth = 1, -- 1 = ripple intro, 0 = live equalizer
    phase = 0,
  }, overlay)
  local bands = overlay.bands
  for bar = 1, 2 * bands - 1 do
    self.baseline[bar] = math.max(0, 1 - math.abs(bar - bands) / (bands - 1)) ^ 2.4
    self.bars[bar] = 0
  end

  local radius = (height - stroke) / 2
  canvas:level(hs.canvas.windowLevels.status)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)
  canvas:appendElements({
    type = "rectangle",
    action = glass and "skip" or "strokeAndFill",
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
      fillColor = { white = self.ink, alpha = 1.0 },
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
  self.glass = glass and glass.new(canvas, height / 2, 0, dark)
  return self
end

function overlay:delete()
  if self.glass then
    self.glass:hide(0)
  end
  self.canvas:delete()
end

function overlay:layout()
  local count = #self.bars
  local span = width * spread
  local pitch = span / (count - 1)
  local warmth = self.warmth * self.warmth * (3 - 2 * self.warmth) -- smoothstep
  local center = (count + 1) / 2
  for bar = 1, count do
    local amplitude, glow
    if self.thinking then
      -- A traveling shimmer.
      local wave = 0.5 + 0.5 * math.sin(self.phase + bar * 0.5)
      amplitude = (0.25 + 0.35 * wave) * self.baseline[bar]
      glow = 0.4 + 0.6 * wave ^ 2
    else
      -- A center ripple crossfades into the live levels.
      local distance = math.abs(bar - center)
      local bloom = math.max(0, math.min(1, (self.phase * 4.6 - distance) / 4))
      local ripple = (0.5 + 0.5 * math.sin(self.phase * 1.3 - distance * 0.6)) ^ 2
      local intro = bloom * (0.25 + 0.75 * self.baseline[bar]) * (0.2 + 0.8 * ripple)
      local live = math.max(self.baseline[bar] * 0.12, self.bars[bar])
      amplitude = warmth * intro + (1 - warmth) * live
      glow = warmth * (1 - 0.6 * (1 - ripple * bloom))
        + (1 - warmth) * (0.45 + 0.55 * math.min(1, self.bars[bar] * 1.8))
    end
    local barHeight = math.max(barWidth, height * peak * amplitude + barWidth * 0.85)
    local barCenter = width / 2 - span / 2 + (bar - 1) * pitch
    -- Element 1 is the pill.
    self.canvas:elementAttribute(
      bar + 1,
      "frame",
      { x = barCenter - barWidth / 2, y = height / 2 - barHeight / 2, w = barWidth, h = barHeight }
    )
    self.canvas:elementAttribute(bar + 1, "fillColor", { white = self.ink, alpha = glow })
  end
end

-- Live `bands` (low to high) mirror out from the center bar.
---@param bands? number[]|false
function overlay:update(bands)
  self.phase = self.phase + 0.35
  if bands then
    self.warmth = math.max(0, self.warmth - 1 / fadeFrames)
    local center = (#self.bars + 1) // 2
    for bar = 1, #self.bars do
      -- Fast attack, slow release.
      local target = math.max(0, math.min(1, bands[math.abs(bar - center) + 1]))
      local current = self.bars[bar]
      self.bars[bar] = current + (target - current) * (target > current and 0.6 or 0.25)
    end
  end
  if bands or self.thinking or self.warmth > 0 then
    self:layout()
  end
end

return overlay

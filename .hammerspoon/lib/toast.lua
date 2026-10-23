-- Raycast-style toasts at the bottom right: the dictation pill's dark face, with a metal rim.
local toast = {}

local limit = 340 -- widest line of text, in points
local margin, gap, padding, icon = 16, 8, 14, 16
local most = 5 -- toasts on screen; a sixth drops the oldest
local title = {
  font = { name = ".AppleSystemUIFontMedium", size = 13 },
  color = { white = 0.976 },
  paragraphStyle = { lineBreak = "truncateTail" },
}
local detail = {
  font = { name = ".AppleSystemUIFont", size = 12 },
  color = { white = 0.62 },
  paragraphStyle = { lineBreak = "truncateTail" },
}
local red = { red = 1, green = 0.27, blue = 0.23 }
-- Brushed metal: a rim lit from the top left with a second glint lower down, over a face lit from
-- above. The rim is a gradient under the face inset 1 pt, as canvas strokes take no gradient.
local rim = { { white = 0.62 }, { white = 0.2 }, { white = 0.42 }, { white = 0.16 } }
local face = { { white = 0.2 }, { white = 0.1 } }

---@alias ToastSize { w: number, h: number }

---@type { text: string, canvas: hs.canvas, timer: hs.timer }[]
local shown = {} -- oldest first; the newest sits at the bottom

local function layout()
  local screen = hs.screen.mainScreen()
  if not screen then
    return
  end
  local frame = screen:frame()
  local bottom = frame.y + frame.h - margin
  for i = #shown, 1, -1 do
    local size = shown[i].canvas:size() --[[@as ToastSize]]
    bottom = bottom - size.h
    shown[i].canvas:topLeft({ x = frame.x + frame.w - margin - size.w, y = bottom })
    bottom = bottom - gap
  end
end

-- By text, which is all the callbacks hold: one holding its own timer is never collected.
---@param text string
local function dismiss(text)
  for i, entry in ipairs(shown) do
    if entry.text == text then
      table.remove(shown, i)
      entry.timer:stop()
      entry.canvas:delete(0.25)
      layout()
      return
    end
  end
end

-- `text` in lines of at most `limit` points, and its size; past `lines`, the rest goes on the
-- last, cut with "…".
---@param canvas hs.canvas
---@param text string
---@param style table
---@param lines integer
local function wrap(canvas, text, style, lines)
  local function size(value)
    return canvas:minimumTextSize(hs.styledtext.new(value, style)) --[[@as ToastSize]]
  end
  local out, line = {}, nil
  for word in text:gmatch("%S+") do
    local longer = line and line .. " " .. word or word
    if line and size(longer).w > limit and #out < lines - 1 then
      out[#out + 1], line = line, word
    else
      line = longer
    end
  end
  out[#out + 1] = line or ""
  local joined = table.concat(out, "\n")
  return hs.styledtext.new(joined, style), size(joined)
end

-- Show `text` for `seconds` (3 by default); "Tiling: no window" is titled "Tiling".
---@param text string
---@param style? "failure" a red cross
---@param seconds? number
function toast.show(text, style, seconds)
  seconds = seconds or 3
  -- The same toast again restarts its time instead of stacking.
  for _, entry in ipairs(shown) do
    if entry.text == text then
      entry.timer:setNextTrigger(seconds)
      return
    end
  end
  local head, rest = text:match("^([^:\n]+): (.+)$")
  if not head or #head > 24 then
    head, rest = text, nil
  end
  -- "no window" -> "No window", but "macOS" stays.
  rest = rest
    and rest:gsub("^(%l)(%l*%f[^%w])", function(first, others)
      return first:upper() .. others
    end)

  local canvas = hs.canvas.new({ x = 0, y = 0, w = 1, h = 1 }) --[[@as hs.canvas]]
  local heading, top = wrap(canvas, head, title, rest and 1 or 3)
  local body, below
  if rest then
    body, below = wrap(canvas, rest, detail, 3)
  end
  local width = math.min(limit, math.max(top.w, below and below.w or 0))
  local height = 2 * 12 + top.h + (below and 2 + below.h or 0)
  local left = padding + (style == "failure" and icon + 10 or 0)
  local size, radius = { w = left + width + padding, h = height }, math.min(height / 2, 20)
  canvas:size(size)
  canvas:appendElements({
    type = "rectangle",
    action = "fill",
    roundedRectRadii = { xRadius = radius, yRadius = radius },
    fillGradient = "linear",
    fillGradientColors = rim,
    fillGradientAngle = 45,
  })
  canvas:appendElements({
    type = "rectangle",
    action = "fill",
    frame = { x = 1, y = 1, w = size.w - 2, h = size.h - 2 },
    roundedRectRadii = { xRadius = radius - 1, yRadius = radius - 1 },
    fillGradient = "linear",
    fillGradientColors = face,
    fillGradientAngle = 90,
  })
  if style == "failure" then
    local x, y, arm = padding + icon / 2, height / 2, icon * 0.18
    canvas:appendElements({
      type = "circle",
      action = "fill",
      center = { x = x, y = y },
      radius = icon / 2,
      fillColor = red,
    })
    for _, sign in ipairs({ 1, -1 }) do
      canvas:appendElements({
        type = "segments",
        action = "stroke",
        coordinates = { { x = x - arm, y = y - sign * arm }, { x = x + arm, y = y + sign * arm } },
        strokeColor = { white = 1 },
        strokeWidth = 1.6,
        strokeCapStyle = "round",
      })
    end
  end
  -- 1 pt of slack: the measured width wraps a line exactly that wide.
  canvas:appendElements({
    type = "text",
    text = heading,
    frame = { x = left, y = 12, w = width + 1, h = top.h },
  })
  if below then
    canvas:appendElements({
      type = "text",
      text = body,
      frame = { x = left, y = 12 + top.h + 2, w = width + 1, h = below.h },
    })
  end
  canvas:level(hs.canvas.windowLevels.status)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)

  -- A click dismisses it.
  canvas:canvasMouseEvents(true, false, false, false)
  canvas:mouseCallback(function()
    dismiss(text)
  end)
  local timer = hs.timer.doAfter(seconds, function()
    dismiss(text)
  end)
  shown[#shown + 1] = { text = text, canvas = canvas, timer = timer }
  if #shown > most then
    dismiss(shown[1].text)
  end
  layout()
  canvas:show(0.15)
end

-- Every hs.alert.show, a Spoon's or a hotkey message's too, becomes a toast.
function toast.install()
  hs.alert.show = function(text, style, screen, seconds)
    local time = type(style) == "number" and style or type(screen) == "number" and screen or seconds
    toast.show(type(text) == "userdata" and text:getString() or tostring(text), nil, time)
  end
end

return toast

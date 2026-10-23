-- Raycast-style toasts at the bottom right: the dictation pill's dark face, in a choice of rims.
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

---@alias ToastTheme "metal"|"edge"|"flat"

-- Gray levels of each look: the rim is a gradient at `angle` under the face inset 1 pt, as canvas
-- strokes take no gradient; the face is lit from above.
local themes = {
  -- A glint at the top left and another lower down, like brushed metal.
  metal = { rim = { 0.62, 0.2, 0.42, 0.16 }, angle = 45, face = { 0.2, 0.1 } },
  -- Only the top left catches the light, with a faint rim at the bottom right.
  edge = { rim = { 0.62, 0.2, 0.14, 0.3 }, angle = 45, face = { 0.17, 0.11 } },
  flat = { rim = { 0.24, 0.24 }, angle = 90, face = { 0.13, 0.13 } },
}
local theme = themes.metal

---@alias ToastSize { w: number, h: number }

---@type { text: string, canvas: hs.canvas, screen: hs.screen, timer?: hs.timer }[]
local shown = {} -- oldest first; each screen's newest sits at its bottom

local function grays(levels)
  local colors = {}
  for i, level in ipairs(levels) do
    colors[i] = { white = level }
  end
  return colors
end

local function layout()
  local bottoms = {}
  for i = #shown, 1, -1 do
    local entry = shown[i]
    local frame, size = entry.screen:frame(), entry.canvas:size() --[[@as ToastSize]]
    local key = entry.screen:id()
    local bottom = (bottoms[key] or frame.y + frame.h - margin) - size.h
    entry.canvas:topLeft({ x = frame.x + frame.w - margin - size.w, y = bottom })
    bottoms[key] = bottom - gap
  end
end

-- By text, which is all the callbacks hold: one holding its own timer is never collected.
---@param text string
function toast.close(text)
  for i, entry in ipairs(shown) do
    if entry.text == text then
      table.remove(shown, i)
      if entry.timer then
        entry.timer:stop()
      end
      entry.canvas:delete(0.25)
      layout()
      return
    end
  end
end

---@param entry { text: string, timer?: hs.timer }
---@param seconds number|false
local function arm(entry, seconds)
  local text = entry.text
  if entry.timer then
    entry.timer:stop()
  end
  entry.timer = seconds and hs.timer.doAfter(seconds, function()
    toast.close(text)
  end) or nil
end

-- `text` in lines of at most `limit` points, breaking at its own line breaks too, and its size;
-- past `lines`, the rest goes on the last, cut with "…".
---@param canvas hs.canvas
---@param text string
---@param style table
---@param lines integer
local function wrap(canvas, text, style, lines)
  local function size(value)
    return canvas:minimumTextSize(hs.styledtext.new(value, style)) --[[@as ToastSize]]
  end
  local out, line = {}, nil
  for paragraph in (text .. "\n"):gmatch("([^\n]*)\n") do
    for word in paragraph:gmatch("%S+") do
      local longer = line and line .. " " .. word or word
      -- Measured only while the line may still break: the last one would grow quadratically.
      if line and #out < lines - 1 and size(longer).w > limit then
        out[#out + 1], line = line, word
      else
        line = longer
      end
    end
    if line and #out < lines - 1 then
      out[#out + 1], line = line, nil
    end
  end
  out[#out + 1] = line
  out[1] = out[1] or ""
  local joined = table.concat(out, "\n")
  return hs.styledtext.new(joined, style), size(joined)
end

-- Show `text`, titled "Tiling" for "Tiling: no window"; its id for `close` is the text.
-- `seconds`: 3 by default, false until closed; `screen`: the focused window's by default.
---@param text string
---@param options? { failure?: boolean, seconds?: number|false, screen?: hs.screen }
---@return string
function toast.show(text, options)
  options = options or {}
  local seconds = options.seconds
  if seconds == nil then
    seconds = 3
  end
  -- The same toast again restarts its time instead of stacking.
  for _, entry in ipairs(shown) do
    if entry.text == text then
      arm(entry, seconds)
      return text
    end
  end
  local screen = options.screen or hs.screen.mainScreen()
  if not screen then
    return text
  end
  local head, rest = text:match("^([^:\n]+): ([^\n]+)$")
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
  local left = padding + (options.failure and icon + 10 or 0)
  local size, radius = { w = left + width + padding, h = height }, math.min(height / 2, 20)
  canvas:size(size)
  canvas:appendElements({
    type = "rectangle",
    action = "fill",
    roundedRectRadii = { xRadius = radius, yRadius = radius },
    fillGradient = "linear",
    fillGradientColors = grays(theme.rim),
    fillGradientAngle = theme.angle,
  })
  canvas:appendElements({
    type = "rectangle",
    action = "fill",
    frame = { x = 1, y = 1, w = size.w - 2, h = size.h - 2 },
    roundedRectRadii = { xRadius = radius - 1, yRadius = radius - 1 },
    fillGradient = "linear",
    fillGradientColors = grays(theme.face),
    fillGradientAngle = 90,
  })
  if options.failure then
    local x, y, reach = padding + icon / 2, height / 2, icon * 0.18
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
        coordinates = {
          { x = x - reach, y = y - sign * reach },
          { x = x + reach, y = y + sign * reach },
        },
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
  -- Every Space, full-screen apps' too.
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  canvas:clickActivating(false)

  -- A click dismisses it.
  canvas:canvasMouseEvents(true, false, false, false)
  canvas:mouseCallback(function()
    toast.close(text)
  end)
  local entry = { text = text, canvas = canvas, screen = screen }
  arm(entry, seconds)
  shown[#shown + 1] = entry
  if #shown > most then
    toast.close(shown[1].text)
  end
  layout()
  canvas:show(0.15)
  return text
end

-- Pick the look, and make every hs.alert a toast: `show`, `hs.alert(...)`, a Spoon's, a hotkey
-- message, with their screen, seconds (a non-number keeps it until closed), and ids.
---@param options? { theme?: ToastTheme } "metal" by default
function toast.install(options)
  local name = options and options.theme or "metal"
  theme = themes[name] or themes.metal
  if not themes[name] then
    require("lib.logger").error(
      "Toast: no theme " .. tostring(name) .. "; use metal, edge, or flat"
    )
  end
  local styled = hs.getObjectMetatable("hs.styledtext")
  local screens, windows = hs.getObjectMetatable("hs.screen"), hs.getObjectMetatable("hs.window")
  local alert = hs.alert
  -- Both hs.alert.show and hs.alert(...) end here. As hs.alert reads its arguments: a screen, or
  -- a window for its screen; a table is a style; anything else the seconds, none or false the
  -- default, another non-number until closed.
  alert.showWithImage = function(message, _, ...)
    local style, screen, seconds
    for _, value in ipairs(table.pack(...)) do
      local kind = getmetatable(value)
      if kind and kind == screens and not screen then
        screen = value
      elseif kind and kind == windows and not screen then
        screen = value:screen()
      elseif type(value) == "table" and not style then
        style = value
      elseif seconds == nil then
        seconds = value
      end
    end
    local text = getmetatable(message) == styled and message:getString() or tostring(message)
    local time = not seconds and 3 or type(seconds) == "number" and seconds or false
    return toast.show(text, { seconds = time, screen = screen })
  end
  alert.closeSpecific = toast.close
  alert.closeAll = function()
    while shown[1] do
      toast.close(shown[1].text)
    end
  end
end

return toast

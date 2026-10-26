-- Raycast-style toasts at the bottom right: the dictation pill's dark face in a choice of rims, or
-- Liquid Glass.
local toast = {}

local limit = 340 -- widest line of text, in points
local margin, gap, padding, icon = 16, 8, 14, 16
local most = 5 -- toasts on a screen; a sixth drops its oldest timed one
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

---@alias ToastTheme "metal"|"edge"|"flat"|"glass"

---@class ToastGlass
---@field hide fun(self: ToastGlass, fade: number)

---@class ToastNative
---@field glass fun(canvas: hs.canvas, radius: number, fade: number): ToastGlass

-- Gray levels of each look: the rim is a gradient at `angle` under the face inset 1 pt, as canvas
-- strokes take no gradient; the face is lit from above.
local themes = {
  -- A glint at the top left and another lower down, like brushed metal.
  metal = { rim = { 0.62, 0.2, 0.42, 0.16 }, angle = 45, face = { 0.2, 0.1 } },
  -- Only the top left catches the light, with a faint rim at the bottom right.
  edge = { rim = { 0.62, 0.2, 0.14, 0.3 }, angle = 45, face = { 0.17, 0.11 } },
  flat = { rim = { 0.24, 0.24 }, angle = 90, face = { 0.13, 0.13 } },
  -- macOS's own Liquid Glass, in a window under the text (lib/toast/toast.m); lighter over a white
  -- window, so its detail is brighter.
  glass = { glass = true, detail = 0.8 },
}
local theme = themes.metal
---@type ToastNative?
local native -- loaded for the glass theme

---@alias ToastSize { w: number, h: number }

---@class ToastEntry
---@field id integer
---@field text string
---@field failure boolean
---@field image boolean
---@field canvas hs.canvas
---@field screen hs.screen
---@field timer? hs.timer
---@field glass? ToastGlass

---@type ToastEntry[]
local shown = {} -- oldest first; each screen's newest sits at its bottom
local count = 0 -- the last toast's id

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

-- By id, which is all the callbacks hold: one holding its own timer is never collected.
---@param id integer?
---@param fade? number seconds, 0.25 by default; none unless it is its screen's oldest
function toast.close(id, fade)
  for i, entry in ipairs(shown) do
    if entry.id == id then
      -- It fades only as the oldest on its screen: otherwise the toasts above move into its place.
      local oldest = true
      for j = 1, i - 1 do
        oldest = oldest and shown[j].screen:id() ~= entry.screen:id()
      end
      table.remove(shown, i)
      if entry.timer then
        entry.timer:stop()
      end
      local seconds = oldest and (fade and math.max(fade, 0) or 0.25) or 0
      entry.canvas:delete(seconds)
      if entry.glass then
        entry.glass:hide(seconds)
      end
      layout()
      return
    end
  end
end

---@param entry ToastEntry
---@param seconds number|false
local function arm(entry, seconds)
  local id = entry.id
  if entry.timer then
    entry.timer:stop()
  end
  entry.timer = seconds and hs.timer.doAfter(seconds, function()
    toast.close(id)
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
  for paragraph in (text:gsub("\n+$", "") .. "\n"):gmatch("([^\n]*)\n") do
    for word in paragraph:gmatch("%S+") do
      local longer = line and line .. " " .. word or word
      -- Measured only while the line may still break: the last one would grow quadratically.
      if line and #out < lines - 1 and size(longer).w > limit then
        out[#out + 1], line = line, word
      else
        line = longer
      end
    end
    -- A line break ends the line, a blank one too, until the last line takes the rest.
    if #out < lines - 1 then
      out[#out + 1], line = line or "", nil
    end
  end
  out[#out + 1] = line
  out[1] = out[1] or ""
  local joined = table.concat(out, "\n")
  return hs.styledtext.new(joined, style), size(joined)
end

---@class ToastOptions
---@field failure? boolean a red cross
---@field seconds? number|false 3 by default; false keeps it until closed
---@field screen? hs.screen the focused window's by default
---@field image? hs.image an icon in place of the red cross

-- Show `text`, titled "Tiling" for "Tiling: no window", and return its id for `close`.
---@param text string
---@param options? ToastOptions
---@return integer?
function toast.show(text, options)
  options = options or {}
  local seconds = options.seconds
  if seconds == nil then
    seconds = 3
  end
  local screen = options.screen or hs.screen.mainScreen()
  if not screen then
    return nil
  end
  local failure = options.failure == true
  -- The same timed toast again, on the same screen, restarts its time instead of stacking; one
  -- kept until closed is its caller's alone, closed by that caller or a click.
  for i, entry in ipairs(shown) do
    local plain = not options.image and not entry.image -- an icon is not repeated
    local same = entry.text == text and entry.failure == failure and plain
    if seconds and entry.timer and same and entry.screen:id() == screen:id() then
      arm(entry, seconds)
      -- Now the newest: at the bottom, and the last its screen's cap drops.
      table.insert(shown, table.remove(shown, i))
      layout()
      return entry.id
    end
  end
  local head, rest = text:match("^([^:\n]+): ([^\n]+)$")
  -- Characters, or bytes if it isn't valid UTF-8 (hs.styledtext shows that too).
  if not head or (utf8.len(head) or #head) > 24 then
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
  local left = padding + ((failure or options.image) and icon + 10 or 0)
  local size, radius = { w = left + width + padding, h = height }, math.min(height / 2, 20)
  canvas:size(size)
  if not theme.glass then
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
  end
  if options.image then
    canvas:appendElements({
      type = "image",
      image = options.image,
      imageScaling = "scaleProportionally",
      frame = { x = padding, y = height / 2 - icon / 2, w = icon, h = icon },
    })
  elseif failure then
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
  -- Every Space, and over full-screen apps while Hammerspoon's Dock icon is hidden.
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  canvas:clickActivating(false)

  -- A click dismisses it.
  canvas:canvasMouseEvents(true, false, false, false)
  count = count + 1
  local id = count
  canvas:mouseCallback(function()
    toast.close(id)
  end)
  local entry = {
    id = id,
    text = text,
    failure = failure,
    image = options.image ~= nil,
    canvas = canvas,
    screen = screen,
  }
  arm(entry, seconds)
  shown[#shown + 1] = entry
  -- Past the cap, the screen's oldest timed toast before this one goes; one kept until closed
  -- stays.
  local on = {}
  for _, other in ipairs(shown) do
    if other.screen:id() == screen:id() then
      on[#on + 1] = other
    end
  end
  if #on > most then
    for i = 1, #on - 1 do
      if on[i].timer then
        toast.close(on[i].id, 0) -- at once: the toast above moves into its place
        break
      end
    end
  end
  layout()
  canvas:show(0.15)
  if theme.glass then
    entry.glass = assert(native).glass(canvas, radius, 0.15)
  end
  return id
end

-- Pick the look, and make every hs.alert a toast: `show`, `hs.alert(...)`, a Spoon's, a hotkey
-- message, with their screen, seconds (a non-number keeps it until closed), and ids.
---@param options? { theme?: ToastTheme } "metal" by default; another name fails the load
function toast.install(options)
  local name = options and options.theme or "metal"
  if not themes[name] then
    local message = "Toast: no theme " .. tostring(name) .. "; use metal, edge, flat, or glass"
    require("lib.logger").error(message)
    error(message, 2)
  end
  if name == "glass" then
    -- Built on first use; utils.native logs a failed build, which fails the load.
    native = native or require("lib.utils").native("toast")
  end
  theme = themes[name]
  detail.color = { white = theme.detail or 0.62 }
  local styled = hs.getObjectMetatable("hs.styledtext")
  local screens, windows = hs.getObjectMetatable("hs.screen"), hs.getObjectMetatable("hs.window")
  local alert = hs.alert
  -- Both hs.alert.show and hs.alert(...) end here. As hs.alert reads its arguments: the first
  -- userdata is the screen, a window here for its screen (hs.alert centers on the window), any
  -- other an error (hs.alert uses a canvas's frame and fails without one); a table is a style;
  -- anything else the seconds, none or false its 2 s default, another non-number until closed.
  -- Styled text keeps its words, not its styles.
  alert.showWithImage = function(message, image, ...)
    local style, screen, seconds
    for i, value in ipairs(table.pack(...)) do
      local kind = getmetatable(value)
      if kind and kind == screens and not screen then
        screen = value
      elseif kind and kind == windows and not screen then
        screen = value:screen()
      elseif type(value) == "userdata" and not screen then
        error(("no screen or window for argument %d"):format(i + 1), 2)
      elseif type(value) == "table" and not style then
        style = value
      elseif seconds == nil then
        seconds = value
      else
        error(("unexpected %s found for argument %d"):format(type(value), i + 1), 2)
      end
    end
    local text = getmetatable(message) == styled and message:getString() or tostring(message)
    local time = not seconds and 2 or type(seconds) == "number" and seconds or false
    return toast.show(text, { seconds = time, screen = screen, image = image })
  end
  alert.closeSpecific = toast.close
  alert.closeAll = function(fade)
    while shown[1] do
      toast.close(shown[1].id, fade)
    end
  end
end

return toast

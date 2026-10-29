local toast = {}

local limit = 340 -- widest text line, pt
local margin, gap, padding, icon = 16, 8, 14, 16
local most = 5 -- toasts per screen
local title = {
  font = { name = ".AppleSystemUIFontMedium", size = 13 },
  paragraphStyle = { lineBreak = "truncateTail" },
}
local detail = {
  font = { name = ".AppleSystemUIFont", size = 12 },
  paragraphStyle = { lineBreak = "truncateTail" },
}
local red = { red = 1, green = 0.27, blue = 0.23 }

---@class ToastGlass
---@field hide fun(self: ToastGlass, fade: number)
---@field paint fun(self: ToastGlass, dark: boolean)

---@class ToastNative
---@field glass fun(canvas: hs.canvas, radius: number, fade: number, dark: boolean): ToastGlass

-- Gray levels.
local themes = {
  metal = {
    angle = 45,
    dark = { rim = { 0.62, 0.2, 0.42, 0.16 }, face = { 0.2, 0.1 }, title = 0.976, detail = 0.62 },
    light = { rim = { 1, 0.62, 0.96, 0.56 }, face = { 0.98, 0.91 }, title = 0.1, detail = 0.2 },
  },
  edge = {
    angle = 45,
    dark = { rim = { 0.62, 0.2, 0.14, 0.3 }, face = { 0.17, 0.11 }, title = 0.976, detail = 0.62 },
    light = { rim = { 1, 0.62, 0.56, 0.68 }, face = { 0.97, 0.92 }, title = 0.1, detail = 0.2 },
  },
  flat = {
    angle = 90,
    dark = { rim = { 0.24, 0.24 }, face = { 0.13, 0.13 }, title = 0.976, detail = 0.62 },
    light = { rim = { 0.78, 0.78 }, face = { 0.95, 0.95 }, title = 0.1, detail = 0.2 },
  },
  glass = {
    glass = true,
    dark = { title = 0.976, detail = 0.95, shadow = { white = 0, alpha = 0.8 } },
    light = { title = 0, detail = 0.1, shadow = { white = 1, alpha = 0.8 } },
  },
}
local theme, dark = themes.metal, true
---@type ToastNative?
local native
---@type hs.distributednotifications?
local watcher

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
---@field radius number
---@field paint fun()

---@type ToastEntry[]
local shown = {} -- oldest first
local count = 0
local held = {}

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

-- By id, as a callback holding its own timer is never collected.
---@param id integer?
---@param fade? number
function toast.close(id, fade)
  local seconds = fade and math.max(fade, 0) or 0.25
  if held[id] then
    return -- its release closes it
  end
  for i, entry in ipairs(shown) do
    if entry.id == id then
      -- Only a screen's oldest fades: the toasts above any other move into its place.
      for j = 1, i - 1 do
        if shown[j].screen:id() == entry.screen:id() then
          seconds = 0
        end
      end
      table.remove(shown, i)
      if entry.timer then
        entry.timer:stop()
      end
      local canvas = entry.canvas
      local from, ends = canvas:alpha(), hs.timer.absoluteTime() + seconds * 1e9
      -- Its fading window ignores clicks only without a callback.
      canvas:mouseCallback(nil)
      -- By hand: hs.canvas's fade orders out, then restores the starting alpha.
      local function step()
        local left = ends - hs.timer.absoluteTime()
        if left > 0 then
          canvas:alpha(from * (left / seconds / 1e9) ^ 2)
          entry.timer = hs.timer.doAfter(1 / 60, step)
        else
          entry.timer = nil -- else never collected
          -- The window server puts back a window ordered out under a held left click.
          canvas:alpha(0)
          canvas:delete()
        end
      end
      step()
      if entry.glass then
        entry.glass:hide(seconds)
      end
      layout()
      return
    end
  end
end

local types = hs.eventtap.event.types
local ups = { [types.leftMouseUp] = true, [types.rightMouseUp] = true, [types.otherMouseUp] = true }
local clicked, dropped = false, {}
-- Drops the rest of a multi-click that closed a toast, each up with its down.
local tap = hs.eventtap.new({
  types.leftMouseDown,
  types.leftMouseUp,
  types.rightMouseDown,
  types.rightMouseUp,
  types.otherMouseDown,
  types.otherMouseUp,
}, function(event)
  local button = event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
  if ups[event:getType()] then
    local drop = dropped[button]
    dropped[button] = nil
    return drop
  end
  local drop = clicked and event:getProperty(hs.eventtap.event.properties.mouseEventClickState) > 1
  clicked, dropped[button] = drop, drop
  return drop
end)

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
      -- Not measured on the last line, which would be quadratic.
      if line and #out < lines - 1 and size(longer).w > limit then
        out[#out + 1], line = line, word
      else
        line = longer
      end
    end
    if #out < lines - 1 then
      out[#out + 1], line = line or "", nil
    end
  end
  out[#out + 1] = line
  local joined = table.concat(out, "\n")
  return joined, size(joined)
end

---@class ToastOptions
---@field failure? boolean
---@field seconds? number|false false: until closed
---@field screen? hs.screen
---@field image? hs.image

-- "Tiling: no window" shows "Tiling" over "No window".
---@param text string
---@param options? ToastOptions
---@return integer?
function toast.show(text, options)
  options = options or {}
  local seconds = options.seconds
  if seconds == nil then
    seconds = 3
  end
  local screen = options.screen or hs.screen.find(hs.spaces.spaceDisplay(hs.spaces.focusedSpace()))
  if not screen then
    -- Not raised or sent to logger.error, which toasts; hs.ipc's print can raise.
    pcall(print, "Toast: no focused display: " .. text)
    return nil
  end
  local failure = options.failure == true
  for i, entry in ipairs(shown) do
    local plain = not options.image and not entry.image
    local same = entry.text == text and entry.failure == failure and plain
    if seconds and entry.timer and same and entry.screen:id() == screen:id() then
      arm(entry, seconds)
      table.insert(shown, table.remove(shown, i))
      layout()
      return entry.id
    end
  end
  local head, rest = text:match("^([^:\n]+): ([^\n]+)$")
  if not head or (utf8.len(head) or #head) > 24 then
    head, rest = text, nil
  end
  -- Capitalized, but "macOS" stays.
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
  local function paint()
    local look = theme[dark and "dark" or "light"]
    local shadow = look.shadow
      and { offset = { h = 0, w = 0 }, blurRadius = 4, color = look.shadow }
    title.color, title.shadow = { white = look.title }, shadow
    detail.color, detail.shadow = { white = look.detail }, shadow
    local elements = {}
    if look.rim then
      elements[1] = {
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = radius, yRadius = radius },
        fillGradient = "linear",
        fillGradientColors = grays(look.rim),
        fillGradientAngle = theme.angle,
      }
      elements[2] = {
        type = "rectangle",
        action = "fill",
        frame = { x = 1, y = 1, w = size.w - 2, h = size.h - 2 },
        roundedRectRadii = { xRadius = radius - 1, yRadius = radius - 1 },
        fillGradient = "linear",
        fillGradientColors = grays(look.face),
        fillGradientAngle = 90,
      }
    end
    if options.image then
      elements[#elements + 1] = {
        type = "image",
        image = options.image,
        imageScaling = "scaleProportionally",
        frame = { x = padding, y = height / 2 - icon / 2, w = icon, h = icon },
      }
    elseif failure then
      local x, y, reach = padding + icon / 2, height / 2, icon * 0.18
      elements[#elements + 1] = {
        type = "circle",
        action = "fill",
        center = { x = x, y = y },
        radius = icon / 2,
        fillColor = red,
      }
      for _, sign in ipairs({ 1, -1 }) do
        elements[#elements + 1] = {
          type = "segments",
          action = "stroke",
          coordinates = {
            { x = x - reach, y = y - sign * reach },
            { x = x + reach, y = y + sign * reach },
          },
          strokeColor = { white = 1 },
          strokeWidth = 1.6,
          strokeCapStyle = "round",
        }
      end
    end
    -- +1 pt: a line exactly as wide as its frame wraps.
    elements[#elements + 1] = {
      type = "text",
      text = hs.styledtext.new(heading, title),
      frame = { x = left, y = 12, w = width + 1, h = top.h },
    }
    if below then
      elements[#elements + 1] = {
        type = "text",
        text = hs.styledtext.new(body, detail),
        frame = { x = left, y = 12 + top.h + 2, w = width + 1, h = below.h },
      }
    end
    canvas:replaceElements(elements)
  end
  paint()
  canvas:level(hs.canvas.windowLevels.dock - 1)
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  canvas:clickActivating(false)

  -- Closes on release, as a held left click would put its window back.
  canvas:canvasMouseEvents(true, true, false, false)
  count = count + 1
  local id = count
  canvas:mouseCallback(function(_, message)
    held[id] = message == "mouseDown" or nil
    if held[id] then
      return
    end
    toast.close(id)
    clicked = true
    -- Never stopped: stopping it from its callback drops that click's mouse-up.
    tap:start()
  end)
  local entry = {
    id = id,
    text = text,
    failure = failure,
    image = options.image ~= nil,
    canvas = canvas,
    screen = screen,
    radius = radius,
    paint = paint,
  }
  arm(entry, seconds)
  shown[#shown + 1] = entry
  local on = {}
  for _, other in ipairs(shown) do
    if other.screen:id() == screen:id() then
      on[#on + 1] = other
    end
  end
  if #on > most then
    for i = 1, #on - 1 do
      if on[i].timer and not held[on[i].id] then
        toast.close(on[i].id, 0) -- at once: the stack shifts into its place
        break
      end
    end
  end
  layout()
  canvas:show(0.15)
  if theme.glass then
    entry.glass = assert(native).glass(canvas, radius, 0.15, dark)
  end
  return id
end

local function repaint()
  for _, entry in ipairs(shown) do
    entry.paint()
    if entry.glass and not theme.glass then
      entry.glass:hide(0)
      entry.glass = nil
    elseif entry.glass then
      entry.glass:paint(dark)
    elseif theme.glass then
      entry.glass = assert(native).glass(entry.canvas, entry.radius, 0, dark)
    end
  end
end

-- Makes every hs.alert a toast.
---@param options? { theme?: "metal"|"edge"|"flat"|"glass", appearance?: "system"|"light"|"dark" }
function toast.install(options)
  options = options or {}
  local name, appearance = options.theme or "metal", options.appearance or "system"
  local problem
  if not themes[name] then
    problem = "Toast: no theme " .. tostring(name) .. "; use metal, edge, flat, or glass"
  elseif not ({ system = true, light = true, dark = true })[appearance] then
    problem = "Toast: no appearance " .. tostring(appearance) .. "; use system, light, or dark"
  end
  if problem then
    require("lib.logger").error(problem)
    error(problem, 2)
  end
  if name == "glass" then
    native = require("lib.utils").native("toast")
  end
  theme = themes[name]
  if watcher then
    watcher:stop()
    watcher = nil
  end
  if appearance == "system" then
    watcher = hs.distributednotifications.new(function()
      dark = hs.host.interfaceStyle() == "Dark"
      repaint()
    end, "AppleInterfaceThemeChangedNotification")
    ---@cast watcher hs.distributednotifications
    watcher:start()
  end
  dark = appearance == "dark" or appearance == "system" and hs.host.interfaceStyle() == "Dark"
  repaint()
  local styled = hs.getObjectMetatable("hs.styledtext")
  local screens, windows = hs.getObjectMetatable("hs.screen"), hs.getObjectMetatable("hs.window")
  local alert = hs.alert
  -- Parsed as hs.alert does, but a window means its screen and styled text loses its styles.
  alert.showWithImage = function(message, image, ...)
    local style, screen, seconds
    for i, value in ipairs(table.pack(...)) do
      local kind = getmetatable(value)
      if kind == screens and not screen then
        screen = value
      elseif kind == windows and not screen then
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
    fade = fade and math.max(fade, 0) -- raises with none shown too
    for _, entry in ipairs({ table.unpack(shown) }) do
      toast.close(entry.id, fade)
    end
  end
end

return toast

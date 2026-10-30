local toast = {}

local maxTextWidth = 340 -- pt
local screenMargin, stackGap, padding, iconSize = 16, 8, 14, 16
local maxToastsPerScreen = 5
local titleStyle = {
  font = { name = ".AppleSystemUIFontMedium", size = 13 },
  paragraphStyle = { lineBreak = "truncateTail" },
}
local detailStyle = {
  font = { name = ".AppleSystemUIFont", size = 12 },
  paragraphStyle = { lineBreak = "truncateTail" },
}
local failureRed = { red = 1, green = 0.27, blue = 0.23 }

---@class ToastGlass
---@field hide fun(self: ToastGlass, fadeSeconds: number)
---@field paint fun(self: ToastGlass, darkAppearance: boolean)

---@class ToastNative
---@field glass fun(canvas: hs.canvas, cornerRadius: number, fadeSeconds: number, darkAppearance: boolean): ToastGlass

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
local theme, darkAppearance = themes.metal, true
---@type ToastNative?
local native
---@type hs.distributednotifications?
local appearanceWatcher

---@alias ToastSize { w: number, h: number }

---@class ToastEntry
---@field id integer
---@field text string
---@field failure boolean
---@field hasImage boolean
---@field canvas hs.canvas
---@field screen hs.screen
---@field timer? hs.timer
---@field glass? ToastGlass
---@field paint fun(fadeSeconds: number)

---@type ToastEntry[]
local shownToasts = {} -- oldest first
local lastToastId = 0
local heldIds = {}

local function grayColors(levels)
  local colors = {}
  for index, level in ipairs(levels) do
    colors[index] = { white = level }
  end
  return colors
end

local function layout()
  local nextBottomByScreen = {}
  for index = #shownToasts, 1, -1 do
    local entry = shownToasts[index]
    local screenFrame, canvasSize = entry.screen:frame(), entry.canvas:size() --[[@as ToastSize]]
    local screenId = entry.screen:id()
    local toastTop = (nextBottomByScreen[screenId] or screenFrame.y + screenFrame.h - screenMargin)
      - canvasSize.h
    entry.canvas:topLeft({
      x = screenFrame.x + screenFrame.w - screenMargin - canvasSize.w,
      y = toastTop,
    })
    nextBottomByScreen[screenId] = toastTop - stackGap
  end
end

-- By id, as a callback holding its own timer is never collected.
---@param id integer?
---@param fade? number
function toast.close(id, fade)
  local fadeSeconds = fade and math.max(fade, 0) or 0.25
  if heldIds[id] then
    return -- its release closes it
  end
  for index, entry in ipairs(shownToasts) do
    if entry.id == id then
      -- Only a screen's oldest fades: the toasts above any other move into its place.
      for olderIndex = 1, index - 1 do
        if shownToasts[olderIndex].screen:id() == entry.screen:id() then
          fadeSeconds = 0
        end
      end
      table.remove(shownToasts, index)
      if entry.timer then
        entry.timer:stop()
      end
      local canvas = entry.canvas
      local startAlpha, fadeEndNs = canvas:alpha(), hs.timer.absoluteTime() + fadeSeconds * 1e9
      -- Its fading window ignores clicks only without a callback.
      canvas:mouseCallback(nil)
      -- By hand: hs.canvas's fade orders out, then restores the starting alpha.
      local function fadeStep()
        local remainingNs = fadeEndNs - hs.timer.absoluteTime()
        if remainingNs > 0 then
          canvas:alpha(startAlpha * (remainingNs / fadeSeconds / 1e9) ^ 2)
          entry.timer = hs.timer.doAfter(1 / 60, fadeStep)
        else
          entry.timer = nil -- else never collected
          -- The window server puts back a window ordered out under a held left click.
          canvas:alpha(0)
          canvas:delete()
        end
      end
      fadeStep()
      if entry.glass then
        entry.glass:hide(fadeSeconds)
      end
      layout()
      return
    end
  end
end

local types = hs.eventtap.event.types
local mouseUpTypes =
  { [types.leftMouseUp] = true, [types.rightMouseUp] = true, [types.otherMouseUp] = true }
local closedByButton, droppedDowns, lastUpButton = {}, {}, "any"
-- Drops the rest of a multi-click that closed a toast, each up with its down.
local multiClickTap = hs.eventtap.new({
  types.leftMouseDown,
  types.leftMouseUp,
  types.rightMouseDown,
  types.rightMouseUp,
  types.otherMouseDown,
  types.otherMouseUp,
}, function(event)
  local button = event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber)
  if mouseUpTypes[event:getType()] then
    lastUpButton = button
    local dropUp = droppedDowns[button]
    droppedDowns[button] = nil
    return dropUp
  end
  local clickState = event:getProperty(hs.eventtap.event.properties.mouseEventClickState)
  local dropDown = (closedByButton[button] or closedByButton.any) and clickState > 1
  closedByButton[button], closedByButton.any, droppedDowns[button] = dropDown, nil, dropDown
  return dropDown
end)

---@param entry ToastEntry
---@param seconds number|false
local function restartTimeout(entry, seconds)
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
---@param maxLines integer
local function wrap(canvas, text, style, maxLines)
  local function measure(value)
    return canvas:minimumTextSize(hs.styledtext.new(value, style)) --[[@as ToastSize]]
  end
  local wrapped, line = {}, nil
  for paragraph in (text:gsub("\n+$", "") .. "\n"):gmatch("([^\n]*)\n") do
    for word in paragraph:gmatch("%S+") do
      local extendedLine = line and line .. " " .. word or word
      -- Not measured on the last line, which would be quadratic.
      if line and #wrapped < maxLines - 1 and measure(extendedLine).w > maxTextWidth then
        wrapped[#wrapped + 1], line = line, word
      else
        line = extendedLine
      end
    end
    if #wrapped < maxLines - 1 then
      wrapped[#wrapped + 1], line = line or "", nil
    end
  end
  wrapped[#wrapped + 1] = line
  local wrappedText = table.concat(wrapped, "\n")
  return wrappedText, measure(wrappedText)
end

local function enforceCap()
  local stacksByScreen = {}
  for _, entry in ipairs(shownToasts) do
    local screenId = entry.screen:id()
    stacksByScreen[screenId] = stacksByScreen[screenId] or {}
    table.insert(stacksByScreen[screenId], entry)
  end
  for _, stack in pairs(stacksByScreen) do
    local excess = #stack - maxToastsPerScreen
    for index = 1, #stack - 1 do
      if excess > 0 and stack[index].timer and not heldIds[stack[index].id] then
        toast.close(stack[index].id, 0) -- at once: the stack shifts into its place
        excess = excess - 1
      end
    end
  end
end

toast.screenWatcher = hs.screen.watcher
  .new(function()
    local primaryScreen = hs.screen.primaryScreen()
    for _, entry in ipairs(shownToasts) do
      entry.screen = hs.screen.find(entry.screen:id()) or primaryScreen or entry.screen
    end
    enforceCap()
    layout()
  end)
  :start() --[[@as hs.screen.watcher]]

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
  for index, entry in ipairs(shownToasts) do
    local bothPlain = not options.image and not entry.hasImage
    local sameToast = entry.text == text and entry.failure == failure and bothPlain
    if seconds and entry.timer and sameToast and entry.screen:id() == screen:id() then
      restartTimeout(entry, seconds)
      table.insert(shownToasts, table.remove(shownToasts, index))
      layout()
      return entry.id
    end
  end
  local titleText, detailText = text:match("^([^:\n]+): ([^\n]+)$")
  if not titleText or (utf8.len(titleText) or #titleText) > 24 then
    titleText, detailText = text, nil
  end
  -- Capitalized, but "macOS" stays.
  detailText = detailText
    and detailText:gsub("^(%l)(%l*%f[^%w])", function(firstLetter, restOfWord)
      return firstLetter:upper() .. restOfWord
    end)

  local canvas = hs.canvas.new({ x = 0, y = 0, w = 1, h = 1 }) --[[@as hs.canvas]]
  local wrappedTitle, titleSize = wrap(canvas, titleText, titleStyle, detailText and 1 or 3)
  local wrappedDetail, detailSize
  if detailText then
    wrappedDetail, detailSize = wrap(canvas, detailText, detailStyle, 3)
  end
  local textWidth = math.min(maxTextWidth, math.max(titleSize.w, detailSize and detailSize.w or 0))
  local canvasHeight = 2 * 12 + titleSize.h + (detailSize and 2 + detailSize.h or 0)
  local textLeft = padding + ((failure or options.image) and iconSize + 10 or 0)
  local canvasSize, cornerRadius =
    { w = textLeft + textWidth + padding, h = canvasHeight }, math.min(canvasHeight / 2, 20)
  canvas:size(canvasSize)
  lastToastId = lastToastId + 1
  local id = lastToastId
  local entry = {
    id = id,
    text = text,
    failure = failure,
    hasImage = options.image ~= nil,
    canvas = canvas,
    screen = screen,
  }
  function entry.paint(fadeSeconds)
    local palette = theme[darkAppearance and "dark" or "light"]
    local textShadow = palette.shadow
      and { offset = { h = 0, w = 0 }, blurRadius = 4, color = palette.shadow }
    titleStyle.color, titleStyle.shadow = { white = palette.title }, textShadow
    detailStyle.color, detailStyle.shadow = { white = palette.detail }, textShadow
    local elements = {}
    if palette.rim then
      elements[1] = {
        type = "rectangle",
        action = "fill",
        roundedRectRadii = { xRadius = cornerRadius, yRadius = cornerRadius },
        fillGradient = "linear",
        fillGradientColors = grayColors(palette.rim),
        fillGradientAngle = theme.angle,
      }
      elements[2] = {
        type = "rectangle",
        action = "fill",
        frame = { x = 1, y = 1, w = canvasSize.w - 2, h = canvasSize.h - 2 },
        roundedRectRadii = { xRadius = cornerRadius - 1, yRadius = cornerRadius - 1 },
        fillGradient = "linear",
        fillGradientColors = grayColors(palette.face),
        fillGradientAngle = 90,
      }
    end
    if options.image then
      elements[#elements + 1] = {
        type = "image",
        image = options.image,
        imageScaling = "scaleProportionally",
        frame = { x = padding, y = canvasHeight / 2 - iconSize / 2, w = iconSize, h = iconSize },
      }
    elseif failure then
      local crossX, crossY, crossReach = padding + iconSize / 2, canvasHeight / 2, iconSize * 0.18
      elements[#elements + 1] = {
        type = "circle",
        action = "fill",
        center = { x = crossX, y = crossY },
        radius = iconSize / 2,
        fillColor = failureRed,
      }
      for _, diagonal in ipairs({ 1, -1 }) do
        elements[#elements + 1] = {
          type = "segments",
          action = "stroke",
          coordinates = {
            { x = crossX - crossReach, y = crossY - diagonal * crossReach },
            { x = crossX + crossReach, y = crossY + diagonal * crossReach },
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
      text = hs.styledtext.new(wrappedTitle, titleStyle),
      frame = { x = textLeft, y = 12, w = textWidth + 1, h = titleSize.h },
    }
    if detailSize then
      elements[#elements + 1] = {
        type = "text",
        text = hs.styledtext.new(wrappedDetail, detailStyle),
        frame = { x = textLeft, y = 12 + titleSize.h + 2, w = textWidth + 1, h = detailSize.h },
      }
    end
    canvas:replaceElements(elements)
    if entry.glass and not theme.glass then
      entry.glass:hide(0)
      entry.glass = nil
    elseif entry.glass then
      entry.glass:paint(darkAppearance)
    elseif theme.glass then
      entry.glass = assert(native).glass(canvas, cornerRadius, fadeSeconds, darkAppearance)
    end
  end
  canvas:level(hs.canvas.windowLevels.dock - 1)
  canvas:behaviorAsLabels({ "canJoinAllSpaces", "stationary", "fullScreenAuxiliary" })
  canvas:clickActivating(false)

  -- Closes on release, as a held left click would put its window back.
  canvas:canvasMouseEvents(true, true, false, false)
  canvas:mouseCallback(function(_, message)
    heldIds[id] = message == "mouseDown" or nil
    if heldIds[id] then
      -- A tap started now can miss a quick click's up, leaving the button unknown.
      -- Never stopped: stopping it from its callback drops an up.
      lastUpButton = "any"
      multiClickTap:start()
      return
    end
    toast.close(id)
    closedByButton[lastUpButton] = true
  end)
  restartTimeout(entry, seconds)
  shownToasts[#shownToasts + 1] = entry
  enforceCap()
  layout()
  canvas:show(0.15)
  entry.paint(0.15)
  return id
end

local function repaint()
  for _, entry in ipairs(shownToasts) do
    entry.paint(0)
  end
end

-- Makes every hs.alert a toast.
---@param options? { theme?: "metal"|"edge"|"flat"|"glass", appearance?: "system"|"light"|"dark" }
function toast.install(options)
  options = options or {}
  local themeName, appearance = options.theme or "metal", options.appearance or "system"
  local problem
  if not themes[themeName] then
    problem = "Toast: no theme " .. tostring(themeName) .. "; use metal, edge, flat, or glass"
  elseif not ({ system = true, light = true, dark = true })[appearance] then
    problem = "Toast: no appearance " .. tostring(appearance) .. "; use system, light, or dark"
  end
  if problem then
    require("lib.logger").error(problem)
    error(problem, 2)
  end
  if themeName == "glass" then
    native = require("lib.utils").native("toast")
  end
  theme = themes[themeName]
  if appearanceWatcher then
    appearanceWatcher:stop()
    appearanceWatcher = nil
  end
  if appearance == "system" then
    appearanceWatcher = hs.distributednotifications.new(function()
      darkAppearance = hs.host.interfaceStyle() == "Dark"
      repaint()
    end, "AppleInterfaceThemeChangedNotification")
    ---@cast appearanceWatcher hs.distributednotifications
    appearanceWatcher:start()
  end
  darkAppearance = appearance == "dark"
    or appearance == "system" and hs.host.interfaceStyle() == "Dark"
  repaint()
  local styledTextMetatable = hs.getObjectMetatable("hs.styledtext")
  local screenMetatable, windowMetatable =
    hs.getObjectMetatable("hs.screen"), hs.getObjectMetatable("hs.window")
  local alert = hs.alert
  -- Parsed as hs.alert does, but a window means its screen and styled text loses its styles.
  alert.showWithImage = function(message, image, ...)
    local style, screen, seconds
    for index, argument in ipairs(table.pack(...)) do
      local metatable = getmetatable(argument)
      if metatable == screenMetatable and not screen then
        screen = argument
      elseif metatable == windowMetatable and not screen then
        screen = argument:screen()
      elseif type(argument) == "userdata" and not screen then
        error(("no screen or window for argument %d"):format(index + 1), 2)
      elseif type(argument) == "table" and not style then
        style = argument
      elseif seconds == nil then
        seconds = argument
      else
        error(("unexpected %s found for argument %d"):format(type(argument), index + 1), 2)
      end
    end
    local text = getmetatable(message) == styledTextMetatable and message:getString()
      or tostring(message)
    local duration = not seconds and 2 or type(seconds) == "number" and seconds or false
    return toast.show(text, { seconds = duration, screen = screen, image = image })
  end
  alert.closeSpecific = toast.close
  alert.closeAll = function(fade)
    fade = fade and math.max(fade, 0) -- raises with none shown too
    for _, entry in ipairs({ table.unpack(shownToasts) }) do
      toast.close(entry.id, fade)
    end
  end
end

return toast

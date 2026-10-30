local filter = require("lib.window_filter")
local previews = require("lib.previews")
local windowManager = require("lib.window_manager")
local switcher = {}
local types, keys = hs.eventtap.event.types, hs.keycodes.map
local properties = hs.eventtap.event.properties
local cycle, operation, queuedWindow
local recent, snapshots, icons = {}, {}, {}
local captures = {}
local eye = assert(
  hs.image.imageFromPath(hs.configdir .. "/assets/eye-closed.svg"),
  "Could not load hidden window icon"
)
local minimize = assert(
  hs.image.imageFromPath(hs.configdir .. "/assets/minimize.svg"),
  "Could not load minimized window icon"
)
local swallowed = {}
local stopped = false
local menuDelay = 0.2

local function isPiP(title)
  title = (title or ""):lower():gsub("[^%a]", "")
  return title == "pictureinpicture" or title == "pip"
end

local function eligible(window)
  if not window["root-window"] or window.app == "Hammerspoon" or isPiP(window.title) then
    return false
  end
  if filter.blacklist[window.subrole] then
    return window.subrole == "AXDialog" and switcher.windows:getWindow(window.id, window.pid) ~= nil
  end
  return window.role == "AXWindow"
end

---@param rows table[]
---@return table[]
local function describe(rows)
  local focused = hs.window.focusedWindow()
  local focusedID = focused and focused:id()
  local apps, windows = {}, {}
  for _, row in ipairs(rows) do
    local app = apps[row.pid]
    if app == nil then
      app = hs.application.applicationForPID(row.pid) or false
      apps[row.pid] = app
    end
    if app then
      windows[#windows + 1] = {
        id = row.id,
        pid = row.pid,
        app = app:name(),
        bundle = app:bundleID(),
        title = row.title,
        role = row.role,
        subrole = row.subrole,
        ["root-window"] = row.root,
        ["has-focus"] = row.id == focusedID,
        ["is-minimized"] = row.minimized,
        ["is-hidden"] = app:isHidden(),
      }
    end
  end
  return windows
end

-- Keyed by bundle: macOS can reuse an exited app's PID.
local function icon(window)
  if window.bundle and not icons[window.bundle] then
    icons[window.bundle] = hs.image.imageFromAppBundle(window.bundle)
  end
  return icons[window.bundle]
end

local function hide()
  if switcher.mouseTap then
    switcher.mouseTap:stop()
  end
  if switcher.canvas then
    switcher.canvas:hide()
  end
end

local function layout(screen, count)
  local width, height = screen.w * 0.85, screen.h * 0.85
  local preferred = math.max(220, math.min(320, 246 * math.min(screen.w, screen.h) / 1074))
  local minimum = math.floor(math.min(180, width - 32, 16 + (height - 72) * 16 / 9))
  local columns = math.min(count, math.max(1, math.floor((width - 20) / (minimum + 12))))
  local rows = math.max(1, math.floor((height - 20) / ((minimum - 16) * 9 / 16 + 52)))
  local best
  for limit = 1, columns do
    local total = math.ceil(count / limit)
    local across = math.ceil(count / total)
    local perRow, extra = math.floor(count / total), count % total
    for visible = 1, math.min(total, rows) do
      local size = math.floor(
        math.min(
          preferred,
          (width - 32 - (across - 1) * 12) / across,
          16 + ((height - 32 - (visible - 1) * 12) / visible - 40) * 16 / 9
        ) + 1e-6
      )
      local shown = visible * perRow + math.min(visible, extra)
      if
        size >= minimum
        and (
          not best
          or shown > best.shown
          or (
            shown == best.shown
            and (size > best.size or (size == best.size and visible < best.rows))
          )
        )
      then
        best = { total = total, columns = across, rows = visible, size = size, shown = shown }
      end
    end
  end
  assert(best, "Window switcher has no usable display area")
  best.count, best.width, best.height = count, screen.w, screen.h
  return best
end

local function draw(current)
  if cycle ~= current or not current.windows then
    return
  end
  local windows, selected = current.windows, current.selected
  if not windows[selected] then
    return
  end
  local screen = current.screen
  local grid = current.layout
  if not grid or grid.count ~= #windows or grid.width ~= screen.w or grid.height ~= screen.h then
    grid = layout(screen, #windows)
    current.layout = grid
  end
  local padding, gap = 16, 12
  local columns, totalRows = grid.columns, grid.total
  local perRow, extraRows = math.floor(#windows / totalRows), #windows % totalRows
  -- First rows take the remainder, one extra window each.
  local function firstInRow(row)
    return row * perRow + math.min(row, extraRows) + 1
  end
  local function rowForWindow(index)
    local extraWindows = extraRows * (perRow + 1)
    if index <= extraWindows then
      return math.floor((index - 1) / (perRow + 1))
    end
    return extraRows + math.floor((index - extraWindows - 1) / perRow)
  end
  local cardWidth = grid.size
  local cardHeight = math.floor((cardWidth - 16) * 9 / 16) + 40
  local rows = grid.rows
  local rowHeight = cardHeight + gap
  local viewportHeight = rows * rowHeight - gap
  current.maxScroll = (totalRows - rows) * rowHeight
  current.scrollOffset = math.max(0, math.min(current.maxScroll, current.scrollOffset or 0))
  if current.revealSelected then
    local top = rowForWindow(selected) * rowHeight
    if top < current.scrollOffset then
      current.scrollOffset = top
    elseif top + cardHeight > current.scrollOffset + viewportHeight then
      current.scrollOffset = top + cardHeight - viewportHeight
    end
    current.revealSelected = false
  end
  local first = firstInRow(math.floor(current.scrollOffset / rowHeight))
  local last = math.min(
    #windows,
    firstInRow(math.ceil((current.scrollOffset + viewportHeight) / rowHeight)) - 1
  )
  local width = padding * 2 + columns * cardWidth + (columns - 1) * gap
  local height = padding * 2 + viewportHeight
  current.cards = {}
  current.frame = {
    x = screen.x + (screen.w - width) / 2,
    y = screen.y + (screen.h - height) / 2,
    w = width,
    h = height,
  }
  local elements = {}
  local function add(element)
    elements[#elements + 1] = element
  end
  local function rect(id, x, y, w, h, fill, stroke)
    add({
      id = id,
      type = "rectangle",
      action = stroke and "strokeAndFill" or "fill",
      frame = { x = x, y = y, w = w, h = h },
      roundedRectRadii = { xRadius = 12, yRadius = 12 },
      fillColor = fill,
      strokeColor = stroke,
      strokeWidth = 2,
    })
  end
  local function picture(value, x, y, w, h, alpha, id)
    if value then
      add({
        id = id,
        type = "image",
        image = value,
        imageAlpha = alpha,
        imageScaling = "scaleProportionally",
        frame = { x = x, y = y, w = w, h = h },
      })
    end
  end
  rect("background", 0, 0, width, height, { white = 0.08, alpha = 0.98 })
  add({
    type = "rectangle",
    action = "clip",
    frame = {
      x = padding - 1,
      y = padding - 1,
      w = width - padding * 2 + 2,
      h = viewportHeight + 2,
    },
  })
  for index = first, last do
    local window = windows[index]
    local row = rowForWindow(index)
    local rowColumns = perRow + (row < extraRows and 1 or 0)
    local rowWidth = rowColumns * cardWidth + (rowColumns - 1) * gap
    local x = (width - rowWidth) / 2 + (index - firstInRow(row)) * (cardWidth + gap)
    local y = padding + row * rowHeight - current.scrollOffset
    local hitY = math.max(padding, y)
    local hitHeight = math.max(0, math.min(y + cardHeight, padding + viewportHeight) - hitY)
    current.cards[#current.cards + 1] = {
      index = index,
      x = x,
      y = hitY,
      w = cardWidth,
      h = hitHeight,
    }
    rect(
      "window-" .. index,
      x,
      y,
      cardWidth,
      cardHeight,
      { white = index == selected and 0.23 or 0.12 },
      index == selected and { red = 0.35, green = 0.65, blue = 1 } or nil
    )
    local image = current.images[window.id]
    local opacity = (window["is-hidden"] or window["is-minimized"]) and 0.20 or 1
    local previewWidth = image and cardWidth - 16 or 52
    local previewHeight = image and cardHeight - 40 or 52
    local centerX, centerY = x + cardWidth / 2, y + 8 + (cardHeight - 40) / 2
    if opacity < 1 and image then
      -- Fade toward black so dark previews do not brighten against the card.
      local size = image:size()
      local fit = math.min(previewWidth / size.w, previewHeight / size.h)
      add({
        id = "dim-" .. index,
        type = "rectangle",
        action = "fill",
        fillColor = { white = 0 },
        frame = {
          x = centerX - size.w * fit / 2,
          y = centerY - size.h * fit / 2,
          w = size.w * fit,
          h = size.h * fit,
        },
      })
    end
    picture(
      image or icon(window),
      centerX - previewWidth / 2,
      centerY - previewHeight / 2,
      previewWidth,
      previewHeight,
      opacity
    )
    if opacity < 1 then
      picture(
        window["is-minimized"] and minimize or eye,
        centerX - 12,
        centerY - 12,
        24,
        24,
        1,
        "state-" .. index
      )
    end
    local label = window.app
    if window.title ~= "" and window.title ~= window.app then
      label = label .. " · " .. window.title
    end
    picture(icon(window), x + 10, y + cardHeight - 24, 16, 16)
    add({
      id = "label-" .. index,
      type = "text",
      text = label,
      textSize = 11,
      textFont = ".AppleSystemUIFont",
      textColor = { white = 0.82 },
      textLineBreak = "truncateTail",
      frame = { x = x + 32, y = y + cardHeight - 24, w = cardWidth - 42, h = 18 },
    })
  end
  add({ type = "resetClip" })
  if current.maxScroll > 0 then
    local thumbHeight =
      math.max(24, viewportHeight * viewportHeight / (totalRows * rowHeight - gap))
    local thumbY = padding
      + (viewportHeight - thumbHeight) * current.scrollOffset / current.maxScroll
    rect("scrollbar", width - 8, thumbY, 3, thumbHeight, { white = 0.5, alpha = 0.7 })
  end
  add({
    id = "select",
    type = "rectangle",
    action = "fill",
    fillColor = { alpha = 0 },
    frame = { x = 0, y = 0, w = width, h = height },
    trackMouseUp = true,
  })
  switcher.canvas:frame(current.frame)
  switcher.canvas:replaceElements(elements)
  switcher.canvas:show()
  switcher.mouseTap:start()
end

local show
show = function(current)
  if current.renderTimer then
    return
  end
  current.renderTimer = hs.timer.doAfter(0, function()
    current.renderTimer = nil
    if cycle ~= current or not current.windows or current.released then
      return
    end
    for _, window in ipairs(current.windows) do
      local cached = snapshots[window.id]
      if not current.images[window.id] and cached and cached.pid == window.pid then
        current.images[window.id] = cached.image
      end
    end
    current.pointer = current.pointer or hs.mouse.absolutePosition()
    draw(current)
    if not hs.screenRecordingState() then
      return
    end
    local ordered, wanted = {}, {}
    local function include(window)
      if window["is-minimized"] or window["is-hidden"] then
        return
      end
      local capture = captures[window.id]
      if capture then
        capture.cancel()
        captures[window.id] = nil
      end
      if not wanted[window.id] then
        ordered[#ordered + 1] = window
        wanted[window.id] = window
      end
    end
    include(current.windows[current.selected])
    for _, card in ipairs(current.cards) do
      if card.h > 0 then
        include(current.windows[card.index])
      end
    end
    local request, changed = current.capture, false
    if request then
      local selected = current.windows[current.selected].id
      changed = request.pending[selected] ~= nil and request.selected ~= selected
      for id, window in pairs(wanted) do
        changed = changed or current.prepared[id] ~= window
      end
      for id, window in pairs(request.pending) do
        changed = changed or wanted[id] ~= window
      end
      if not changed then
        return
      end
      -- Superseded work cannot delay captures for a new viewport.
      request.cancel()
      for id, window in pairs(request.pending) do
        if current.prepared[id] == window then
          current.prepared[id] = nil
        end
      end
      current.capture = nil
    end
    local pending = {}
    request = { pending = {} }
    for _, window in ipairs(ordered) do
      if current.prepared[window.id] ~= window then
        pending[#pending + 1] = window
        request.pending[window.id] = window
        current.prepared[window.id] = window
      end
    end
    if #pending == 0 then
      return
    end
    request.selected = pending[1].id
    current.capture = request
    local ok, cancel = pcall(previews.capture, pending, function(id, image)
      if cycle ~= current or current.released or current.capture ~= request then
        return
      end
      if not id then
        current.capture = nil
        return
      end
      local window = request.pending[id]
      request.pending[id] = nil
      if not window or current.prepared[id] ~= window then
        return
      end
      if image then
        snapshots[id] = { image = image, pid = window.pid }
        current.images[id] = image
      end
      show(current)
    end)
    if ok then
      request.cancel = cancel
    else
      current.capture = nil
    end
  end)
end

local function stopDrawing(current)
  if current then
    if current.delayTimer then
      current.delayTimer:stop()
      current.delayTimer = nil
    end
    if current.renderTimer then
      current.renderTimer:stop()
      current.renderTimer = nil
    end
    if current.capture then
      current.capture.cancel()
      current.capture = nil
    end
  end
end

local focus
local function finish(job, message)
  if operation ~= job then
    return
  end
  job.deadline:stop()
  job.deadline = nil
  if job.watcher then
    job.watcher:stop()
    job.watcher = nil
  end
  if message then
    hs.printf("Window switcher: %s", message)
    hs.alert.show("Could not switch to that window")
  end
  operation = nil
  if queuedWindow and not stopped then
    local window = queuedWindow
    queuedWindow = nil
    focus(window)
  end
end

focus = function(window)
  if operation then
    queuedWindow = window
    return
  end
  local job = {}
  operation = job
  job.deadline = hs.timer.doAfter(3, function()
    finish(job, "timed out " .. (job.watcher and "unhiding " or "focusing ") .. window.app)
  end)
  local function moveAndFocus()
    job.target = window.id
    -- Re-run by the window-focused event.
    job.confirmFocus = function()
      if operation ~= job then
        return
      end
      local focused = hs.window.focusedWindow()
      if focused and focused:id() == window.id then
        recent[window.id] = hs.timer.secondsSinceEpoch()
        finish(job)
      end
    end
    windowManager.focus(window.pid, window.id, function(focused, failure)
      if operation ~= job then
        return
      end
      if not focused then
        finish(job, failure)
        return
      end
      job.confirmFocus()
    end)
  end
  -- Requery: the window may have moved or closed while the menu was open.
  windowManager.windows(function(ok, err, rows)
    if operation ~= job then
      return
    end
    local row
    for _, candidate in ipairs(ok and describe(rows) or {}) do
      if candidate.id == window.id then
        row = candidate
        break
      end
    end
    if not row or not eligible(row) or row.pid ~= window.pid then
      finish(job, err or "window is no longer available")
      return
    end
    window = row
    local restoring = false
    local function restore()
      if operation ~= job or restoring then
        return
      end
      restoring = true
      if job.watcher then
        job.watcher:stop()
        job.watcher = nil
      end
      if row["is-minimized"] then
        windowManager.minimize(row.pid, row.id, false, function(restored, reason)
          if operation ~= job then
            return
          end
          if restored then
            moveAndFocus()
          else
            finish(job, reason)
          end
        end)
      else
        moveAndFocus()
      end
    end
    if not row["is-hidden"] then
      restore()
      return
    end
    local app = hs.application.applicationForPID(row.pid)
    local element = app and hs.axuielement.applicationElement(app)
    if not app or not element then
      finish(job, "application Accessibility unavailable for " .. row.app)
      return
    end
    local events = hs.application.watcher
    local accepted, unhidden = false, false
    job.watcher = events.new(function(_, event, application)
      if operation ~= job or not job.watcher or not application or application:pid() ~= row.pid then
        return
      end
      if event == events.unhidden then
        unhidden = true
        if accepted then
          restore()
        end
      elseif event == events.terminated then
        finish(job, row.app .. " exited while unhiding")
      end
    end)
    job.watcher:start()
    -- AX reports request errors; app:unhide() only checks the immediate hidden state.
    local result, reason = element:setAttributeValue("AXHidden", false)
    if not result then
      finish(job, "could not unhide " .. row.app .. ": " .. tostring(reason))
      return
    end
    accepted = true
    if unhidden or not app:isHidden() then
      restore()
    end
  end)
end

function switcher.mostRecent(windows)
  local target, timestamp
  for _, window in ipairs(windows) do
    local used = recent[window.id] or 0
    if not target or used > timestamp then
      target, timestamp = window, used
    end
  end
  return target
end

local function accept()
  local current = cycle
  if not current then
    return
  end
  stopDrawing(current)
  hide()
  current.released = true
  if current.windows then
    cycle = nil
    local window = current.windows[current.selected]
    if window then
      focus(window)
    end
  end
end

local function cancel()
  stopDrawing(cycle)
  cycle = nil
  hide()
end

local function step(direction)
  -- A released cycle already chose its window; a new press supersedes it.
  if cycle and not cycle.released then
    cycle.showRequested = true
    cycle.delayTimer:stop()
    if cycle.windows then
      cycle.selected = (cycle.selected - 1 + direction) % #cycle.windows + 1
      cycle.revealSelected = true
      show(cycle)
    else
      cycle.steps = cycle.steps + direction
    end
    return
  end
  -- The main screen can stay on another display while a fullscreen app has focus.
  local display = hs.screen.find(hs.spaces.spaceDisplay(hs.spaces.focusedSpace()))
  if not display then
    hs.printf("Window switcher: focused display unavailable")
    hs.alert.show("Focused display unavailable")
    return
  end
  local current = {
    steps = direction,
    images = {},
    prepared = {},
    added = {},
    closed = {},
    screen = display:frame(),
  }
  cycle = current
  current.delayTimer = hs.timer.doAfter(menuDelay, function()
    if cycle == current then
      current.showRequested = true
      show(current)
    end
  end)
  windowManager.windows(function(ok, err, found)
    if cycle ~= current then
      return
    end
    if not ok then
      cancel()
      hs.printf("Window switcher: %s", err or "window list unavailable")
      hs.alert.show("Window list unavailable")
      return
    end
    local rows = describe(found)
    -- Keep events received while the initial query was in flight.
    local windows, live = {}, {}
    for _, window in ipairs(rows) do
      local added = current.added[window.id]
      if added then
        if added.pid == window.pid then
          added["has-focus"] = window["has-focus"]
        end
      elseif not current.closed[window.id] and eligible(window) then
        windows[#windows + 1] = window
        live[window.id] = window.pid
      end
    end
    for id, window in pairs(current.added) do
      windows[#windows + 1] = window
      live[id] = window.pid
    end
    current.added = {}
    for id in pairs(snapshots) do
      if not live[id] then
        snapshots[id] = nil
        recent[id] = nil
      end
    end
    for id, capture in pairs(captures) do
      if live[id] ~= capture.pid then
        capture.cancel()
        captures[id] = nil
      end
    end
    if #windows == 0 then
      cancel()
      return
    end
    table.sort(windows, function(a, b)
      if a["has-focus"] ~= b["has-focus"] then
        return a["has-focus"]
      end
      local recentA, recentB = recent[a.id] or 0, recent[b.id] or 0
      if recentA ~= recentB then
        return recentA > recentB
      end
      return a.id < b.id
    end)
    current.windows = windows
    current.selected = current.steps % #windows + 1
    current.revealSelected = true
    if current.released then
      accept()
      return
    end
    if current.showRequested then
      show(current)
    end
  end)
end

-- Gaps and padding pick the nearest visible card.
local function cardAtPoint(current, x, y)
  if not current or not current.cards then
    return nil
  end
  if x < 0 or x >= current.frame.w or y < 0 or y >= current.frame.h then
    return nil
  end
  local nearest, distance
  for _, card in ipairs(current.cards) do
    if card.w > 0 and card.h > 0 then
      local dx = math.max(card.x - x, 0, x - (card.x + card.w))
      local dy = math.max(card.y - y, 0, y - (card.y + card.h))
      local squared = dx * dx + dy * dy
      if
        not distance
        or squared < distance - 1e-6
        or (math.abs(squared - distance) <= 1e-6 and card.index == current.selected)
      then
        nearest, distance = card.index, squared
      end
    end
  end
  return nearest
end

switcher.canvas = hs.canvas.new({ x = 0, y = 0, w = 1, h = 1 }) --[[@as hs.canvas]]
switcher.canvas:level("overlay")
switcher.canvas:behaviorAsLabels({ "canJoinAllSpaces", "fullScreenAuxiliary", "ignoresCycle" })
switcher.canvas:clickActivating(false)
switcher.canvas:mouseCallback(function(_, message, _, x, y)
  if message == "mouseUp" then
    local index = cardAtPoint(cycle, x, y)
    if index then
      cycle.selected = index
      accept()
    end
  end
end)

-- Inactive canvas windows can miss AppKit hover events.
switcher.mouseTap = hs.eventtap.new({ types.mouseMoved, types.scrollWheel }, function(event)
  if not cycle or not cycle.cards then
    return false
  end
  local pointer, previous = event:location(), cycle.pointer
  cycle.pointer = pointer
  local x, y = pointer.x - cycle.frame.x, pointer.y - cycle.frame.y
  if event:getType() == types.scrollWheel then
    if x < 0 or x >= cycle.frame.w or y < 0 or y >= cycle.frame.h then
      return false
    end
    local delta = event:getProperty(properties.scrollWheelEventIsContinuous) ~= 0
        and event:getProperty(properties.scrollWheelEventPointDeltaAxis1)
      or event:getProperty(properties.scrollWheelEventDeltaAxis1) * 32
    local offset = math.max(0, math.min(cycle.maxScroll, cycle.scrollOffset - delta))
    if offset ~= cycle.scrollOffset then
      cycle.scrollOffset = offset
      cycle.revealSelected = false
      show(cycle)
    end
    -- Consume even at scroll limits, so the app below doesn't scroll.
    return true
  end
  if previous and pointer.x == previous.x and pointer.y == previous.y then
    return false
  end
  local index = cardAtPoint(cycle, x, y)
  if index and cycle.selected ~= index then
    cycle.selected = index
    show(cycle)
  end
  return false
end)

switcher.tap = hs.eventtap
  .new({ types.keyDown, types.keyUp, types.flagsChanged }, function(event)
    local kind, key, flags = event:getType(), event:getKeyCode(), event:getFlags()
    if kind == types.flagsChanged then
      if cycle and not flags.cmd then
        accept()
      end
      return false
    end
    if kind == types.keyUp and swallowed[key] then
      swallowed[key] = nil
      return true
    end
    if kind ~= types.keyDown then
      return false
    end
    if key == keys.tab and flags.cmd and not flags.ctrl and not flags.alt then
      swallowed[key] = true
      step(flags.shift and -1 or 1)
      return true
    end
    if cycle and not cycle.released then
      if key == keys.escape then
        swallowed[key] = true
        cancel()
      elseif key == keys.left or key == keys.right then
        swallowed[key] = true
        step(key == keys.left and -1 or 1)
      elseif key == keys["return"] then
        swallowed[key] = true
        accept()
      else
        swallowed[key] = true
      end
      return true
    end
    return false
  end)
  :start() --[[@as hs.eventtap]]

-- Unfiltered, so title changes into and out of PiP still arrive.
switcher.windows = filter.new()
-- Front-to-back seed, below any focus timestamp; other Spaces stay unordered.
local ordered = (hs.window --[[@as { _orderedwinids: fun(): integer[] }]])._orderedwinids()
for index, id in ipairs(ordered) do
  recent[id] = #ordered - index + 1
end
switcher.windows:subscribe(filter.windowFocused, function(window)
  local id = assert(window:id())
  recent[id] = hs.timer.secondsSinceEpoch()
  if operation and operation.target == id and operation.confirmFocus then
    operation.confirmFocus(true)
  end
end)
local function created(window, name, _, id)
  local current = cycle
  if not current or current.released or name == "Hammerspoon" or isPiP(window:title()) then
    return
  end
  for _, row in ipairs(current.windows or {}) do
    if row.id == id then
      return
    end
  end
  if current.added[id] then
    return
  end
  -- The Accessibility event can arrive before the window list includes this window.
  local app = window:application()
  local element = app and hs.axuielement.windowElement(window)
  if not element then
    -- Already closed; its destruction event follows.
    return
  end
  local parent = element:attributeValue("AXParent")
  if parent and parent:attributeValue("AXRole") ~= "AXApplication" then
    return
  end
  local row = {
    id = id,
    pid = app:pid(),
    app = name,
    bundle = app:bundleID(),
    title = window:title() or "",
    ["has-focus"] = false,
    ["is-minimized"] = window:isMinimized(),
    ["is-hidden"] = app:isHidden(),
  }
  current.closed[id] = nil
  if not current.windows then
    current.added[id] = row
    return
  end
  current.windows[#current.windows + 1] = row
  current.revealSelected = true
  if current.showRequested then
    show(current)
  end
end
local function destroyed(_, _, _, id)
  if captures[id] then
    captures[id].cancel()
    captures[id] = nil
  end
  recent[id], snapshots[id] = nil, nil
  local current = cycle
  if not current then
    return
  end
  current.closed[id] = true
  current.added[id], current.prepared[id], current.images[id] = nil, nil, nil
  for index, window in ipairs(current.windows or {}) do
    if window.id == id then
      table.remove(current.windows, index)
      if #current.windows == 0 then
        cancel()
        return
      end
      current.selected = index < current.selected and current.selected - 1
        or math.min(current.selected, #current.windows)
      current.revealSelected = true
      if current.showRequested and not current.released then
        show(current)
      end
      return
    end
  end
end
switcher.windows:subscribe(filter.windowCreated, created)
switcher.windows:subscribe(filter.windowDestroyed, destroyed)

switcher.windows:subscribe({
  filter.windowMoved,
  filter.windowTitleChanged,
  filter.windowMinimized,
  filter.windowUnminimized,
  filter.windowHidden,
  filter.windowUnhidden,
}, function(window, name, event, id)
  local current = cycle
  local capture = event == filter.windowMinimized or event == filter.windowHidden
  if not capture and (not current or current.released) then
    return
  end
  -- Entering PiP acts as a close, leaving it as a create.
  local title = window:title() or ""
  if isPiP(title) then
    if event == filter.windowTitleChanged then
      destroyed(window, name, event, id)
    end
    return
  end
  if event == filter.windowTitleChanged then
    created(window, name, event, id)
  end
  local app = window:application()
  if not app then
    return
  end
  local pid = app:pid()
  if capture and hs.screenRecordingState() then
    if captures[id] then
      captures[id].cancel()
    end
    local request = { pid = pid }
    captures[id] = request
    if current and current.capture then
      current.capture.pending[id] = nil
    end
    local ok, stop = pcall(previews.capture, { { id = id, pid = pid } }, function(captured, image)
      if stopped or captures[id] ~= request then
        return
      end
      if not captured then
        captures[id] = nil
        return
      end
      if image then
        snapshots[id] = { image = image, pid = pid }
      end
      local menu = cycle
      if menu and not menu.released then
        for _, row in ipairs(menu.windows or {}) do
          if row.id == id and row.pid == pid then
            menu.prepared[id] = row
            if image then
              menu.images[id] = image
            end
            if menu.showRequested then
              show(menu)
            end
            break
          end
        end
      end
    end)
    if ok then
      request.cancel = stop
    else
      captures[id] = nil
    end
  end
  if not current or current.released then
    return
  end
  for _, row in ipairs(current.windows or {}) do
    if row.id == id then
      if pid ~= row.pid then
        return
      end
      row.title = title
      row["is-minimized"] = window:isMinimized()
      row["is-hidden"] = app:isHidden()
      current.prepared[id] = capture and row or nil
      if current.showRequested then
        show(current)
      end
      return
    end
  end
end)

function switcher.isBusy()
  return operation ~= nil or cycle ~= nil or switcher.canvas:isShowing()
end

function switcher.status()
  local result = {
    active = switcher.tap:isEnabled(),
    visible = switcher.canvas:isShowing(),
    previews = hs.screenRecordingState(),
    busy = operation ~= nil,
    windows = {},
  }
  if cycle and cycle.windows then
    for _, window in ipairs(cycle.windows) do
      result.windows[#result.windows + 1] = {
        id = window.id,
        app = window.app,
        title = window.title,
        preview = cycle.images[window.id] ~= nil,
        minimized = window["is-minimized"] == true,
        hidden = window["is-hidden"] == true,
      }
    end
    result.selected = cycle.windows[cycle.selected].id
  end
  return result
end

function switcher.stop()
  stopped = true
  for id, capture in pairs(captures) do
    capture.cancel()
    captures[id] = nil
  end
  switcher.tap:stop()
  switcher.windows:delete()
  cancel()
  switcher.canvas:delete()
  queuedWindow = nil
  if operation then
    local job = operation
    operation = nil
    job.deadline:stop()
    job.deadline = nil
    if job.watcher then
      job.watcher:stop()
      job.watcher = nil
    end
  end
end

return switcher

local Engine = require("dictation.engine")
local Overlay = require("dictation.overlay")
local config = require("dictation.config")
local history = require("dictation.history")
local recorder = require("dictation.recorder")

-- Report a failure in the log and on screen.
---@param message string
local function fail(message)
  print(message)
  hs.alert.show(message:match("^[^\n]+"), 5)
end

---@class DictationModule
---@field hotkey? hs.hotkey bound when trigger = "hotkey"
---@field cancelHotkey? hs.hotkey Escape; enabled only while dictating
---@field keyTap? hs.eventtap bound for "modifierTap" / "dictationKey" triggers
---@field stop fun() tear everything down (called on Hammerspoon shutdown)
local dictation = {}

---@type "idle"|"recording"|"thinking"
local state = "idle"
---@type DictationOverlay?, DictationRecording?, DictationEngine?, hs.timer?
local overlay, recording, engine, animation
local inflight
local requests = {}
local stopped = false

local browsers = {
  ["com.apple.Safari"] = "Safari",
  ["com.google.Chrome"] = "Google Chrome",
  ["com.brave.Browser"] = "Brave Browser",
  ["company.thebrowser.Browser"] = "Arc",
  ["com.microsoft.edgemac"] = "Microsoft Edge",
}

-- Frontmost app, window title, browser URL, and (opt-in) the text selection.
---@return DictationTranscribeRequest context `wav` is filled in by the caller
local function gatherContext()
  ---@type DictationTranscribeRequest
  local context = { wav = "" }
  local app = hs.application.frontmostApplication()
  if app then
    context.app = app:bundleID()
    local window = app:focusedWindow()
    if window then
      context.title = window:title()
    end
    -- URL of the front tab when the app is a known browser.
    local browser = context.app and browsers[context.app]
    if browser then
      local script = browser == "Safari"
          and [[tell application "Safari" to return URL of current tab of front window]]
        or ([[tell application "%s" to return URL of active tab of front window]]):format(browser)
      local ok, url = hs.osascript.applescript(script)
      if ok and type(url) == "string" and #url > 0 then
        context.url = url
      end
    end
  end
  -- Only a real selection, capped: the whole field leaks the document and gets echoed back.
  if config.includeSelection then
    local ok, selection = pcall(function()
      local systemWide = hs.axuielement.systemWideElement() --[[@as hs.axuielement]]
      local element = systemWide:attributeValue("AXFocusedUIElement")
      return element and element:attributeValue("AXSelectedText")
    end)
    if ok and type(selection) == "string" and #selection > 0 then
      local cut = utf8.offset(selection, 201) -- byte after the 200th character, or nil if shorter
      context.selected = cut and selection:sub(1, cut - 1) or selection
    end
  end
  return context
end

local function stopAnimation()
  if animation then
    animation:stop()
    animation = nil
  end
end

---@param active boolean
local function setEscape(active)
  if not dictation.cancelHotkey then
    return
  end
  if active then
    dictation.cancelHotkey:enable()
  else
    dictation.cancelHotkey:disable()
  end
end

-- Insert into the focused field; false when there is none. Raises on failure.
---@param text string
---@return boolean
local function insertText(text)
  local systemWide = hs.axuielement.systemWideElement() --[[@as hs.axuielement]]
  local element = systemWide:attributeValue("AXFocusedUIElement")
  if not element then
    return false
  end
  local value = element:attributeValue("AXValue")
  local range = element:attributeValue("AXSelectedTextRange")
  local selected = element:attributeValue("AXSelectedText")
  if type(value) == "string" and type(range) == "table" and range.location then
    -- Characters around the selection (AX ranges count UTF-16 units).
    local before, after, units = "", "", 0
    for _, codepoint in utf8.codes(value) do
      if units >= range.location + (range.length or 0) then
        after = utf8.char(codepoint)
        break
      end
      if units < range.location then
        before = utf8.char(codepoint)
      end
      units = units + (codepoint > 0xFFFF and 2 or 1)
    end
    -- Delimiters that open a run: no space is added between them and the text.
    local openers = {
      ["("] = true,
      ["["] = true,
      ["{"] = true,
      ['"'] = true,
      ["'"] = true,
      ["“"] = true,
      ["‘"] = true,
      ["<"] = true,
      ["/"] = true,
    }
    if before ~= "" and not before:match("^%s$") and not openers[before] then
      text = " " .. text
    end
    if after:match("^%w$") or openers[after] then
      text = text .. " "
    end
  end
  local writable, failure = element:isAttributeSettable("AXSelectedText")
  if failure then
    error(failure, 0)
  end
  -- Only a text field has a writable selection and a string value.
  if not writable or type(value) ~= "string" then
    return false
  end
  -- Chromium/Electron accept the write and ignore it; trust it only if the value changed.
  local result, reason = element:setAttributeValue("AXSelectedText", text)
  if not result then
    error(reason or "could not insert into focused field", 0)
  end
  if element:attributeValue("AXValue") ~= value or selected == text then
    return true -- changed, or identical text over an identical selection (a no-op either way)
  end
  -- The app's own ⌘V; macOS never signals when the clipboard was read, hence the delay.
  local previous = hs.pasteboard.readAllData()
  if not hs.pasteboard.setContents(text) then
    error("could not write clipboard", 0)
  end
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  local count = hs.pasteboard.changeCount()
  hs.timer.doAfter(0.25, function()
    -- Restore only if the clipboard still holds the dictation (nothing else wrote to it).
    if previous and hs.pasteboard.changeCount() == count then
      hs.pasteboard.writeAllData(previous)
    end
  end)
  return true
end

-- Deliver the result and return to idle.
---@param text string?
local function finish(text)
  inflight = nil
  if text and #text > 0 and not stopped then
    local mode = config.insert
    local inserted
    if mode ~= "clipboard" then
      local ok, result = pcall(insertText, text)
      inserted = ok and result
      if mode == "direct" and not inserted then
        fail("Dictation: " .. (ok and "no text field is focused" or tostring(result)))
      end
    end
    -- "clipboard" always copies; "auto" copies when nothing could be inserted.
    if mode == "clipboard" or (mode == "auto" and not inserted) then
      if hs.pasteboard.setContents(text) then
        if mode == "auto" then
          hs.alert.show("Dictation copied to clipboard", 1.5)
        end
      else
        fail("Dictation: could not write clipboard")
      end
    end
  end
  if overlay then
    overlay:hide()
  end
  stopAnimation()
  setEscape(false)
  if recording then
    recorder.cleanup(recording)
    recording = nil
  end
  state = "idle"
end

local function cancel()
  inflight = nil
  finish(nil)
end

local function toggle()
  if stopped then
    return
  end
  if state == "idle" then
    if not engine or not engine:isReady() then
      fail("Dictation: backend is not ready")
      return
    end
    if hs.microphoneState(false) == false then
      hs.microphoneState(true)
      fail("Dictation: allow Microphone access in System Settings")
      return
    end
    local pill = overlay or Overlay.new(config.overlayHeight)
    overlay = pill
    state = "recording"
    pill:show()
    setEscape(true)
    local capture, message = recorder.start(config.eqBands, function(failure)
      fail("Dictation recorder: " .. failure)
      cancel()
    end)
    if not capture then
      fail("Dictation: " .. tostring(message))
      finish(nil)
      return
    end
    recording = capture
    -- One 30 fps tick: the ripple intro until the mic opens, then the equalizer.
    stopAnimation()
    animation = hs.timer.doEvery(1 / 30, function()
      if state == "recording" then
        local bands = recorder.poll(capture)
        if bands then
          pill:setBars(bands)
          return
        end
      end
      pill:tick()
    end)
  elseif state == "recording" then
    state = "thinking"
    local capture = assert(recording)
    local backend, pill = assert(engine), assert(overlay)
    recorder.stop(capture, function(wav, peak, duration)
      if recording ~= capture or stopped then
        return
      end
      if not wav then
        fail("Dictation: " .. (capture.error or "capture failed"))
        finish(nil)
        return
      end
      if peak < config.minLevel or duration < config.minDuration then
        local line = "Dictation: discarded (peak %.2f < %.2f or %.2fs < %.2fs)"
        print(line:format(peak, config.minLevel, duration, config.minDuration))
        finish(nil)
        return
      end
      local context = gatherContext()
      context.wav = wav
      local id, message = backend:transcribe(context)
      if not id then
        fail("Dictation: " .. tostring(message))
        finish(nil)
        return
      end
      requests[id], inflight, recording = capture, id, nil
      pill:setThinking()
      if not animation then
        animation = hs.timer.doEvery(1 / 30, function()
          pill:tick()
        end)
      end
    end)
  end
end

-- Each reply owns its recording; cancelled replies cannot finish a later take.
local failure
engine, failure = Engine.new(config, {
  onReady = function()
    print("Dictation: backend ready")
  end,
  onFinal = function(result)
    -- Saved before anything else, even for a cancelled take, so no result is lost.
    if result.text and #result.text > 0 then
      local problem = history.save(result.text, config.history)
      if problem then
        fail("Dictation: " .. problem)
      end
    end
    recorder.cleanup(requests[result.id])
    requests[result.id] = nil
    if stopped or inflight ~= result.id then
      return
    end
    finish(result.text)
  end,
  onError = function(message, id)
    if id then
      recorder.cleanup(requests[id])
      requests[id] = nil
      if inflight ~= id then
        return
      end
    else
      for key, capture in pairs(requests) do
        recorder.cleanup(capture)
        requests[key] = nil
      end
    end
    fail("Dictation backend: " .. message)
    cancel()
  end,
  onLog = function(message)
    print("Dictation backend: " .. message)
  end,
})
if not engine then
  fail("Dictation: " .. tostring(failure))
end

if config.trigger == "hotkey" then
  dictation.hotkey = hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, toggle)
elseif config.trigger == "dictationKey" then
  local key = config.dictationKey
  dictation.keyTap = hs.eventtap.new({ hs.eventtap.event.types.systemDefined }, function(event)
    local native = event:getRawEventData().NSEventData
    if native and native.subtype == key.subtype and native.data1 == key.data1 then
      if native.data2 == 1 then
        toggle()
      end
      return key.swallow
    end
    return false
  end)
else
  -- Solo modifier tap: any other key, click, scroll, or modifier voids it.
  local modifier = config.modifierTap
  local types = hs.eventtap.event.types
  local down, downAt, otherUsed = false, 0, false
  ---@type number, integer
  local lastTapAt, tapCount = 0, 0
  local watched = {
    types.flagsChanged,
    types.keyDown,
    types.leftMouseDown,
    types.rightMouseDown,
    types.otherMouseDown,
    types.scrollWheel,
  }
  dictation.keyTap = hs.eventtap.new(watched, function(event)
    local kind = event:getType()
    if kind ~= types.flagsChanged then
      if down then
        otherUsed = true -- a key, click, or scroll while the modifier was held
      end
      return false
    end
    local key = event:getKeyCode()
    local flags = event:getFlags()
    if key == modifier.keycode then
      if flags[modifier.flag] then
        -- our modifier went down; another modifier already held is not a solo tap
        local others = false
        for flag in pairs(flags) do
          others = others or flag ~= modifier.flag
        end
        down, downAt, otherUsed = true, hs.timer.secondsSinceEpoch() or 0, others
      else
        -- our modifier went up: a clean, quick tap?
        local now = hs.timer.secondsSinceEpoch() or 0
        down = false
        if not otherUsed and (now - downAt) <= modifier.window then
          if (now - lastTapAt) <= modifier.window then
            tapCount = tapCount + 1
          else
            tapCount = 1
          end
          lastTapAt = now
          if tapCount >= modifier.taps then
            tapCount = 0
            toggle()
          end
        else
          tapCount = 0
        end
      end
    elseif next(flags) ~= nil then
      -- a different modifier is involved; not a clean solo tap
      otherUsed = true
    end
    return false
  end)
end
if dictation.keyTap then
  dictation.keyTap:start()
end

-- Bound but disabled; only enabled while dictating so Escape works normally.
dictation.cancelHotkey = hs.hotkey.new({}, "escape", function()
  if state ~= "idle" then
    cancel()
  end
end)

function dictation.stop()
  stopped = true
  cancel()
  if engine then
    engine:stop()
  end
  for id, capture in pairs(requests) do
    recorder.cleanup(capture)
    requests[id] = nil
  end
  if overlay then
    overlay:delete()
    overlay = nil
  end
  if dictation.keyTap then
    dictation.keyTap:stop()
    dictation.keyTap = nil
  end
  if dictation.hotkey then
    dictation.hotkey:delete()
  end
  if dictation.cancelHotkey then
    dictation.cancelHotkey:delete()
  end
end

-- Chain into Hammerspoon's shutdown so reloads clean up the backend process.
local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  dictation.stop()
  if previousShutdown then
    previousShutdown()
  end
end

return dictation

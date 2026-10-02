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

local dictation = {}

---@type "idle"|"recording"|"thinking"
local state = "idle"
---@type DictationOverlay?, DictationRecording?, DictationEngine?, string?
local overlay, recording, engine, engineError
---@type hs.timer?, hs.axuielement?, string?
local animation, target, targetError
local inflight
local requests = {}

local browsers = {
  ["com.apple.Safari"] = "Safari",
  ["com.google.Chrome"] = "Google Chrome",
  ["com.brave.Browser"] = "Brave Browser",
  ["company.thebrowser.Browser"] = "Arc",
  ["com.microsoft.edgemac"] = "Microsoft Edge",
  ["net.imput.helium"] = "Helium",
}

-- The focused UI element; nil and an error string when accessibility fails.
---@return hs.axuielement?, string?
local function focused()
  local systemWide = hs.axuielement.systemWideElement() --[[@as hs.axuielement]]
  return systemWide:attributeValue("AXFocusedUIElement")
end

-- At most 200 characters: a whole document or a data: URL would flood the prompt.
---@param text string
local function clip(text)
  local cut = utf8.offset(text, 201) -- byte after the 200th character, or nil if shorter
  return cut and text:sub(1, cut - 1) or text
end

-- Window title, browser URL, and selection feed only our own prompt; an adapter ships its own.
local function prompted()
  return config.cleanup.enabled and not config.cleanup.adapter
end

-- Frontmost app; when prompted(), window title, browser URL, and (opt-in) selection.
-- nil and why when asked-for context cannot be read: the take stops rather than go without it.
---@return DictationTranscribeRequest?, string?
local function gatherContext()
  ---@type DictationTranscribeRequest
  local context = { wav = "" } -- the caller sets wav
  local app = hs.application.frontmostApplication()
  if not app then
    return context
  end
  context.app = app:bundleID()
  if not prompted() then
    return context
  end
  local window = app:focusedWindow()
  if window then
    context.title = clip(window:title())
  end
  -- URL of the front tab when the app is a known browser.
  local browser = context.app and browsers[context.app]
  if browser then
    local script = browser == "Safari"
        and [[tell application "Safari" to return URL of current tab of front window]]
      or ([[tell application "%s" to return URL of active tab of front window]]):format(browser)
    local ok, url, descriptor = hs.osascript.applescript(script)
    if not ok then
      local message = (descriptor --[[@as table]]).NSAppleScriptErrorMessage
      return nil, "could not read the URL: " .. tostring(message)
    elseif type(url) == "string" and #url > 0 then
      context.url = clip(url)
    end
  end
  -- Only a real selection: the whole field leaks the document and gets echoed back.
  if config.includeSelection then
    -- The field focused at stop, which is also the one the text goes into.
    local selection, problem = nil, targetError
    if target then
      selection, problem = target:attributeValue("AXSelectedText")
    end
    -- Unsupported just means the focus is not a text field.
    if problem and problem ~= "Attribute is not supported by target" then
      return nil, "could not read the selection: " .. problem
    elseif type(selection) == "string" and #selection > 0 then
      context.selected = clip(selection)
    end
  end
  return context
end

-- The app's own ⌘V; macOS never signals when the clipboard was read, hence the delay.
---@param text string
local function paste(text)
  local previous = hs.pasteboard.readAllData() or {} -- nil when the clipboard is empty
  -- One entry per item, each its own list of types: the item count, not the type count.
  local items = #hs.pasteboard.allContentTypes()
  -- Transient (nspasteboard.org): clipboard managers record neither this nor the restore.
  local transient = "org.nspasteboard.TransientType"
  if not hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = text, [transient] = "" }) then
    error("could not write clipboard", 0)
  end
  -- Before ⌘V: any later write, the app's own included, cancels the restore.
  local count = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  -- Held so GC cannot stop it.
  dictation.restore = hs.timer.doAfter(0.25, function()
    dictation.restore = nil
    -- Restore only if the clipboard still holds the dictation (nothing else wrote to it).
    if hs.pasteboard.changeCount() ~= count then
      return
    elseif next(previous) == nil then
      hs.pasteboard.clearContents() -- it was empty; this reports nothing, so look
      if #hs.pasteboard.allContentTypes() > 0 then
        fail("Dictation: could not clear the clipboard")
      end
      return
    end
    previous[transient] = ""
    if not hs.pasteboard.writeAllData(previous) then
      fail("Dictation: could not restore the clipboard")
    elseif items > 1 then
      -- readAllData sees only the first item (e.g. of several copied files).
      fail(("Dictation: restored only the first of %d clipboard items"):format(items))
    end
  end)
  return true
end

-- An attribute of the focused field; nil when unsupported. Raises on accessibility errors.
---@param element hs.axuielement
---@param name string
local function read(element, name)
  local value, problem = element:attributeValue(name)
  if problem and problem ~= "Attribute is not supported by target" then
    error(("could not read the focused field's %s: %s"):format(name, problem), 0)
  end
  return value
end

-- Whether an attribute of the focused field takes writes; nil when unsupported. Raises like `read`.
---@param element hs.axuielement
---@param name string
local function settable(element, name)
  local writable, problem = element:isAttributeSettable(name)
  if problem and problem ~= "Attribute is not supported by target" then
    error(("could not check the focused field's %s: %s"):format(name, problem), 0)
  end
  return writable
end

-- Insert into the field focused at stop; false when there is none. Raises on failure.
---@param text string
local function insertText(text)
  if targetError then
    error("could not read the focused field at stop: " .. targetError, 0)
  end
  local element, problem = focused()
  if problem then
    error("could not read the focused field: " .. problem, 0)
  end
  if not element then
    return false
  end
  if element ~= target then
    error("focus moved while transcribing", 0)
  end
  local role = read(element, "AXRole")
  -- Mail's compose body is an editable page: its value is settable, its selection is not.
  if role == "AXWebArea" and settable(element, "AXValue") then
    return paste(text)
  end
  -- Text roles only: Chromium also takes (and drops) text writes on sliders, buttons, toolbars.
  if role ~= "AXTextField" and role ~= "AXTextArea" and role ~= "AXComboBox" then
    return false
  end
  if not settable(element, "AXSelectedText") then
    -- Terminals and Messages take no writes: paste. Read-only views look alike; ⌘V fails silently.
    return paste(text)
  end
  -- Nothing to space against or compare without a string value.
  local value = read(element, "AXValue")
  if type(value) ~= "string" then
    return false
  end
  local range = read(element, "AXSelectedTextRange")
  local selected = read(element, "AXSelectedText")
  if type(range) == "table" and range.location then
    -- Two characters on each side of the selection and its last one (AX ranges count UTF-16 units).
    local prior, before, last, after, beyond, units = "", "", "", "", "", 0
    for _, codepoint in utf8.codes(value) do
      -- Browsers store a typed trailing space in a contenteditable as U+00A0.
      local char = codepoint == 0xA0 and " " or utf8.char(codepoint)
      if units >= range.location + (range.length or 0) then
        if after ~= "" then
          beyond = char
          break
        end
        after = char
      elseif units < range.location then
        prior, before = before, char
      else
        last = char
      end
      units = units + (codepoint > 0xFFFF and 2 or 1)
    end
    -- Delimiters that open a run: no space is added between them and the text.
    local openers = {
      ["("] = true,
      ["["] = true,
      ["{"] = true,
      ["“"] = true,
      ["‘"] = true,
      ["<"] = true,
      ["/"] = true,
    }
    -- A straight quote or backtick opens after the start, a space, or an opener, and before a word.
    local quotes = { ['"'] = true, ["'"] = true, ["`"] = true }
    local function starts(char)
      return char == "" or char:match("^%s$") or openers[char]
    end
    -- A letter or digit in any script ("é", "日"); punctuation blocks and Latin-1 marks are not.
    local marks = {
      { 0x80, 0xBF },
      { 0x2000, 0x206F },
      { 0x3000, 0x303F },
      -- Fullwidth punctuation: "！", "？", "：", "［", "｛", "｡".
      { 0xFF01, 0xFF0F },
      { 0xFF1A, 0xFF20 },
      { 0xFF3B, 0xFF40 },
      { 0xFF5B, 0xFF65 },
    }
    local function within(char, blocks)
      local code = char ~= "" and utf8.codepoint(char) or 0
      for _, block in ipairs(blocks) do
        if code >= block[1] and code <= block[2] then
          return true
        end
      end
      return false
    end
    local function wordy(char)
      return char:match("^%w$") ~= nil or (#char > 1 and not within(char, marks))
    end
    -- A part of a name, address, or path stays joined: "foo.[local].bar", "foo-|bar", "foo_[bar]",
    -- "user+[tag]@example.com", "/usr/|bin", and before one: "/usr|/bin", "foo|.bar", "user|@host".
    local joiners = { ["."] = true, ["-"] = true, ["_"] = true, ["@"] = true, ["+"] = true }
    joiners["="] = true -- "KEY=[old]", "--flag=|value"
    joiners[":"] = true -- "image:[latest]"; "Note:|" alone still gets its space
    local slash = { ["/"] = true, ["\\"] = true } -- "C:\[old]\file" too
    local joined = (joiners[before] and wordy(prior) or slash[before])
        and (last ~= "" or wordy(after))
      or wordy(before) and (slash[after] or joiners[after] and wordy(beyond))
    -- Chinese, Japanese, Thai, and the like put no space between words: "你好|世界" + "漂亮".
    local unspaced = {
      { 0x0E00, 0x0EFF }, -- Thai, Lao
      { 0x1000, 0x109F }, -- Myanmar
      { 0x1780, 0x17FF }, -- Khmer
      { 0x2E80, 0x2FDF }, -- CJK radicals
      { 0x3000, 0x31FF }, -- CJK punctuation, kana, Bopomofo
      { 0x3400, 0x9FFF }, -- CJK ideographs
      { 0xF900, 0xFAFF },
      { 0xFF00, 0xFFEF }, -- fullwidth and halfwidth forms
      { 0x20000, 0x3FFFF },
    }
    local first, final = utf8.char(utf8.codepoint(text, 1)), text:sub(utf8.offset(text, -1))
    if
      not starts(before)
      and not (quotes[before] and starts(prior))
      and not joined
      and not (within(before, unspaced) and within(first, unspaced))
    then
      text = " " .. text
    end
    local opens = quotes[after] and starts(last ~= "" and last or before) and wordy(beyond)
    -- A "/" after is a path going on ("/usr/share/bin"), not an opener.
    if
      (wordy(after) or (openers[after] and after ~= "/") or opens)
      and not joined
      and not (within(final, unspaced) and within(after, unspaced))
    then
      text = text .. " "
    end
  end
  -- Chromium/Electron accept the write and ignore it; trust it only if the value changed.
  local result, reason = element:setAttributeValue("AXSelectedText", text)
  if not result then
    error(reason or "could not insert into focused field", 0)
  end
  if read(element, "AXValue") ~= value or selected == text then
    return true -- changed, or identical text over an identical selection (a no-op either way)
  end
  return paste(text)
end

-- Deliver the result and return to idle.
---@param text string?
local function finish(text)
  inflight = nil
  if text and #text > 0 then
    local mode = config.insert
    local inserted
    if mode ~= "clipboard" then
      local ok, result = pcall(insertText, text)
      inserted = ok and result
      if mode == "direct" and not inserted then
        fail("Dictation: " .. (ok and "no text field is focused" or tostring(result)))
      elseif not ok then
        print("Dictation: " .. tostring(result))
      end
    end
    -- "clipboard" always copies; "auto" copies when nothing could be inserted.
    if mode == "clipboard" or (mode == "auto" and not inserted) then
      if not hs.pasteboard.setContents(text) then
        fail("Dictation: could not write clipboard")
      elseif mode == "auto" then
        hs.alert.show("Dictation copied to clipboard", 1.5)
      end
    end
  end
  target, targetError = nil, nil
  if overlay then
    overlay:hide()
  end
  if animation then
    animation:stop()
    animation = nil
  end
  dictation.cancelHotkey:disable()
  recorder.cleanup(recording)
  recording = nil
  state = "idle"
end

local function toggle()
  if state == "idle" then
    if not engine then
      fail("Dictation: " .. tostring(engineError))
      return
    elseif engine.stopped then
      fail("Dictation: backend stopped (see the console); reload Hammerspoon")
      return
    elseif not engine.ready then
      fail("Dictation: backend is still loading")
      return
    end
    if hs.microphoneState(false) == false then
      hs.microphoneState(true)
      fail("Dictation: allow Microphone access in System Settings")
      return
    end
    -- AX inserts the text and reads the selection sent as context.
    local selects = config.includeSelection and prompted()
    if (config.insert ~= "clipboard" or selects) and not hs.accessibilityState(true) then
      fail("Dictation: allow Accessibility access in System Settings")
      return
    end
    local pill = overlay or Overlay.new(config.overlayHeight, config.eqBands)
    overlay = pill
    state = "recording"
    pill:show()
    if not dictation.cancelHotkey:enable() then
      fail("Dictation: could not bind Escape to cancel")
      finish(nil)
      return
    end
    local capture, message = recorder.start(config.eqBands, function(failure)
      fail("Dictation recorder: " .. failure)
      finish(nil)
    end)
    if not capture then
      fail("Dictation: " .. tostring(message))
      finish(nil)
      return
    end
    recording = capture
    -- One 30 fps tick: the ripple intro, the equalizer once the mic opens, then the shimmer.
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
    local context ---@type DictationTranscribeRequest? read at stop, below
    recorder.stop(capture, function(wav, peak, duration)
      -- A too-short take is an accidental tap; a quiet one is a mic problem worth showing.
      if duration < config.minDuration then
        print(("Dictation: discarded (%.2fs < %.2fs)"):format(duration, config.minDuration))
        finish(nil)
        return
      elseif peak < config.minLevel then
        -- Name the input: a Bluetooth headset can deliver pure silence while it switches modes.
        local input = hs.audiodevice.defaultInputDevice()
        local name = input and input:name() or "the default input"
        fail(
          ("Dictation: no speech from %s (peak %.2f < %.2f)"):format(name, peak, config.minLevel)
        )
        finish(nil)
        return
      end
      if not context then
        return -- the take ended at stop: its context could not be read
      end
      context.wav = wav
      local id, message = backend:transcribe(context)
      if not id then
        fail("Dictation: " .. tostring(message))
        finish(nil)
        return
      end
      requests[id], inflight, recording = capture, id, nil
      pill:setThinking()
    end)
    -- After SIGINT so a slow app cannot extend the take; the text goes here only if it keeps focus.
    target, targetError = focused()
    -- The app at stop, not whichever is in front once the wav is final.
    local problem
    context, problem = gatherContext()
    if not context then
      fail("Dictation: " .. tostring(problem))
      finish(nil)
    end
  end
end

-- Each reply owns its recording; cancelled replies cannot finish a later take.
engine, engineError = Engine.new(config, {
  onFinal = function(result)
    -- Saved before anything else, even for a cancelled take, so no result is lost.
    local problem = #result.text > 0 and history.save(result.text, config.history)
    if problem then
      fail("Dictation: " .. problem)
    end
    recorder.cleanup(requests[result.id])
    requests[result.id] = nil
    if inflight == result.id then
      if result.text == "" then
        fail("Dictation: no speech recognized")
      end
      finish(result.text)
    end
    -- nil means saved (false: nothing to save); prune after delivery since it stats every file.
    problem = problem == nil and history.prune(config.history)
    if problem then
      fail("Dictation: " .. problem)
    end
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
    finish(nil)
  end,
})
if not engine then
  fail("Dictation: " .. tostring(engineError))
end

if config.trigger == "hotkey" then
  dictation.hotkey = hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, toggle)
  if not dictation.hotkey then
    fail("Dictation: could not register the hotkey; another app or macOS already uses it")
  end
else
  -- Solo modifier tap: any other key, click, scroll, or modifier voids it.
  local modifier = config.modifierTap
  local types = hs.eventtap.event.types
  local down, downAt, otherUsed = false, 0, false
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
      else
        tapCount = 0 -- input between taps: the next tap starts over
      end
      return false
    end
    local key = event:getKeyCode()
    local flags = event:getFlags()
    local now = hs.timer.secondsSinceEpoch() --[[@as number]]
    if key == modifier.keycode then
      if flags[modifier.flag] then
        -- our modifier went down; another modifier already held is not a solo tap
        local others = false
        for flag in pairs(flags) do
          others = others or (flag ~= modifier.flag and flag ~= "capslock") -- latched, not held
        end
        down, downAt, otherUsed = true, now, others
      else
        -- our modifier went up: a clean, quick tap?
        down = false
        if not otherUsed and (now - downAt) <= modifier.window then
          tapCount = (now - lastTapAt) <= modifier.window and tapCount + 1 or 1
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
      -- a different modifier is involved; not a clean solo tap, and a pending tap starts over
      otherUsed, tapCount = true, 0
    end
    return false
  end)
  dictation.keyTap:start()
  if not dictation.keyTap:isEnabled() then
    fail("Dictation: allow Accessibility access in System Settings, then reload Hammerspoon")
  end
end
-- No trigger can start a take: free the backend's models.
if engine and not (dictation.hotkey or (dictation.keyTap and dictation.keyTap:isEnabled())) then
  engine:stop()
end

-- Bound but disabled; only enabled while dictating so Escape works normally.
dictation.cancelHotkey = hs.hotkey.new({}, "escape", function()
  finish(nil)
end)

-- Chain into Hammerspoon's shutdown so reloads clean up the backend process.
local previousShutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  -- A pending clipboard restore runs now: a reload must not leave the dictation on it.
  if dictation.restore then
    dictation.restore:fire()
  end
  finish(nil)
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
  dictation.cancelHotkey:delete()
  if previousShutdown then
    previousShutdown()
  end
end

return dictation

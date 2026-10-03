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

-- Frontmost app; when prompted(), window title, browser URL, and (opt-in) selection. Also why
-- asked-for context could not be read, which stops the take.
---@return DictationTranscribeRequest, string?
local function gatherContext()
  ---@type DictationTranscribeRequest, string[]
  local context, problems = { wav = "" }, {} -- the caller sets wav
  local app = hs.application.frontmostApplication()
  context.app = app and app:bundleID()
  if not prompted() then
    return context
  end
  -- The window's title, read through accessibility, which tells a failure from no window
  -- (hs.window says "" for both); only a window has one, not the app element some apps return.
  if app then
    local element = hs.axuielement.applicationElement(app)
    local window, failed = nil, "no accessibility element" ---@type any, string?
    if element then
      window, failed = element:attributeValue("AXFocusedWindow")
    end
    local title
    if window ~= nil and not failed then
      -- Something else handed back is reported, never raised.
      local read, value, problem = pcall(function()
        local role, failure = window:attributeValue("AXRole")
        if failure or role ~= "AXWindow" then
          return nil, failure
        end
        return window:attributeValue("AXTitle")
      end)
      if read then
        title, failed = value, problem
      else
        failed = "the focused window is no accessibility element"
      end
    end
    if failed and failed ~= "Attribute is not supported by target" then
      problems[#problems + 1] = "could not read the window title: " .. failed
    elseif type(title) == "string" then
      context.title = clip(title)
    end
  end
  -- URL of the front tab when the app is a known browser; none without a window. Not after the
  -- title failed: a hung browser would hang this too.
  local browser = context.app and browsers[context.app]
  if browser and #problems == 0 then
    -- Bounded: it runs on Hammerspoon's main thread.
    local tab = browser == "Safari" and "current tab" or "active tab"
    local script = ([[with timeout of 2 seconds
  tell application "%s" to if (count windows) > 0 then return URL of %s of front window
end timeout]]):format(browser, tab)
    local ok, url, descriptor = hs.osascript.applescript(script)
    if not ok then
      local message = (descriptor --[[@as table]]).NSAppleScriptErrorMessage
      problems[#problems + 1] = "could not read the URL: " .. tostring(message)
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
      problems[#problems + 1] = "could not read the selection: " .. problem
    elseif type(selection) == "string" and #selection > 0 then
      context.selected = clip(selection)
    end
  end
  return context, #problems > 0 and table.concat(problems, "; ") or nil
end

-- The app's own ⌘V; macOS never signals when the clipboard was read, hence the delay.
---@param text string
local function paste(text)
  -- A restore still waiting means the clipboard holds the last dictation (unless written since):
  -- this paste puts back what that one would have, the user's clipboard.
  local pending = dictation.restore
  local held = pending and hs.pasteboard.changeCount() == pending.count
  local previous = held and pending.previous or hs.pasteboard.readAllData() or {} -- nil: empty
  -- One entry per item, each its own list of types: the item count, not the type count.
  local items = held and pending.items or #hs.pasteboard.allContentTypes()
  -- Transient (nspasteboard.org): clipboard managers record neither this nor the restore.
  local transient = "org.nspasteboard.TransientType"
  if not hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = text, [transient] = "" }) then
    error("could not write clipboard", 0)
  end
  if pending then
    pending.timer:stop()
  end
  -- Before ⌘V: any later write, the app's own included, cancels the restore.
  local count = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  -- Held so GC cannot stop it.
  -- Long enough for a busy app (Slack, VS Code) to read it; any later write cancels it anyway.
  dictation.restore = { count = count, previous = previous, items = items }
  dictation.restore.timer = hs.timer.doAfter(1, function()
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
  return "pasted" -- sent, unconfirmed: a read-only view takes ⌘V silently
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

-- The text spaced against its neighbors in `value` around `range` (a selection or the cursor).
---@param text string
---@param value string
---@param range table?
local function spaced(text, value, range)
  if type(range) ~= "table" or not range.location then
    return text
  end
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
    -- Part of a word replaced: "fo[ob]ar" + "baz" is "fobazar" (not beside an emoji).
    or (before .. last .. after):match("^%w%w%w$") ~= nil
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
  return text
end

-- Insert into the field focused at stop: true once written, "pasted" when sent with ⌘V, false
-- when there is no field. Raises on failure.
---@param text string
---@return boolean|"pasted"
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
  -- A field that takes no write still shows its text and cursor, if any, to space against; one
  -- that hides them (a terminal) gets the text as dictated. A failed read stops delivery.
  local function shown()
    local value = read(element, "AXValue")
    return type(value) == "string" and spaced(text, value, read(element, "AXSelectedTextRange"))
      or text
  end
  -- Mail's compose body is an editable page: its value is settable, its selection is not.
  if role == "AXWebArea" and settable(element, "AXValue") then
    return paste(shown())
  end
  -- Text roles only: Chromium also takes (and drops) text writes on sliders, buttons, toolbars.
  if role ~= "AXTextField" and role ~= "AXTextArea" and role ~= "AXComboBox" then
    return false
  end
  if not settable(element, "AXSelectedText") then
    -- Terminals and Messages take no writes: paste. Read-only views look alike; ⌘V fails silently.
    return paste(shown())
  end
  -- Nothing to space against or compare without a string value.
  local value = read(element, "AXValue")
  if type(value) ~= "string" then
    return false
  end
  local selected = read(element, "AXSelectedText")
  text = spaced(text, value, read(element, "AXSelectedTextRange"))
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

-- Move a take's recording into history when nothing it said was saved: it is the only copy.
-- One that cannot move stays where it is, and the next load tries again (recorder.leftovers).
---@param capture DictationRecording
---@return boolean kept
local function keep(capture)
  local problem = history.keep(capture.wav, config.history)
  if problem then
    fail("Dictation: " .. problem)
    return false
  end
  recorder.cleanup(capture)
  return true
end

-- Keep each recording; how many were kept and where, or nil for none.
---@param captures DictationRecording[]
---@return string?
local function keepAll(captures)
  local kept = 0
  for _, capture in ipairs(captures) do
    kept = kept + (keep(capture) and 1 or 0)
  end
  local where = config.history.directory
  return kept > 0 and ("%d recording%s kept in %s"):format(kept, kept > 1 and "s" or "", where)
    or nil
end

-- Deliver the result and return to idle.
---@param text string?
---@return boolean delivered written or copied, so not a ⌘V nothing confirms
local function finish(text)
  inflight = nil
  local delivered = false
  if text and #text > 0 then
    local mode = config.insert
    if mode == "clipboard" then
      -- Kept (not transient) so it can be pasted by hand.
      delivered = hs.pasteboard.setContents(text)
      if not delivered then
        fail("Dictation: could not write clipboard")
      end
    else
      local ok, result = pcall(insertText, text)
      delivered = ok and result == true
      if not (ok and result) then
        fail("Dictation: " .. (ok and "no text field is focused" or tostring(result)))
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
  return delivered
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
    -- AX inserts the text and reads the context: the window title and the selection.
    if (config.insert ~= "clipboard" or prompted()) and not hs.accessibilityState(true) then
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
        -- Reads the PCM ffmpeg writes to a file: hs.task drops non-UTF-8 output, so its stream
        -- callback can't carry audio. One read per animation frame (~0.15 ms), no timer of its own.
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
    local context, unread ---@type DictationTranscribeRequest?, string? read at stop, below
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
      -- No take without the context asked for; none once the backend died during it.
      local id, message = nil, unread
      if not unread then
        local request = assert(context, "the context is read at stop, before the wav is final")
        request.wav = wav
        id, message = backend:transcribe(request)
      end
      if not id then
        -- Its recording is the only copy, so keep it.
        recording = nil -- kept, or left where it is: not for finish() to clean up
        local kept = keep(capture) and "; the recording is kept in " .. config.history.directory
        fail("Dictation: " .. tostring(message) .. (kept or ""))
        finish(nil)
        return
      end
      requests[id], inflight, recording = capture, id, nil
      pill:setThinking()
    end)
    -- After SIGINT so a slow app cannot extend the take; the text goes here only if it keeps focus.
    target, targetError = focused()
    -- The app at stop, not whichever is in front once the wav is final.
    -- Run to the end: an error here would leave the take waiting, so it stops it instead.
    local gathered, found, problem = pcall(gatherContext)
    if gathered then
      context, unread = found, problem
    else
      context, unread = nil, "could not read the context: " .. tostring(found)
    end
  end
end

-- Each reply owns its recording; cancelled replies cannot finish a later take.
engine, engineError = Engine.new(config, {
  onFinal = function(result)
    -- Saved before anything else, even for a cancelled take, so no result is lost; with nothing to
    -- type (the cleanup heard no coherent speech), what the speech model heard.
    local kept = #result.text > 0 and result.text or result.heard
    local problem = kept ~= nil and #kept > 0 and history.save(kept, config.history)
    local capture = requests[result.id]
    requests[result.id] = nil
    if problem then
      -- Reported, but the text is still delivered: stopping here would lose the only copy.
      fail("Dictation: " .. problem)
    end
    local delivered = false
    if inflight == result.id then
      if result.text == "" then
        local saved = result.heard and problem == nil and " (what was heard is in history)" or ""
        fail("Dictation: no speech recognized" .. saved)
      end
      delivered = finish(result.text)
    end
    if problem and not delivered then
      -- Neither saved nor delivered (cancelled, focus moved): the recording is all that is left.
      if capture and keep(capture) then
        fail("Dictation: the recording is kept in " .. config.history.directory)
      end
    else
      recorder.cleanup(capture)
    end
    -- nil means saved (false: nothing to save); prune after delivery since it stats every file.
    problem = problem == nil and history.prune(config.history)
    if problem then
      fail("Dictation: " .. problem)
    end
  end,
  onError = function(message, id, heard)
    -- Nothing said is lost: what was heard is saved, and failing that the recording is kept.
    local saved = false
    if heard and #heard > 0 then
      local problem = history.save(heard, config.history)
      if problem then
        fail("Dictation: " .. problem) -- even for a cancelled take, as onFinal does
      else
        saved, message = true, message .. " (what was heard is in history)"
        -- As after a result, or takes that keep failing would grow the folder past its cap.
        problem = history.prune(config.history)
        if problem then
          fail("Dictation: " .. problem)
        end
      end
    end
    if id then
      local capture = requests[id]
      requests[id] = nil
      if saved then
        recorder.cleanup(capture)
      elseif capture and keep(capture) then
        message = message .. "; the recording is kept in " .. config.history.directory
        if inflight ~= id then
          fail("Dictation backend: " .. message) -- cancelled, but told where its audio went
        end
      end
      if inflight ~= id then
        return
      end
    else
      -- The backend died: what it had not transcribed survives only as recordings, so keep them.
      local captures = {}
      for key, capture in pairs(requests) do
        requests[key], captures[#captures + 1] = nil, capture
      end
      local kept = keepAll(captures)
      message = message .. (kept and "; " .. kept or "")
    end
    fail("Dictation backend: " .. message)
    -- A take still recording or finalizing goes on: stopped, it finds no backend and is kept.
    if not recording then
      finish(nil)
    end
  end,
})
if not engine then
  fail("Dictation: " .. tostring(engineError))
end

-- Recordings a crash left are the only copies of what was said: kept in history, and announced.
local recovered = keepAll(recorder.leftovers())
if recovered then
  fail("Dictation: " .. recovered .. ", left by a crash")
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
            -- After the tap returns: stopping reads Accessibility (and AppleScript), and a slow app
            -- must not hold every key and click while the tap waits on it.
            dictation.deferred = hs.timer.doAfter(0, toggle)
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
    dictation.restore.timer:fire()
  end
  -- The take still transcribing keeps its recording: nothing said is lost to a reload. Cancelled
  -- ones go, as does one stopped but not yet sent: ffmpeg is still finishing its wav (a few ms),
  -- and the reload's signal would cut that short.
  local capture = inflight and requests[inflight]
  if capture then
    requests[inflight] = nil
    if keep(capture) then
      print("Dictation: the take still transcribing is kept in " .. config.history.directory)
    end
  end
  finish(nil)
  if engine then
    engine:stop()
  end
  for id, cancelled in pairs(requests) do
    recorder.cleanup(cancelled)
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

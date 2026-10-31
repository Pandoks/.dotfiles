local Engine = require("dictation.engine")
local Overlay = require("dictation.overlay")
local history = require("dictation.history")
local logger = require("lib.logger")
local recorder = require("dictation.recorder")
local spaced = require("dictation.spacing")

---@param message string
local function fail(message)
  logger.error("Dictation: " .. message)
end

local config = require("dictation.defaults")
for key, value in pairs(require("dictation.config")) do
  if config[key] == nil then
    fail("unknown setting " .. tostring(key) .. " in config.lua")
  end
  config[key] = value
end
-- JSON can't mix list and map keys.
local function spelled(words)
  local spellings = {}
  for key, value in pairs(words or {}) do
    if type(key) == "number" then
      spellings[value] = {}
    else
      spellings[key] = type(value) == "string" and { value } or value
    end
  end
  return spellings
end
config.words = spelled(config.words)
for _, app in pairs(config.apps) do
  app.words = spelled(app.words)
end

local dictation = {}

---@param problem string
local function disabled(problem)
  fail(problem)
  dictation.hotkey = hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, function()
    fail(problem)
  end)
  return dictation
end

local unprepared = history.prepare(config.history)
if unprepared then
  return disabled(unprepared)
elseif not recorder.ffmpeg then
  return disabled("no ffmpeg found; run mise install")
end

---@type "idle"|"recording"|"thinking"
local state = "idle"
local overlay, recording, animation, deadline
-- The request to type, and the field focused at its stop.
local inflight, target, targetError
local wavs = {}
local restore

-- Gecko applies AX writes after the read-back, which would paste again.
local gecko = {
  ["org.mozilla.firefox"] = true,
  ["org.mozilla.firefoxdeveloperedition"] = true,
  ["org.mozilla.nightly"] = true,
  ["org.mozilla.thunderbird"] = true,
  ["app.zen-browser.zen"] = true,
  ["io.gitlab.librewolf-community"] = true,
  ["one.ablaze.floorp"] = true,
  ["net.waterfox.waterfox"] = true,
}
local transient = "org.nspasteboard.TransientType" -- clipboard managers skip it

local function focused()
  return (hs.axuielement.systemWideElement() --[[@as hs.axuielement]]):attributeValue(
    "AXFocusedUIElement"
  )
end

---@param text string
local function paste(text)
  -- Back-to-back pastes restore the clipboard from before the first.
  local chained = restore and hs.pasteboard.changeCount() == restore.changeCount
  local previous = chained and restore.previous or hs.pasteboard.readAllData() or {}
  local itemCount = chained and restore.itemCount or #hs.pasteboard.allContentTypes()
  if not hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = text, [transient] = "" }) then
    error("could not write clipboard", 0)
  end
  if restore then
    restore.timer:stop()
  end
  local changeCount = hs.pasteboard.changeCount()
  -- 1 s lets a busy app (Slack, VS Code) read it.
  restore = {
    changeCount = changeCount,
    previous = previous,
    itemCount = itemCount,
    timer = hs.timer.doAfter(1, function()
      restore = nil
      if hs.pasteboard.changeCount() ~= changeCount then
        return
      elseif next(previous) == nil then
        hs.pasteboard.clearContents()
        return
      end
      previous[transient] = ""
      if not hs.pasteboard.writeAllData(previous) then
        fail("could not restore the clipboard")
      elseif itemCount > 1 then
        fail(("restored only the first of %d clipboard items"):format(itemCount))
      end
    end),
  }
  -- Last: a layout without "v" raises.
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
end

---@param element hs.axuielement
---@param name string
---@param settable? boolean
local function read(element, name, settable)
  local value, problem
  if settable then
    value, problem = element:isAttributeSettable(name)
  else
    value, problem = element:attributeValue(name)
  end
  if problem and problem ~= "Attribute is not supported by target" then
    error(("could not read the focused field's %s: %s"):format(name, problem), 0)
  end
  return value
end

---@param text string
local function insert(text)
  if targetError then
    error("could not read the focused field at stop: " .. targetError, 0)
  end
  local element, problem = focused()
  if problem then
    error("could not read the focused field: " .. problem, 0)
  elseif not element then
    error("no text field is focused", 0)
  elseif element ~= target then
    error("focus moved while transcribing", 0)
  end
  local role = read(element, "AXRole")
  local value = read(element, "AXValue")
  local range = read(element, "AXSelectedTextRange")
  local app = hs.application.frontmostApplication()
  local bundle = app and app:bundleID()
  -- Unspaced where the value is hidden, or is Ghostty's whole screen at {0, 0}.
  if type(value) == "string" and bundle ~= "com.mitchellh.ghostty" then
    text = spaced(text, value, range)
  end
  -- Mail's compose body is an editable page: its value is settable, its selection is not.
  if role == "AXWebArea" and read(element, "AXValue", true) then
    return paste(text)
  end
  -- Chromium also takes (and drops) text writes on sliders, buttons, toolbars.
  if role ~= "AXTextField" and role ~= "AXTextArea" and role ~= "AXComboBox" then
    error("no text field is focused", 0)
  end
  -- Terminals and Messages take no writes; read-only views look alike and ignore ⌘V.
  if not read(element, "AXSelectedText", true) or gecko[bundle] then
    return paste(text)
  end
  if type(value) ~= "string" then
    error("no text field is focused", 0)
  end
  local selected = read(element, "AXSelectedText")
  local written, reason = element:setAttributeValue("AXSelectedText", text)
  if not written then
    error(reason or "could not insert into the focused field", 0)
  end
  -- Chromium and Electron accept the write and ignore it; identical text over itself is a no-op.
  if read(element, "AXValue") == value and selected ~= text then
    paste(text)
  end
end

---@param text string?
---@param saved boolean?
local function finish(text, saved)
  local ok, problem = true, nil
  if text and config.insert == "clipboard" then
    ok, problem = hs.pasteboard.setContents(text), "could not write clipboard"
  elseif text then
    ok, problem = pcall(insert, text)
  end
  if not ok then
    fail(tostring(problem) .. (saved and " (the text is in history)" or ""))
  end
  if overlay then
    overlay.canvas:delete()
  end
  if animation then
    animation:stop()
  end
  if deadline then
    deadline:stop()
  end
  recorder.cleanup(recording)
  overlay, recording, animation, deadline = nil, nil, nil, nil
  inflight, target, targetError = nil, nil, nil
  state = "idle"
  dictation.cancel:disable()
end

---@param wav string
local function keep(wav)
  local problem = history.keep(wav, config.history)
  fail(
    problem and ("could not keep %s: %s"):format(wav, problem)
      or "the recording is kept in " .. config.history.directory
  )
end

-- Kills ffmpeg and keeps its wav if it caught audio; finish() then deletes nothing.
local function salvage()
  recorder.cleanup(recording, true)
  if hs.fs.attributes(recording.wav) then
    keep(recording.wav)
  end
  recording = nil
end

---@param id integer
---@param text string?
---@return boolean saved
local function settle(id, text)
  local wav = wavs[id]
  wavs[id] = nil
  if text == "" then
    os.remove(wav)
    return false
  elseif text then
    local problem = history.save(text, config.history)
    if not problem then
      os.remove(wav)
      return true
    end
    fail(problem)
  end
  keep(wav)
  return false
end

local engine, problem = Engine.new(config, {
  onFinal = function(result)
    local text = result.text ~= "" and result.text or nil
    local saved = settle(result.id, result.text)
    if inflight == result.id then
      if not text then
        fail("no speech recognized")
      end
      finish(text, saved)
    end
    -- After delivery: pruning past the cap lists the folder.
    local unpruned = saved and history.prune(config.history)
    if unpruned then
      fail(unpruned)
    end
  end,
  onError = function(message, id, heard)
    -- No id: the backend died with every take.
    local saved = false
    for take in pairs(wavs) do
      if take == id or not id then
        saved = settle(take, heard)
      end
    end
    fail("backend: " .. message .. (saved and " (what was heard is in history)" or ""))
    -- A take still recording goes on.
    if inflight and (inflight == id or not id) then
      finish()
    end
    local unpruned = saved and history.prune(config.history)
    if unpruned then
      fail(unpruned)
    end
  end,
})
if not engine then
  return disabled(tostring(problem))
end

local function toggle()
  if state == "idle" then
    if not engine.ready then
      fail(
        engine.stopped and "backend stopped (see the console); reload Hammerspoon"
          or "backend is still loading"
      )
      return
    elseif hs.microphoneState(false) == false then
      hs.microphoneState(true)
      fail("allow Microphone access in System Settings")
      return
    elseif config.insert ~= "clipboard" and not hs.accessibilityState(true) then
      fail("allow Accessibility access in System Settings")
      return
    end
    -- New each take: a reused one can drop off the spaces it joined.
    local pill = Overlay.new()
    overlay, state = pill, "recording"
    local capture, failure = recorder.start(Overlay.bands, function(message)
      fail("recorder: " .. message)
      salvage()
      finish()
    end)
    if not capture then
      fail(tostring(failure))
      return finish()
    end
    recording = capture
    animation = hs.timer.doEvery(1 / 30, function()
      -- An error would stop the timer silently.
      local ok, trace = xpcall(function()
        pill:update(state == "recording" and recorder.analyze(capture))
      end, debug.traceback)
      if not ok then
        fail("overlay: " .. tostring(trace))
        finish()
      end
    end)
    if not dictation.cancel:enable() then
      fail("could not bind Escape to cancel")
    end
  elseif state == "recording" then
    state = "thinking"
    local pill = overlay
    local app = hs.application.frontmostApplication()
    local bundle = app and app:bundleID()
    recorder.stop(recording, function(wav, peak, duration)
      assert(deadline):stop()
      deadline = nil
      -- Too short is an accidental tap; too quiet is a mic problem worth showing.
      if duration < config.minDuration then
        pcall(
          print,
          ("Dictation: discarded (%.2fs < minDuration %.2fs)"):format(duration, config.minDuration)
        )
        return finish()
      elseif peak < config.minLevel then
        -- Named: a Bluetooth headset delivers silence while it switches modes.
        local input = hs.audiodevice.defaultInputDevice()
        fail(
          ("no speech from %s (peak %.2f < minLevel %.2f)"):format(
            input and input:name() or "the default input",
            peak,
            config.minLevel
          )
        )
        return finish()
      end
      local id, refused = engine:transcribe(wav, bundle)
      if not id then
        fail(tostring(refused))
        salvage()
        return finish()
      end
      wavs[id], inflight, recording = wav, id, nil
      pill.thinking = true
    end)
    -- After SIGINT, so a slow app cannot extend the take.
    target, targetError = focused()
    -- An unplugged mic makes ffmpeg ignore SIGINT; counted from here, as focused() can block.
    deadline = hs.timer.doAfter(2, function()
      fail("the recording did not finish in 2 s")
      salvage()
      finish()
    end)
  end
end

-- A key hs.hotkey doesn't know raises; the backend must not stay running without a hotkey.
local bound, hotkey = pcall(hs.hotkey.bind, config.hotkey.mods, config.hotkey.key, toggle)
dictation.hotkey = bound and hotkey or nil
if not dictation.hotkey then
  fail(bound and "could not register the hotkey; another app or macOS uses it" or tostring(hotkey))
  engine:stop()
end
dictation.cancel = hs.hotkey.new({}, "escape", finish)

local shutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  if restore then
    restore.timer:fire()
  end
  if recording then
    salvage()
  end
  engine:stop()
  for id in pairs(wavs) do
    settle(id)
  end
  if shutdown then
    shutdown()
  end
end

return dictation

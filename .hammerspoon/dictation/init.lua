local Engine = require("dictation.engine")
local Overlay = require("dictation.overlay")
local history = require("dictation.history")
local recorder = require("dictation.recorder")
local spaced = require("dictation.spacing")

---@param message string
local function fail(message)
  print("Dictation: " .. message)
  hs.alert.show("Dictation: " .. message:match("^[^\n]+"), 5)
end

-- config.lua's settings over the defaults, each replacing its default whole.
local config = require("dictation.defaults")
for key, value in pairs(require("dictation.config")) do
  if config[key] == nil then
    fail("config.lua: unknown setting " .. tostring(key))
  end
  config[key] = value
end
-- "Slack" becomes Slack = {}: JSON has no table that is a list and a map at once.
local function spelled(words)
  local out = {}
  for key, value in pairs(words or {}) do
    if type(key) == "number" then
      out[value] = {}
    else
      out[key] = value
    end
  end
  return out
end
config.words = spelled(config.words)
for _, app in pairs(config.apps) do
  app.words = spelled(app.words)
end

local dictation = {}

local unprepared = history.prepare(config.history)
if unprepared then
  fail(unprepared)
end

---@type "idle"|"recording"|"thinking"
local state = "idle"
local overlay, recording, animation
-- The request whose text gets typed, and the field focused when its take stopped.
local inflight, target, targetError
-- Wavs the backend has yet to answer, by request id.
local wavs = {}
-- The clipboard to put back after the last paste.
local restore

-- Gecko apps apply accessibility writes late, after the read-back that would then paste it again.
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

-- The app's own ⌘V, then the clipboard put back; macOS never says when the app read it.
---@param text string
local function paste(text)
  -- A paste before the last one's restore keeps the clipboard from before that one.
  local held = restore and hs.pasteboard.changeCount() == restore.count
  local previous = held and restore.previous or hs.pasteboard.readAllData() or {}
  local items = held and restore.items or #hs.pasteboard.allContentTypes()
  if not hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = text, [transient] = "" }) then
    error("could not write clipboard", 0)
  end
  if restore then
    restore.timer:stop()
  end
  local count = hs.pasteboard.changeCount()
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  -- 1 s lets a busy app (Slack, VS Code) read it; any later write cancels the restore.
  restore = {
    count = count,
    previous = previous,
    items = items,
    timer = hs.timer.doAfter(1, function()
      restore = nil
      if hs.pasteboard.changeCount() ~= count then
        return
      elseif next(previous) == nil then
        hs.pasteboard.clearContents()
        return
      end
      previous[transient] = ""
      if not hs.pasteboard.writeAllData(previous) then
        fail("could not restore the clipboard")
      elseif items > 1 then
        fail(("restored only the first of %d clipboard items"):format(items))
      end
    end),
  }
end

-- An attribute of the focused field, or whether it is settable; nil when unsupported.
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

-- Into the field focused at stop, by accessibility write or ⌘V. Raises on failure.
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
  -- A field hiding its text (a terminal) gets the text as dictated.
  text = type(value) == "string" and spaced(text, value, range) or text
  -- Mail's compose body is an editable page: its value is settable, its selection is not.
  if role == "AXWebArea" and read(element, "AXValue", true) then
    return paste(text)
  end
  -- Text roles only: Chromium also takes (and drops) text writes on sliders, buttons, toolbars.
  if role ~= "AXTextField" and role ~= "AXTextArea" and role ~= "AXComboBox" then
    error("no text field is focused", 0)
  end
  local app = hs.application.frontmostApplication()
  -- Terminals and Messages take no writes; read-only views look alike and ignore ⌘V.
  if not read(element, "AXSelectedText", true) or (app and gecko[app:bundleID()]) then
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

-- Deliver `text`, if any, and return to idle.
---@param text string?
local function finish(text)
  if text and config.insert == "clipboard" then
    if not hs.pasteboard.setContents(text) then
      fail("could not write clipboard")
    end
  elseif text then
    local ok, problem = pcall(insert, text)
    if not ok then
      fail(tostring(problem))
    end
  end
  if overlay then
    overlay.canvas:delete()
  end
  if animation then
    animation:stop()
  end
  recorder.cleanup(recording)
  overlay, recording, animation, inflight, target, targetError = nil, nil, nil, nil, nil, nil
  state = "idle"
  dictation.cancel:disable()
end

-- Move a recording into history: with no transcript, it is the only copy of what was said.
---@param wav string
local function keep(wav)
  local problem = history.keep(wav, config.history)
  fail(
    problem and ("could not keep %s: %s"):format(wav, problem)
      or "the recording is kept in " .. config.history.directory
  )
end

-- Save the text that came back for take `id` and delete its wav; with no reply, keep the wav.
---@param id integer
---@param text string? "" when nothing was heard
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

-- Each reply settles its take; only the one still waiting is delivered.
local engine, problem = Engine.new(config, {
  onFinal = function(result)
    local text = result.text ~= "" and result.text or nil
    -- With nothing to type, what the speech model heard is saved.
    local saved = settle(result.id, text or result.heard or "")
    if inflight == result.id then
      if not text then
        fail("no speech recognized" .. (saved and " (what was heard is in history)" or ""))
      end
      finish(text)
    end
    -- After delivery: past the cap it lists the folder.
    local unpruned = saved and history.prune(config.history)
    if unpruned then
      fail(unpruned)
    end
  end,
  onError = function(message, id, heard)
    -- No id: the backend died, and none of the takes it holds will be answered.
    local saved = false
    for key in pairs(wavs) do
      if key == id or not id then
        saved = settle(key, heard)
      end
    end
    fail("backend: " .. message .. (saved and " (what was heard is in history)" or ""))
    -- A take still recording goes on, and is kept when the backend refuses it.
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
  fail(tostring(problem))
  -- The hotkey says why too, rather than doing nothing.
  dictation.hotkey = hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, function()
    fail(tostring(problem))
  end)
  return dictation
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
    local pill = Overlay.new(config.overlayHeight)
    overlay, state = pill, "recording"
    local capture, failure = recorder.start(Overlay.bands, function(message)
      fail("recorder: " .. message)
      finish()
    end)
    if not capture then
      fail(tostring(failure))
      return finish()
    end
    recording = capture
    -- 30 fps: the ripple intro, the equalizer once the mic opens, then the shimmer.
    animation = hs.timer.doEvery(1 / 30, function()
      pill:update(state == "recording" and recorder.poll(capture))
    end)
    if not dictation.cancel:enable() then
      fail("could not bind Escape to cancel")
    end
  elseif state == "recording" then
    state = "thinking"
    local pill = overlay
    -- The app at stop, for its per-app style and vocabulary.
    local app = hs.application.frontmostApplication()
    local bundle = app and app:bundleID()
    recorder.stop(recording, function(wav, peak, duration)
      -- Too short is an accidental tap; too quiet is a mic problem worth showing.
      if duration < config.minDuration then
        print(("Dictation: discarded (%.2fs < %.2fs)"):format(duration, config.minDuration))
        return finish()
      elseif peak < config.minLevel then
        -- Named: a Bluetooth headset delivers silence while it switches modes.
        local input = hs.audiodevice.defaultInputDevice()
        fail(
          ("no speech from %s (peak %.2f < %.2f)"):format(
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
        recording = nil -- kept, so not for finish() to delete
        keep(wav)
        return finish()
      end
      wavs[id], inflight, recording = wav, id, nil
      pill.thinking = true
    end)
    -- After SIGINT, so a slow app cannot extend the take.
    target, targetError = focused()
  end
end

dictation.hotkey = hs.hotkey.bind(config.hotkey.mods, config.hotkey.key, toggle)
if not dictation.hotkey then
  fail("could not register the hotkey; another app or macOS already uses it")
  engine:stop()
end
-- Enabled only while dictating, so Escape works normally otherwise.
dictation.cancel = hs.hotkey.new({}, "escape", finish)

local shutdown = hs.shutdownCallback
hs.shutdownCallback = function()
  -- A reload must not leave the dictation on the clipboard.
  if restore then
    restore.timer:fire()
  end
  finish()
  engine:stop()
  -- No transcript will come back for these.
  for id in pairs(wavs) do
    settle(id)
  end
  if shutdown then
    shutdown()
  end
end

return dictation

local root, frameworks, scratch = arg[1], arg[2], arg[3]
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
package.path = root .. "/../?.lua;" .. package.path
local passed, alerts, notices, strokes, timers, changes, takeCount, serial =
  0, {}, {}, {}, {}, 0, 0, 0
local toggle, escape, handlers, deliver, focus, frontmost, recorded, sent, ipcDead, began, vanished
local settings, recording, loading
local engines, unloads = {}, {}
local tick, broken, unshowable, armed, shown, chained, unstartable
local clipboard = { ["public.utf8-plain-text"] = "mine" }
local transient = "org.nspasteboard.TransientType"
local directory = scratch .. "/init-history"

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

local function stub(fields)
  return setmetatable(fields or {}, {
    __index = function()
      return function()
        return true
      end
    end,
  })
end

local function import(name, environment)
  return assert(
    loadfile(root .. "/" .. name .. ".lua", "t", setmetatable(environment, { __index = _G }))
  )()
end

local config = import("defaults", {})
local mine = import("config", {})
mine.words = { "Slack", Raycast = { "ray cast" } }
mine.apps =
  { ["com.x"] = { words = { "Zed", Neovim = "neo vim" } }, ["com.y"] = { style = "terse" } }
mine.cleanup, mine.speech, mine.theme = false, { model = "mine" }, "flat"
config.history.directory, config.minDuration, config.minLevel = directory, 0, 0
local hs = {
  fs = fs,
  alert = {
    show = function(message)
      alerts[#alerts + 1] = message
    end,
  },
  hotkey = {
    bind = function(_, key, callback)
      assert(key ~= "bogus", "Invalid key: bogus")
      toggle = callback
      return stub()
    end,
    -- hs.hotkey logs on enable/disable; hs.ipc's print raises while a dead `hs` CLI is registered.
    new = function(_, _, callback)
      escape = function()
        assert(armed, "Escape is not bound")
        callback()
      end
      local function arm(on)
        return function()
          armed = on
          assert(not ipcDead, "ipc port is no longer valid")
          return true
        end
      end
      return { enable = arm(true), disable = arm(false) }
    end,
  },
  timer = {
    doEvery = function(_, callback)
      tick = callback
      return stub({
        stop = function()
          tick = nil
        end,
      })
    end,
    doAfter = function(seconds, callback)
      if seconds == (config.unloadMinutes or 0) * 60 then
        local unload = { fire = callback }
        unloads[#unloads + 1] = unload
        return {
          stop = function()
            unload.stopped = true
          end,
        }
      end
      local index = #timers + 1
      timers[index] = callback
      return stub({
        fire = callback,
        stop = function()
          timers[index] = function() end
        end,
      })
    end,
  },
  audiodevice = {
    defaultInputDevice = function() end,
  },
  microphoneState = function()
    return true
  end,
  accessibilityState = function()
    return true
  end,
  application = {
    frontmostApplication = function()
      return frontmost
    end,
  },
  axuielement = {
    systemWideElement = function()
      return {
        attributeValue = function()
          return focus
        end,
      }
    end,
  },
  pasteboard = {
    readAllData = function()
      return clipboard
    end,
    allContentTypes = function()
      return clipboard and { {} } or {}
    end,
    writeAllData = function(data)
      clipboard, changes = data, changes + 1
      return true
    end,
    setContents = function(text)
      clipboard, changes = { ["public.utf8-plain-text"] = text }, changes + 1
      return true
    end,
    changeCount = function()
      return changes
    end,
  },
  eventtap = {
    keyStroke = function(mods, key)
      strokes[#strokes + 1] = mods[1] .. "+" .. key
    end,
  },
  shutdownCallback = function()
    chained = true
  end,
}

-- The real lib/glass.lua, over a fake native build.
local function glassModule()
  return import("../lib/glass", {
    require = function()
      return {
        native = function()
          return {}
        end,
      }
    end,
  })
end

local modules = {
  ["dictation.defaults"] = config,
  ["dictation.config"] = mine,
  ["lib.logger"] = import("../lib/logger", {
    hs = hs,
    print = function() end,
    require = function()
      return { show = hs.alert.show }
    end,
  }),
  ["lib.toast"] = {
    show = function(message)
      assert(not unshowable, "the toast raised")
      notices[#notices + 1] = message
    end,
  },
  ["dictation.spacing"] = import("spacing", {}),
  ["dictation.history"] = import("history", { hs = { fs = fs } }),
  ["dictation.overlay"] = {
    new = function()
      shown = true
      return stub({
        delete = function()
          shown = false
        end,
        update = function()
          assert(not broken, "broken frame")
        end,
      })
    end,
  },
  ["dictation.recorder"] = {
    ffmpeg = "/usr/bin/ffmpeg",
    start = function(_, backend, onError)
      if unstartable then
        return nil, "could not start capture task"
      end
      assert(backend == nil or backend == "/tmp/backend.sock", "ffmpeg streams elsewhere")
      takeCount = takeCount + 1
      recorded = ("%s/take%d.wav"):format(scratch, takeCount)
      assert(io.open(recorded, "w")):close()
      recording = { wav = recorded, fail = onError, pid = 4000 + takeCount, backend = backend }
      return recording
    end,
    stop = function(capture, callback)
      capture.done = callback
      deliver = function()
        if capture.done then
          capture.done(capture.wav, 0.5, 1)
        end
        capture.done = nil
      end
    end,
    cleanup = function(capture, kept)
      if capture then
        capture.done, capture.ended = nil, true
        if not kept or capture.empty then
          os.remove(capture.wav)
        end
      end
    end,
    analyze = function() end,
  },
  ["dictation.engine"] = {
    new = function(merged, callbacks)
      if vanished then
        return nil, "backend venv missing"
      end
      handlers, settings = callbacks, merged
      engines[#engines + 1] = {
        ready = not loading,
        socket = "/tmp/backend.sock",
        stop = function(self)
          self.stopped, self.ready = true, false
        end,
        start = function(_, pid, app)
          serial, began = serial + 1, { pid = pid, app = app }
          return serial
        end,
        transcribe = function(_, id, wav, app)
          if id then
            assert(id == serial, "a stop line for another take")
            sent = { wav = wav, app = began.app, pid = began.pid }
          else
            serial, sent = serial + 1, { wav = wav, app = app }
          end
          return serial
        end,
      }
      return engines[#engines]
    end,
  },
}
import("init", {
  hs = hs,
  print = function() end,
  require = function(name)
    return modules[name]
  end,
})

local function app(bundle)
  return {
    bundleID = function()
      return bundle
    end,
  }
end

-- Chromium ignores writes; a terminal takes none.
local function field(before, ignoresWrites, unsettable, role)
  local element = { value = before }
  function element:attributeValue(name)
    return ({
      AXRole = role or "AXTextArea",
      AXValue = self.value,
      AXSelectedText = "",
      AXSelectedTextRange = { location = self.caret or utf8.len(self.value), length = 0 },
    })[name]
  end
  function element.isAttributeSettable()
    return not unsettable
  end
  function element:setAttributeValue(_, text)
    self.written = text
    if not ignoresWrites then
      self.value = self.value .. text
    end
    return self
  end
  return element
end

local function dictate(element)
  alerts, notices, strokes, focus = {}, {}, {}, element
  toggle()
  toggle()
  deliver()
  return serial
end

local function saved(text)
  for entry in fs.dir(directory) do
    local file = entry:match("%.txt$") and assert(io.open(directory .. "/" .. entry))
    if file and file:read("a") == text .. "\n" then
      return true
    end
  end
  return false
end

local function wavs()
  local count = 0
  for entry in fs.dir(directory) do
    count = count + (entry:match("%.wav$") and 1 or 0)
  end
  return count
end

test("a field that takes the write gets the text spaced, saved, its recording deleted", function()
  local element = field("Hello")
  frontmost = app("com.apple.Notes")
  handlers.onFinal({ id = dictate(element), text = "there." })
  assert(sent.app == "com.apple.Notes" and sent.pid == recording.pid, tostring(sent.app))
  assert(element.value == "Hello there." and #strokes == 0 and #alerts == 0, element.value)
  assert(saved("there."), "not the text saved")
  assert(not fs.attributes(sent.wav) and wavs() == 0, "the recording is left")
  assert(not shown and not tick and not armed, "the pill, its frames, or Escape outlived the take")
end)

test("a write the field ignores (Chromium) is pasted, then the clipboard put back", function()
  local types = hs.pasteboard.allContentTypes
  hs.pasteboard.allContentTypes = function()
    return { {}, {} }
  end
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "you" })
  hs.pasteboard.allContentTypes = types
  assert(strokes[1] == "cmd+v" and clipboard["public.utf8-plain-text"] == " you", strokes[1])
  assert(clipboard[transient] == "", "clipboard managers record the dictation")
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
  assert(clipboard[transient] == "", "clipboard managers record the restore")
  assert(
    alerts[1] == "Dictation: restored only the first of 2 clipboard items",
    tostring(alerts[1])
  )
end)

test("a ⌘V that raises (a layout without v) still puts the clipboard back", function()
  local stroke = hs.eventtap.keyStroke
  hs.eventtap.keyStroke = function()
    error("Invalid key: v", 0)
  end
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "you" })
  hs.eventtap.keyStroke = stroke
  assert(alerts[1] == "Dictation: Invalid key: v (the text is in history)", tostring(alerts[1]))
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
end)

test("a terminal's or a Gecko app's field is pasted into, never written", function()
  local screen = field("Last login: Mon\n$ ", false, true)
  screen.caret = 0 -- Ghostty's value is its whole screen, its range {0, 0}
  for _, case in ipairs({
    { screen, "com.mitchellh.ghostty", "ls" },
    { field("Hi"), "org.mozilla.firefox", " ls" }, -- applies writes late
  }) do
    local element, bundle, want = table.unpack(case)
    frontmost = app(bundle)
    handlers.onFinal({ id = dictate(element), text = "ls" })
    assert(element.written == nil and strokes[1] == "cmd+v", bundle)
    assert(clipboard["public.utf8-plain-text"] == want, clipboard["public.utf8-plain-text"])
    timers[#timers]()
  end
  frontmost = nil
end)

test("a second paste before the restore puts back the clipboard from before the first", function()
  local types = hs.pasteboard.allContentTypes
  hs.pasteboard.allContentTypes = function()
    return { {}, {} }
  end
  handlers.onFinal({ id = dictate(field("a", true)), text = "one" })
  hs.pasteboard.allContentTypes = types
  handlers.onFinal({ id = dictate(field("b", true)), text = "two" })
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
  assert(alerts[1] and alerts[1]:find("first of 2", 1, true), tostring(alerts[1]))
end)

test("focus moved while transcribing writes nothing and copies the text", function()
  local element = field("x")
  local id = dictate(element)
  focus = field("y")
  handlers.onFinal({ id = id, text = "moved" })
  assert(not element.written and not focus.written and #strokes == 0, "written")
  assert(
    notices[1] == "Dictation: copied to the clipboard (focus moved while transcribing)",
    tostring(notices[1])
  )
  assert(clipboard["public.utf8-plain-text"] == "moved" and #alerts == 0, tostring(alerts[1]))
  assert(saved("moved"), "not saved")
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
end)

test("with nothing focused the text is copied; a failed copy alerts and keeps history", function()
  handlers.onFinal({ id = dictate(nil), text = "nowhere" })
  assert(
    notices[1] == "Dictation: copied to the clipboard (no text field is focused)",
    tostring(notices[1])
  )
  assert(clipboard["public.utf8-plain-text"] == "nowhere" and #alerts == 0, tostring(alerts[1]))
  assert(clipboard[transient] == nil, "hidden from clipboard managers")
  local setContents = hs.pasteboard.setContents
  hs.pasteboard.setContents = function()
    return false
  end
  handlers.onFinal({ id = dictate(nil), text = "lost" })
  hs.pasteboard.setContents = setContents
  assert(
    alerts[1]
        == "Dictation: no text field is focused; could not write clipboard (the text is in history)"
      and #notices == 0,
    tostring(alerts[1])
  )
  assert(saved("lost"), "not saved")
  unshowable = true
  handlers.onFinal({ id = dictate(nil), text = "unshown" })
  unshowable = false
  assert(not shown and not armed, "a toast that raised left the take running")
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
end)

test("a reply to a cancelled take is saved; the next take still gets its own", function()
  for _, reply in ipairs({
    function(id)
      handlers.onFinal({ id = id, text = "late " .. id })
    end,
    function(id)
      handlers.onError("cleanup failed", id, "late " .. id)
    end,
  }) do
    local element = field("Hi")
    local cancelled = dictate(element)
    escape()
    local waiting = dictate(element)
    reply(cancelled)
    handlers.onFinal({ id = waiting, text = "now" })
    assert(element.value == "Hi now" and saved("late " .. cancelled), element.value)
    assert(#notices == 0, tostring(notices[1]))
  end
end)

test("a cleanup that fails types what was heard, saved in place of the recording", function()
  local element = field("Hi")
  handlers.onError("the cleanup rewrote what was said", dictate(element), "heard it")
  assert(element.value == "Hi heard it" and #alerts == 0, tostring(alerts[1] or element.value))
  assert(
    notices[1] == "Dictation: used what was heard (backend: the cleanup rewrote what was said)",
    tostring(notices[1])
  )
  assert(saved("heard it") and not fs.attributes(recorded), "not saved, or the recording left")
  assert(wavs() == 0, "a recording kept")
  unshowable = true
  handlers.onError("the cleanup returned no words", dictate(nil), "heard it")
  unshowable = false
  assert(clipboard["public.utf8-plain-text"] == "heard it", clipboard["public.utf8-plain-text"])
  assert(not shown and not armed, "a toast that raised left the take running")
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
  local rejecting = field("Hi")
  local id = dictate(rejecting)
  function rejecting.setAttributeValue()
    return nil, "Messaging failed"
  end
  handlers.onError("the cleanup rewrote what was said", id, "heard it")
  assert(#notices == 0, "told it was used: " .. tostring(notices[1]))
  assert(alerts[1] == "Dictation: Messaging failed (the text is in history)", tostring(alerts[1]))
  assert(alerts[2] == "Dictation: backend: the cleanup rewrote what was said", tostring(alerts[2]))
end)

test("a take whose transcript isn't saved keeps its recording in history", function()
  for _, case in ipairs({
    {
      "an error reply",
      function(id)
        handlers.onError("speech failed", id)
      end,
    },
    {
      "the backend dying",
      function()
        handlers.onError("exited (code 1)")
      end,
    },
    {
      "a transcript it can't save",
      function(id)
        local history = modules["dictation.history"]
        local save = history.save
        history.save = function()
          return "disk full"
        end
        handlers.onFinal({ id = id, text = "lost" })
        history.save = save
      end,
    },
  }) do
    local name, reply = table.unpack(case)
    local count = wavs()
    reply(dictate(field("Hi")))
    assert(wavs() == count + 1 and not fs.attributes(recorded), name .. ": not kept")
    assert(table.concat(alerts, "\n"):find("kept in", 1, true), name .. ": not told")
  end
end)

test("a take recording or stopping when the backend dies is kept", function()
  for _, stopped in ipairs({ false, true }) do
    local count = wavs()
    focus = field("Hi")
    toggle()
    if stopped then
      toggle()
    end
    handlers.onError("exited (code 1)")
    assert(wavs() == count + 1 and not fs.attributes(recorded), "the take was dropped")
  end
end)

test("a stop ffmpeg doesn't finish in 2 s, slow apps aside, keeps the take and says so", function()
  local count, element, before = wavs(), field("Hi"), #timers
  local system = hs.axuielement.systemWideElement
  -- An app slow to answer: every timer started by then comes due first.
  hs.axuielement.systemWideElement = function()
    assert(recording.done, "a slow app kept the take recording")
    for index = before + 1, #timers do
      timers[index]()
    end
    return system()
  end
  local id = dictate(element)
  hs.axuielement.systemWideElement = system
  assert(#alerts == 0, "a slow app used up the 2 s: " .. tostring(alerts[1]))
  local exited = timers[#timers] -- ffmpeg exited in time: its deadline is stopped
  exited()
  handlers.onFinal({ id = id, text = "in time" })
  assert(element.value == "Hi in time" and #alerts == 0, tostring(alerts[1] or element.value))
  toggle()
  toggle()
  escape()
  focus, alerts = field("Hi"), {}
  toggle()
  exited()
  timers[#timers]() -- cancelled: its deadline is stopped
  assert(shown and #alerts == 0, "an earlier take's deadline ended the next one")
  toggle()
  timers[#timers]()
  assert(tostring(alerts[1]):find("the recording did not finish", 1, true), tostring(alerts[1]))
  assert(recording.ended, "ffmpeg left running")
  assert(wavs() == count + 1 and not fs.attributes(recorded), "not kept")
  assert(not shown and not armed, "the take did not end")
end)

test("config.lua's settings replace the defaults, its words sent as one map", function()
  local json = assert(package.loadlib(frameworks .. "/hs/libjson.dylib", "luaopen_hs_libjson"))()
  local decoded = json.decode(assert(json.encode(settings)))
  assert(decoded.speech.revision == nil and decoded.cleanup == false, "a setting merged")
  assert(next(decoded.words.Slack) == nil, json.encode(decoded.words))
  assert(decoded.words.Raycast[1] == "ray cast", json.encode(decoded.words))
  local words = decoded.apps["com.x"].words
  assert(next(words.Zed) == nil and words.Neovim[1] == "neo vim", json.encode(words))
end)

test("a take too short or too quiet gets no stop line, and is deleted", function()
  for setting, value in pairs({ minDuration = 2, minLevel = 0.75 }) do
    sent = nil
    config[setting] = value
    dictate(field("Hi"))
    config[setting] = 0
    assert(not sent and not fs.attributes(recorded), setting)
    if setting == "minLevel" then
      assert(#alerts > 0, "too quiet alerted nothing")
    end
  end
end)

test("an empty transcript says no speech, deletes its recording, and saves nothing", function()
  local count = wavs()
  handlers.onFinal({ id = dictate(field("Hi")), text = "" })
  assert(alerts[1] == "Dictation: no speech recognized", tostring(alerts[1]))
  assert(wavs() == count and not fs.attributes(recorded), "kept the recording")
  assert(not saved(""), "saved a transcript")
end)

test("a log line raising as Escape is bound or unbound leaves no take half done", function()
  local element = field("Hi")
  focus, ipcDead = element, true
  pcall(toggle)
  ipcDead = false
  toggle()
  deliver()
  ipcDead = true
  pcall(handlers.onFinal, { id = serial, text = "one" })
  ipcDead = false
  handlers.onFinal({ id = dictate(element), text = "two" })
  assert(element.value == "Hi one two", element.value)
end)

test("clipboard mode copies the text, inserts nothing, and says if the copy fails", function()
  local element, setContents = field("Hi"), hs.pasteboard.setContents
  config.insert = "clipboard"
  handlers.onFinal({ id = dictate(element), text = "copied" })
  assert(not element.written and #strokes == 0, "inserted")
  assert(clipboard["public.utf8-plain-text"] == "copied", clipboard["public.utf8-plain-text"])
  hs.pasteboard.setContents = function()
    return false
  end
  handlers.onFinal({ id = dictate(element), text = "lost" })
  config.insert, hs.pasteboard.setContents = "direct", setContents
  assert(
    alerts[1] == "Dictation: could not write clipboard (the text is in history)",
    tostring(alerts[1])
  )
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
end)

test("Escape while recording deletes the take", function()
  focus = field("Hi")
  toggle()
  escape()
  assert(not fs.attributes(recorded), "the recording is left")
end)

test("a failed capture keeps its audio and says why; the next press starts anew", function()
  local count = wavs()
  alerts, focus = {}, field("Hi")
  toggle()
  recording.fail("device lost")
  assert(alerts[1] == "Dictation: recorder: device lost", tostring(alerts[1]))
  assert(wavs() == count + 1 and not fs.attributes(recorded), "not kept")
  local started = takeCount
  alerts = {}
  toggle()
  assert(takeCount == started + 1, "the next press did not start a take")
  recording.empty = true
  recording.fail("capture exited (code 0)")
  assert(#alerts == 1 and wavs() == count + 1, "kept no audio: " .. tostring(alerts[2]))
end)

test("a capture that can't start says why and leaves the hotkey working", function()
  alerts, focus, unstartable = {}, field("Hi"), true
  toggle()
  unstartable = nil
  assert(alerts[1] == "Dictation: could not start capture task" and not shown, tostring(alerts[1]))
  toggle()
  assert(shown and armed, "the next press did not start a take")
  escape()
end)

test("a frame that raises ends the take and says so", function()
  alerts, focus = {}, field("Hi")
  toggle()
  broken = true
  tick()
  broken = false
  assert(alerts[1] and alerts[1]:find("broken frame", 1, true), tostring(alerts[1]))
  assert(not fs.attributes(recorded), "the recording is left")
end)

test("a copy made before the clipboard restore is kept", function()
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "x" })
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "copied" })
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "copied", clipboard["public.utf8-plain-text"])
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
end)

test("a field that hides its value, can't be read, or rejects the write is never copied", function()
  local system = hs.axuielement.systemWideElement
  local function unreadable()
    hs.axuielement.systemWideElement = function()
      return {
        attributeValue = function()
          return nil, "Messaging failed"
        end,
      }
    end
  end
  for _, case in ipairs({
    {
      "no text field is focused",
      function(element)
        local attribute = element.attributeValue
        function element:attributeValue(name)
          if name ~= "AXValue" then
            return attribute(self, name)
          end
        end
      end,
    },
    { "could not read the focused field at stop: Messaging failed", unreadable, true },
    { "could not read the focused field: Messaging failed", unreadable },
    {
      "could not read the focused field's AXRole: Messaging failed",
      function(element)
        local attribute = element.attributeValue
        function element:attributeValue(name)
          if name == "AXRole" then
            return nil, "Messaging failed"
          end
          return attribute(self, name)
        end
      end,
    },
    {
      "Messaging failed",
      function(element)
        function element.setAttributeValue()
          return nil, "Messaging failed"
        end
      end,
    },
  }) do
    local problem, breakField, atStop = table.unpack(case)
    local element = field("Hi")
    if atStop then
      breakField(element)
    end
    local id = dictate(element)
    if not atStop then
      breakField(element)
    end
    handlers.onFinal({ id = id, text = "kept" })
    hs.axuielement.systemWideElement = system
    assert(
      alerts[1] == "Dictation: " .. problem .. " (the text is in history)",
      problem .. ": " .. tostring(alerts[1])
    )
    assert(#notices == 0 and clipboard["public.utf8-plain-text"] == "mine", problem .. ": copied")
  end
end)

test("Mail's compose page is pasted into; a slider's text is copied instead", function()
  local page = field("Hi", false, false, "AXWebArea")
  handlers.onFinal({ id = dictate(page), text = "you" })
  assert(strokes[1] == "cmd+v" and not page.written and #notices == 0, tostring(strokes[1]))
  timers[#timers]()
  local slider = field("50", false, false, "AXSlider")
  handlers.onFinal({ id = dictate(slider), text = "you" })
  assert(not slider.written and #strokes == 0, "wrote into a slider")
  assert(
    notices[1] == "Dictation: copied to the clipboard (no text field is focused)",
    tostring(notices[1])
  )
  assert(clipboard["public.utf8-plain-text"] == "you", clipboard["public.utf8-plain-text"])
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
end)

test("past the history cap a saved take prunes the oldest", function()
  config.history.maxMegabytes = 0
  handlers.onFinal({ id = dictate(field("Hi")), text = "newest" })
  config.history.maxMegabytes = 10
  local transcriptCount = 0
  for entry in fs.dir(directory) do
    transcriptCount = transcriptCount + (entry:match("%.txt$") and 1 or 0)
  end
  assert(transcriptCount == 1, transcriptCount)
end)

test("unloaded when idle, the backend reloads on a press; takes go whole at their stop", function()
  local unloaded, idle, count = engines[#engines], unloads[#unloads], #engines
  assert(not idle.stopped, "the last take armed no unload")
  idle.fire()
  assert(unloaded.stopped, "the backend kept its models")
  chained = false
  hs.shutdownCallback()
  assert(chained, "a shutdown with the backend unloaded raised")
  vanished, alerts = true, {}
  toggle()
  vanished = nil
  assert(alerts[1] == "Dictation: backend venv missing" and not shown, tostring(alerts[1]))
  local element = field("Hi")
  frontmost, loading, began = app("com.apple.Notes"), true, nil
  for _, text in ipairs({ "there.", "again." }) do -- the second while it still loads
    local id = dictate(element)
    assert(#engines == count + 1 and #alerts == 0, "no backend loaded, or an alert")
    assert(not began and not recording.backend, "streamed to a backend still loading")
    assert(sent.app == "com.apple.Notes" and sent.wav == recorded, "the take was not sent whole")
    handlers.onFinal({ id = id, text = text })
  end
  unloads[#unloads].fire()
  assert(not engines[#engines].stopped, "unloaded while it still loads")
  frontmost, loading, engines[#engines].ready = nil, false, true
  assert(element.value == "Hi there. again." and #alerts == 0, element.value)
end)

test("no unload while a take records or thinks, or a cancelled one's reply is due", function()
  local backend, idle = engines[#engines], unloads[#unloads]
  focus = field("Hi")
  toggle()
  idle.fire()
  toggle()
  deliver()
  idle.fire()
  local id = serial
  escape()
  local due = unloads[#unloads]
  due.fire()
  assert(not backend.stopped, "unloaded with a take or its reply due")
  handlers.onFinal({ id = id, text = "late" })
  assert(unloads[#unloads] ~= due, "the reply armed no unload")
  assert(due.stopped, "a superseded unload still fires")
  unloads[#unloads].fire()
  assert(backend.stopped, "never unloaded")
end)

test("a crashed backend is not reloaded: a press says so", function()
  dictate(field("Hi"))
  local crashed = engines[#engines]
  crashed.stopped, crashed.ready = true, false
  handlers.onError("exited (code 1)")
  unloads[#unloads].fire()
  alerts = {}
  toggle()
  assert(engines[#engines] == crashed and not shown, "the crashed backend was replaced")
  assert(
    alerts[1] == "Dictation: backend stopped (see the console); reload Hammerspoon",
    tostring(alerts[1])
  )
  crashed.stopped, crashed.ready = nil, true -- revived for the tests after
end)

local function reload(swapped)
  local main, cancel, shutdown = toggle, escape, hs.shutdownCallback
  import("init", {
    hs = hs,
    print = function() end,
    require = function(name)
      return swapped[name] or modules[name]
    end,
  })
  local bound = toggle
  toggle, escape, hs.shutdownCallback = main, cancel, shutdown
  return bound
end

local function unprepared(problem)
  return {
    prepare = function()
      return problem
    end,
  }
end

test("an unsecured history folder, no ffmpeg, or no venv leaves a hotkey that says why", function()
  for _, case in ipairs({
    {
      "could not create /x owner-only",
      { ["dictation.history"] = unprepared("could not create /x owner-only") },
    },
    { "no ffmpeg found; run mise install", { ["dictation.recorder"] = {} } },
    { "backend venv missing", {} },
  }) do
    local problem, swapped = table.unpack(case)
    swapped["dictation.engine"] = {
      new = function()
        return nil, "backend venv missing"
      end,
    }
    local hotkey = reload(swapped)
    alerts = {}
    hotkey()
    assert(alerts[1] == "Dictation: " .. problem, tostring(alerts[1]))
  end
end)

test(
  "an unknown theme, a glass that fails to build, or a bad tint leaves a hotkey that says why",
  function()
    local hotkey = reload({
      ["dictation.defaults"] = import("defaults", {}),
      ["dictation.config"] = { theme = "shiny" },
      ["dictation.history"] = unprepared(),
    })
    alerts = {}
    hotkey()
    assert(alerts[1] == "Dictation: no theme shiny; use flat or glass", tostring(alerts[1]))
    hotkey = reload(setmetatable({
      ["dictation.defaults"] = import("defaults", {}),
      ["dictation.config"] = { theme = "glass" },
      ["dictation.history"] = unprepared(),
    }, {
      __index = function(_, name)
        assert(name ~= "lib.glass", "glass: native build failed")
      end,
    }))
    alerts = {}
    hotkey()
    assert(tostring(alerts[1]):find("glass: native build failed", 1, true), tostring(alerts[1]))
    hotkey = reload({
      ["dictation.defaults"] = import("defaults", {}),
      ["dictation.config"] = { theme = "glass", tint = { light = 0.5 } },
      ["dictation.history"] = unprepared(),
      ["lib.glass"] = glassModule(),
    })
    alerts = {}
    hotkey()
    assert(alerts[1] == "Dictation: tint.dark is nil; use 0 to 1", tostring(alerts[1]))
  end
)

test("the glass theme draws the pill on lib.glass, with its tint or config.lua's", function()
  local glass = glassModule()
  for _, case in ipairs({ { false, glass.tint }, { { light = 0.2, dark = 0.9 } } }) do
    local configured, expected = case[1], case[2] or case[1]
    local drawnOn, drawnTint
    local hotkey = reload({
      ["dictation.defaults"] = import("defaults", {}),
      ["dictation.config"] = { theme = "glass", tint = configured },
      ["dictation.history"] = unprepared(),
      ["lib.glass"] = glass,
      ["dictation.engine"] = {
        new = function()
          return {}
        end,
      },
      ["dictation.overlay"] = {
        new = function(native, tint)
          drawnOn, drawnTint = native, tint
          error("drawn") -- ends the take before it records
        end,
      },
    })
    assert(not pcall(hotkey) and drawnOn == glass, "the pill is not on the glass")
    assert(drawnTint == expected, "not the expected tint")
  end
end)

test("an unknown setting in config.lua alerts", function()
  alerts = {}
  reload({
    ["dictation.defaults"] = import("defaults", {}),
    ["dictation.config"] = { bogus = true },
    ["dictation.history"] = unprepared("stop"),
  })
  assert(alerts[1] == "Dictation: unknown setting bogus in config.lua", tostring(alerts[1]))
end)

test("a hotkey key hs.hotkey doesn't know stops the backend and says why", function()
  local stopped = false
  alerts = {}
  reload({
    ["dictation.defaults"] = import("defaults", {}),
    ["dictation.config"] = { hotkey = { mods = {}, key = "bogus" } },
    ["dictation.history"] = { prepare = function() end },
    ["dictation.engine"] = {
      new = function()
        return {
          stop = function()
            stopped = true
          end,
        }
      end,
    },
  })
  assert(stopped and tostring(alerts[1]):find("Invalid key: bogus", 1, true), tostring(alerts[1]))
end)

test("a backend that becomes ready arms the unload, none with unloadMinutes = false", function()
  local main, merged = handlers, settings
  for _, minutes in ipairs({ 15, false }) do
    local count, defaults = #unloads, import("defaults", {})
    defaults.unloadMinutes = minutes
    reload({
      ["dictation.defaults"] = defaults,
      ["dictation.config"] = {},
      ["dictation.history"] = { prepare = function() end },
    })
    assert(#unloads == count, "armed while the backend loads")
    handlers.onReady()
    assert(#unloads == count + (minutes and 1 or 0), tostring(minutes))
  end
  handlers, settings = main, merged
end)

test("a take that can't move into history is left where the alert says", function()
  alerts, focus = {}, field("Hi")
  toggle()
  toggle()
  os.execute("chmod 500 " .. directory)
  local ok, problem = pcall(timers[#timers]) -- the stop deadline
  os.execute("chmod 700 " .. directory)
  assert(ok, problem)
  assert(tostring(alerts[2]):find("could not keep " .. recorded, 1, true), tostring(alerts[2]))
  assert(fs.attributes(recorded), "the recording was deleted")
end)

-- Last: it leaves the take to Hammerspoon's teardown.
test("shutdown puts the clipboard back and keeps every take", function()
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "x" })
  local count = wavs()
  dictate(field("Hi"))
  escape() -- still transcribing, no longer waited on
  toggle()
  chained = false
  hs.shutdownCallback()
  assert(recording.ended, "ffmpeg left running")
  assert(chained, "the shutdown before it was skipped")
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
  assert(wavs() == count + 2 and not fs.attributes(recorded), "a recording is not kept")
end)

print("RESULT " .. passed .. " passed, 0 failed")

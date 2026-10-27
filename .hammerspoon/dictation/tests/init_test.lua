local root, frameworks, scratch = arg[1], arg[2], arg[3]
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
package.path = root .. "/../?.lua;" .. package.path
local passed, alerts, strokes, timers, changes, takes, serial = 0, {}, {}, {}, 0, 0, 0
local toggle, escape, handlers, done, focus, front, refused, recorded, sent, dead, settings, take
local frame, broken, armed, shown, chained, unstartable
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

local function load(name, env)
  return assert(loadfile(root .. "/" .. name .. ".lua", "t", setmetatable(env, { __index = _G })))()
end

local config = load("defaults", {})
local mine = load("config", {})
mine.words = { "Slack", Raycast = { "ray cast" } }
mine.apps = { ["com.x"] = { words = { "Zed", Neovim = "neo vim" } } }
mine.cleanup, mine.speech = false, { model = "mine" }
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
      local function log(on)
        return function()
          armed = on
          assert(not dead, "ipc port is no longer valid")
          return true
        end
      end
      return { enable = log(true), disable = log(false) }
    end,
  },
  timer = {
    doEvery = function(_, callback)
      frame = callback
      return stub({
        stop = function()
          frame = nil
        end,
      })
    end,
    doAfter = function(_, callback)
      local index = #timers + 1
      timers[index] = callback
      return stub({
        fire = callback,
        stop = function()
          timers[index] = function() end -- a stopped timer never fires
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
      return front
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

local modules = {
  ["dictation.defaults"] = config,
  ["dictation.config"] = mine,
  ["lib.logger"] = load("../lib/logger", {
    hs = hs,
    print = function() end,
    require = function()
      return { show = hs.alert.show }
    end,
  }),
  ["dictation.spacing"] = load("spacing", {}),
  ["dictation.history"] = load("history", { hs = { fs = fs } }),
  ["dictation.overlay"] = {
    new = function()
      shown = true
      return stub({
        canvas = stub({
          delete = function()
            shown = false
          end,
        }),
        update = function()
          assert(not broken, "broken frame")
        end,
      })
    end,
  },
  ["dictation.recorder"] = {
    ffmpeg = "/usr/bin/ffmpeg",
    start = function(_, onError)
      if unstartable then
        return nil, "could not start capture task"
      end
      takes = takes + 1
      recorded = ("%s/take%d.wav"):format(scratch, takes)
      assert(io.open(recorded, "w")):close()
      take = { wav = recorded, fail = onError }
      return take
    end,
    stop = function(capture, callback)
      capture.done = callback
      done = function()
        if capture.done then
          capture.done(capture.wav, 0.5, 1)
        end
        capture.done = nil -- ffmpeg exits once
      end
    end,
    cleanup = function(capture, kept)
      if capture then
        capture.done, capture.ended = nil, true
        if not kept then
          os.remove(capture.wav)
        end
      end
    end,
    finalize = function(capture)
      capture.done, capture.finalized = nil, fs.attributes(capture.wav) ~= nil
      return not capture.stuck
    end,
    analyze = function() end,
  },
  ["dictation.engine"] = {
    new = function(merged, callbacks)
      handlers, settings = callbacks, merged
      return {
        ready = true,
        stop = function() end,
        transcribe = function(_, wav, app)
          if refused then
            return nil, "backend is not ready"
          end
          serial, sent = serial + 1, { wav = wav, app = app }
          return serial
        end,
      }
    end,
  },
}
load("init", {
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

-- `deaf` takes writes but keeps its value (Chromium); `fixed` takes none (a terminal).
local function field(before, deaf, fixed, role)
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
    return not fixed
  end
  function element:setAttributeValue(_, text)
    self.written = text
    if not deaf then
      self.value = self.value .. text
    end
    return self
  end
  return element
end

local function dictate(element)
  alerts, strokes, focus = {}, {}, element
  toggle()
  toggle()
  done()
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
  front = app("com.apple.Notes")
  handlers.onFinal({ id = dictate(element), text = "there." })
  assert(sent.app == "com.apple.Notes", tostring(sent.app))
  assert(element.value == "Hello there." and #strokes == 0 and #alerts == 0, element.value)
  assert(saved("there."), "not the text saved")
  assert(not fs.attributes(sent.wav) and wavs() == 0, "the recording is left")
  assert(not shown and not frame and not armed, "the pill, its frames, or Escape outlived the take")
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
    front = app(bundle)
    handlers.onFinal({ id = dictate(element), text = "ls" })
    assert(element.written == nil and strokes[1] == "cmd+v", bundle)
    assert(clipboard["public.utf8-plain-text"] == want, clipboard["public.utf8-plain-text"])
    timers[#timers]()
  end
  front = nil
end)

test("a second paste before the restore puts back the clipboard from before the first", function()
  handlers.onFinal({ id = dictate(field("a", true)), text = "one" })
  handlers.onFinal({ id = dictate(field("b", true)), text = "two" })
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
end)

test("focus moved while transcribing writes nothing, says so, and saves the text", function()
  local element = field("x")
  local id = dictate(element)
  focus = field("y")
  handlers.onFinal({ id = id, text = "moved" })
  assert(not element.written and not focus.written and #strokes == 0, "written")
  assert(alerts[1] and alerts[1]:find("focus moved", 1, true), tostring(alerts[1]))
  assert(alerts[1]:find("in history", 1, true) and saved("moved"), "not saved, or not told")
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
  end
end)

test("with nothing to type, what was heard is saved in place of the recording", function()
  local rewrote = "the cleanup rewrote what was said, so nothing was typed"
  handlers.onError(rewrote, dictate(field("Hi")), "heard it")
  assert(
    alerts[1] == "Dictation: backend: " .. rewrote .. " (what was heard is in history)",
    tostring(alerts[1])
  )
  assert(saved("heard it") and not fs.attributes(recorded), "not saved, or the recording left")
  assert(wavs() == 0, "a recording kept")
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
      "the backend refusing it",
      function() end,
      true,
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
    local name, reply, refuse = table.unpack(case)
    local count = wavs()
    refused = refuse
    reply(dictate(field("Hi")))
    refused = nil
    assert(wavs() == count + 1 and not fs.attributes(recorded), name .. ": not kept")
    assert(table.concat(alerts, "\n"):find("kept in", 1, true), name .. ": not told")
  end
end)

test("a take recording when the backend dies goes on, and is kept", function()
  local count = wavs()
  focus = field("Hi")
  toggle()
  handlers.onError("exited (code 1)")
  refused = true
  toggle()
  done()
  refused = nil
  assert(wavs() == count + 1 and not fs.attributes(recorded), "the take was dropped")
end)

test("a stop ffmpeg doesn't finish in 2 s (a stalled mic) keeps the take and says so", function()
  local count = wavs()
  local id = dictate(field("Hi"))
  timers[#timers]() -- ffmpeg exited in time: its deadline is stopped
  handlers.onFinal({ id = id, text = "in time" })
  toggle()
  toggle()
  escape()
  timers[#timers]() -- cancelled: its deadline is stopped
  focus, alerts = field("Hi"), {}
  toggle()
  toggle()
  timers[#timers]()
  assert(tostring(alerts[1]):find("did not finish the recording", 1, true), tostring(alerts[1]))
  assert(take.ended, "ffmpeg left running")
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

test("a take too short or too quiet is never sent, and is deleted", function()
  for setting, value in pairs({ minDuration = 2, minLevel = 0.75 }) do
    local count = serial
    config[setting] = value
    dictate(field("Hi"))
    config[setting] = 0
    assert(serial == count and not fs.attributes(recorded), setting)
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
  focus, dead = element, true
  pcall(toggle)
  dead = false
  toggle()
  done()
  dead = true
  pcall(handlers.onFinal, { id = serial, text = "one" })
  dead = false
  handlers.onFinal({ id = dictate(element), text = "two" })
  assert(element.value == "Hi one two", element.value)
end)

test("clipboard mode copies the text, inserts nothing, and says if the copy fails", function()
  local element, set = field("Hi"), hs.pasteboard.setContents
  config.insert = "clipboard"
  handlers.onFinal({ id = dictate(element), text = "copied" })
  assert(not element.written and #strokes == 0, "inserted")
  assert(clipboard["public.utf8-plain-text"] == "copied", clipboard["public.utf8-plain-text"])
  hs.pasteboard.setContents = function()
    return false
  end
  handlers.onFinal({ id = dictate(element), text = "lost" })
  config.insert, hs.pasteboard.setContents = "direct", set
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

test("a recorder that fails ends the take and says why; the next press starts anew", function()
  alerts, focus = {}, field("Hi")
  toggle()
  take.fail("device lost")
  assert(alerts[1] == "Dictation: recorder: device lost", tostring(alerts[1]))
  local count = takes
  toggle()
  assert(takes == count + 1, "the next press did not start a take")
  escape()
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
  frame()
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

test("Mail's compose page is pasted into; a slider gets nothing and says so", function()
  local page = field("Hi", false, false, "AXWebArea")
  handlers.onFinal({ id = dictate(page), text = "you" })
  assert(strokes[1] == "cmd+v" and not page.written, tostring(strokes[1]))
  timers[#timers]()
  local slider = field("50", false, false, "AXSlider")
  handlers.onFinal({ id = dictate(slider), text = "you" })
  assert(not slider.written and #strokes == 0, "wrote into a slider")
  assert(
    alerts[1] == "Dictation: no text field is focused (the text is in history)",
    tostring(alerts[1])
  )
end)

test("past the history cap a saved take prunes the oldest", function()
  config.history.maxMegabytes = 0
  handlers.onFinal({ id = dictate(field("Hi")), text = "newest" })
  config.history.maxMegabytes = 10
  local texts = 0
  for entry in fs.dir(directory) do
    texts = texts + (entry:match("%.txt$") and 1 or 0)
  end
  assert(texts == 1, texts)
end)

-- init.lua loaded again with `swapped` modules; its hotkey is returned, the first load's kept.
local function reload(swapped)
  local main, cancel, shutdown = toggle, escape, hs.shutdownCallback
  load("init", {
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
    { "ffmpeg not found; run mise install", { ["dictation.recorder"] = {} } },
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

test("an unknown setting in config.lua alerts", function()
  alerts = {}
  reload({
    ["dictation.defaults"] = load("defaults", {}),
    ["dictation.config"] = { bogus = true },
    ["dictation.history"] = unprepared("stop"),
  })
  assert(alerts[1] == "Dictation: config.lua: unknown setting bogus", tostring(alerts[1]))
end)

test("a hotkey key hs.hotkey doesn't know stops the backend and says why", function()
  local stopped = false
  alerts = {}
  reload({
    ["dictation.defaults"] = load("defaults", {}),
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

test("a reload that can't move a take into history leaves it where the alert says", function()
  alerts, focus = {}, field("Hi")
  toggle()
  os.execute("chmod 500 " .. directory)
  hs.shutdownCallback()
  os.execute("chmod 700 " .. directory)
  assert(tostring(alerts[1]):find("could not keep " .. recorded, 1, true), tostring(alerts[1]))
  assert(fs.attributes(recorded), "the recording was deleted")
end)

-- Last: it tears everything down.
test("shutdown puts the clipboard back and keeps every take, even if a log line raises", function()
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "x" })
  local count = wavs()
  dictate(field("Hi"))
  escape() -- still transcribing, no longer waited on
  toggle()
  local recording = take
  recording.stuck, alerts, chained = true, {}, false
  dead = true -- unbinding Escape raises: every take is kept first
  pcall(hs.shutdownCallback)
  dead = false
  assert(recording.finalized, "the recording was kept before ffmpeg finished it")
  assert(chained, "the shutdown before it was skipped")
  assert(tostring(alerts[1]):find("may be cut short", 1, true), tostring(alerts[1]))
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
  assert(wavs() == count + 2 and not fs.attributes(recorded), "a recording is not kept")
end)

print("RESULT " .. passed .. " passed, 0 failed")

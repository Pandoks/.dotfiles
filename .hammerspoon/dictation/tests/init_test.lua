local root, frameworks, scratch = arg[1], arg[2], arg[3]
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
local passed, alerts, strokes, timers, changes, takes, serial = 0, {}, {}, {}, 0, 0, 0
local toggle, escape, handlers, done, focus, front, refused, recorded, sent, dead, settings, take
local frame, broken
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
mine.cleanup = { enabled = false }
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
      escape = callback
      local function log()
        assert(not dead, "ipc port is no longer valid")
        return true
      end
      return { enable = log, disable = log }
    end,
  },
  timer = {
    doEvery = function(_, callback)
      frame = callback
      return stub()
    end,
    doAfter = function(_, callback)
      timers[#timers + 1] = callback
      return stub({ fire = callback })
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
      return stub({
        canvas = stub(),
        update = function()
          assert(not broken, "broken frame")
        end,
      })
    end,
  },
  ["dictation.recorder"] = {
    start = function()
      takes = takes + 1
      recorded = ("%s/take%d.wav"):format(scratch, takes)
      assert(io.open(recorded, "w")):close()
      take = { wav = recorded }
      return take
    end,
    stop = function(capture, callback)
      capture.done = callback
      done = function()
        if capture.done then
          capture.done(capture.wav, 0.5, 1)
        end
      end
    end,
    cleanup = function(capture)
      if capture then
        capture.done = nil
        os.remove(capture.wav)
      end
    end,
    finalize = function(capture)
      capture.done, capture.finalized = nil, fs.attributes(capture.wav) ~= nil
      return not capture.stuck
    end,
    analyze = function() end,
  },
  ["dictation.engine"] = {
    new = function(config, callbacks)
      handlers, settings = callbacks, config
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
      AXSelectedTextRange = { location = utf8.len(self.value), length = 0 },
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
  handlers.onFinal({ id = dictate(element), text = "there.", heard = "there" })
  assert(sent.app == "com.apple.Notes", tostring(sent.app))
  assert(element.value == "Hello there." and #strokes == 0 and #alerts == 0, element.value)
  assert(saved("there.") and not saved("there"), "not the text saved")
  assert(not fs.attributes(sent.wav) and wavs() == 0, "the recording is left")
end)

test("a write the field ignores (Chromium) is pasted, then the clipboard put back", function()
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "you" })
  assert(strokes[1] == "cmd+v" and clipboard["public.utf8-plain-text"] == " you", strokes[1])
  assert(clipboard[transient] == "", "clipboard managers record the dictation")
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
end)

test("a terminal's or a Gecko app's field is pasted into, never written", function()
  for _, case in ipairs({
    { field("$ ", false, true), "com.mitchellh.ghostty" },
    { field("Hi"), "org.mozilla.firefox" }, -- applies writes late
  }) do
    local element, bundle = table.unpack(case)
    front = app(bundle)
    handlers.onFinal({ id = dictate(element), text = "ls" })
    assert(element.written == nil and strokes[1] == "cmd+v", bundle)
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
  assert(saved("moved"), "not saved")
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
  handlers.onFinal({ id = dictate(field("Hi")), text = "", heard = "mumble" })
  assert(saved("mumble") and not fs.attributes(recorded), "not saved, or the recording left")
  local rewrote = "the cleanup rewrote what was said, so nothing was typed"
  handlers.onError(rewrote, dictate(field("Hi")), "heard it")
  assert(
    alerts[1] == "Dictation: backend: " .. rewrote .. " (what was heard is in history)",
    tostring(alerts[1])
  )
  assert(saved("heard it") and not fs.attributes(recorded), "not saved, or the recording left")
  assert(wavs() == 0, "a recording kept")
end)

test("a take with no transcript keeps its recording in history", function()
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
        handlers.onError("backend exited (code 1)")
      end,
    },
    {
      "the backend refusing it",
      function() end,
      true,
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
  handlers.onError("backend exited (code 1)")
  refused = true
  toggle()
  done()
  refused = nil
  assert(wavs() == count + 1 and not fs.attributes(recorded), "the take was dropped")
end)

test("config.lua's settings replace the defaults, its words sent as one map", function()
  local json = assert(package.loadlib(frameworks .. "/hs/libjson.dylib", "luaopen_hs_libjson"))()
  local sent = json.decode(assert(json.encode(settings)))
  assert(sent.speech.model and sent.cleanup.model == nil, "a setting merged, not replaced")
  assert(next(sent.words.Slack) == nil, json.encode(sent.words))
  assert(sent.words.Raycast[1] == "ray cast", json.encode(sent.words))
  local app = sent.apps["com.x"].words
  assert(next(app.Zed) == nil and app.Neovim[1] == "neo vim", json.encode(app))
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

test("a take where nothing was heard deletes its recording", function()
  local count = wavs()
  handlers.onFinal({ id = dictate(field("Hi")), text = "" })
  assert(alerts[1] == "Dictation: no speech recognized", tostring(alerts[1]))
  assert(wavs() == count and not fs.attributes(recorded) and not saved(""), "kept a silent take")
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

test("clipboard mode copies the text and inserts nothing", function()
  local element = field("Hi")
  config.insert = "clipboard"
  handlers.onFinal({ id = dictate(element), text = "copied" })
  config.insert = "direct"
  assert(not element.written and #strokes == 0, "inserted")
  assert(clipboard["public.utf8-plain-text"] == "copied", clipboard["public.utf8-plain-text"])
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
end)

test("Escape while recording deletes the take", function()
  focus = field("Hi")
  toggle()
  escape()
  assert(not fs.attributes(recorded), "the recording is left")
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
  assert(alerts[1] == "Dictation: no text field is focused", tostring(alerts[1]))
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

test("a history folder it can't secure leaves only a hotkey that says why", function()
  local started = false
  local hotkey = reload({
    ["dictation.history"] = unprepared("could not create /x owner-only"),
    ["dictation.engine"] = {
      new = function()
        started = true
      end,
    },
  })
  alerts = {}
  hotkey()
  assert(not started and alerts[1] == "Dictation: could not create /x owner-only", alerts[1])
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

test("a hotkey macOS can't bind stops the backend and says why", function()
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

-- Last: it tears everything down.
test("shutdown puts the clipboard back and keeps every take, even if a log line raises", function()
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "x" })
  local count = wavs()
  dictate(field("Hi"))
  escape() -- still transcribing, no longer waited on
  toggle()
  local recording = take
  recording.stuck, alerts = true, {}
  dead = true -- unbinding Escape raises: every take is kept first
  pcall(hs.shutdownCallback)
  dead = false
  assert(recording.finalized, "the recording was kept before ffmpeg finished it")
  assert(tostring(alerts[1]):find("may be cut short", 1, true), tostring(alerts[1]))
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
  assert(wavs() == count + 2 and not fs.attributes(recorded), "a recording is not kept")
end)

print(passed .. " init tests passed")

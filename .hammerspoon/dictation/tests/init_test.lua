local root, frameworks, scratch = arg[1], arg[2], arg[3]
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
local passed, alerts, strokes, timers, changes, takes, serial = 0, {}, {}, {}, 0, 0, 0
local toggle, escape, handlers, done, focus, front, refused, recorded, sent
local clipboard = { ["public.utf8-plain-text"] = "mine" }
local transient = "org.nspasteboard.TransientType"
local directory = scratch .. "/init-history"

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

-- Every method a no-op that succeeds.
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

local config = load("config", {})
config.history.directory, config.minDuration, config.minLevel = directory, 0, 0
local hs = {
  alert = {
    show = function(message)
      alerts[#alerts + 1] = message
    end,
  },
  hotkey = {
    bind = function(_, _, callback)
      toggle = callback
      return stub()
    end,
    new = function(_, _, callback)
      escape = callback
      return stub()
    end,
  },
  timer = {
    doEvery = function()
      return stub()
    end,
    doAfter = function(_, callback)
      timers[#timers + 1] = callback
      return stub({ fire = callback })
    end,
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
  -- Every write counts, as NSPasteboard's changeCount does.
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

-- init.lua with the real spacing and history; the hotkey, recorder, and backend are stubs to drive.
local modules = {
  ["dictation.config"] = config,
  ["dictation.spacing"] = load("spacing", {}),
  ["dictation.history"] = load("history", { hs = { fs = fs } }),
  ["dictation.overlay"] = {
    new = function()
      return stub({ canvas = stub() })
    end,
  },
  ["dictation.recorder"] = {
    start = function()
      takes = takes + 1
      recorded = ("%s/take%d.wav"):format(scratch, takes)
      assert(io.open(recorded, "w")):close()
      return { wav = recorded }
    end,
    -- As the real one: `done` gets the finished wav; cleanup deletes it and cancels `done`.
    stop = function(capture, callback)
      capture.done = callback
      done = function()
        if capture.done then
          capture.done(capture.wav, 1, 1)
        end
      end
    end,
    cleanup = function(capture)
      if capture then
        capture.done = nil
        os.remove(capture.wav)
      end
    end,
    poll = function() end,
  },
  ["dictation.engine"] = {
    new = function(_, callbacks)
      handlers = callbacks
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

-- A text area holding `before`, the cursor at its end; `deaf` takes writes but keeps its value
-- (Chromium), `fixed` takes none (a terminal).
local function field(before, deaf, fixed)
  local element = { value = before }
  function element:attributeValue(name)
    return ({
      AXRole = "AXTextArea",
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

-- A take into `element`, recorded and stopped; its request id.
local function dictate(element)
  alerts, strokes, focus = {}, {}, element
  toggle()
  toggle()
  done()
  return serial
end

-- Whether a transcript in history holds exactly `text`.
local function saved(text)
  for entry in fs.dir(directory) do
    local file = entry:match("%.txt$") and assert(io.open(directory .. "/" .. entry))
    if file and file:read("a") == text .. "\n" then
      return true
    end
  end
  return false
end

-- Recordings kept in history.
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

test("a result after Escape is saved, not inserted", function()
  local element = field("Hi")
  local id = dictate(element)
  escape()
  handlers.onFinal({ id = id, text = "late" })
  assert(not element.written and #strokes == 0 and saved("late"), "inserted, or not saved")
end)

test("with nothing to type, what was heard is saved in place of the recording", function()
  handlers.onFinal({ id = dictate(field("Hi")), text = "", heard = "mumble" })
  assert(saved("mumble") and not fs.attributes(recorded), "not saved, or the recording left")
  handlers.onError("cleanup failed", dictate(field("Hi")), "heard it")
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

test("a take where nothing was heard deletes its recording", function()
  local count = wavs()
  handlers.onFinal({ id = dictate(field("Hi")), text = "" })
  assert(wavs() == count and not fs.attributes(recorded), "kept a silent take")
end)

test("Escape while recording deletes the take", function()
  focus = field("Hi")
  toggle()
  escape()
  assert(not fs.attributes(recorded), "the recording is left")
end)

test("a copy made before the clipboard restore is kept", function()
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "x" })
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "copied" })
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "copied", clipboard["public.utf8-plain-text"])
  hs.pasteboard.writeAllData({ ["public.utf8-plain-text"] = "mine" })
end)

-- Last: it tears everything down.
test("shutdown puts the clipboard back and keeps the take still transcribing", function()
  handlers.onFinal({ id = dictate(field("Hi", true)), text = "x" })
  local count = wavs()
  dictate(field("Hi"))
  hs.shutdownCallback()
  assert(clipboard["public.utf8-plain-text"] == "mine", clipboard["public.utf8-plain-text"])
  assert(wavs() == count + 1 and not fs.attributes(recorded), "the recording is not kept")
end)

print(passed .. " init tests passed")

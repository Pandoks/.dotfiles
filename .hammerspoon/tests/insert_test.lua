local root = assert(arg[1], "pass the dictation directory")
local passed, serial, alerts, strokes, clipboard, timers = 0, 0, {}, {}, {}, {}
-- Every clipboard write counts, as NSPasteboard's changeCount does; `pasteWrites` makes ⌘V write.
local changes, pasteWrites, starts, clearFails = 0, false, 0, false
local toggle, handlers, done, escape, focus, copied, saved, refused
local pruned, kept, down = 0, {}, false
local sent, front, saveFails -- the last request, the frontmost app, history.save's failure
local windowProblem -- what reading the front app's window title fails with
---@type string|false|integer its window: a title, false for none, or something no element
local frontWindow = "Inbox"
local trusted = true -- Accessibility granted
local config = {
  insert = "direct",
  trigger = "hotkey",
  hotkey = { mods = { "alt" }, key = "space" },
  cleanup = { enabled = false },
  minDuration = 0,
  minLevel = 0,
  history = { directory = "~/Library/Application Support/dictation" },
}

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

-- Every method is a no-op.
local function stub()
  return setmetatable({}, {
    __index = function()
      return function() end
    end,
  })
end

-- init.lua with the real insertion code; hotkey, recorder, and backend are stubs the tests drive.
local env = setmetatable({
  require = function(name)
    return ({
      ["dictation.config"] = config,
      ["dictation.engine"] = {
        new = function(_, callbacks)
          handlers = callbacks
          return {
            ready = true,
            stop = function() end,
            transcribe = function(_, request)
              sent = request
              if down then
                return nil, "backend is not ready"
              end
              serial = serial + 1
              return serial
            end,
          }
        end,
      },
      ["dictation.overlay"] = { new = stub },
      ["dictation.history"] = {
        save = function(text)
          saved[#saved + 1] = text
          return saveFails
        end,
        prune = function()
          pruned = pruned + 1
        end,
        keep = function(wav)
          kept[#kept + 1] = wav
        end,
      },
      ["dictation.recorder"] = {
        start = function()
          starts = starts + 1
          return { wav = ("take%d.wav"):format(starts) }
        end,
        stop = function(_, callback)
          done = callback
        end,
        cleanup = function() end,
        leftovers = function()
          return { { wav = "crashed.wav" } } -- a take a crash left behind
        end,
      },
    })[name]
  end,
  print = function() end,
  hs = {
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
        local key = stub()
        -- The hotkey, or nil when macOS refuses the binding.
        function key:enable()
          return not refused and self or nil
        end
        return key
      end,
    },
    timer = {
      doEvery = stub,
      doAfter = function(_, callback)
        timers[#timers + 1] = callback
        local timer = stub()
        function timer.fire()
          callback()
        end
        return timer
      end,
    },
    microphoneState = function()
      return true
    end,
    accessibilityState = function()
      return trusted
    end,
    application = {
      frontmostApplication = function()
        return front
      end,
    },
    osascript = {
      applescript = function()
        return false, nil, { NSAppleScriptErrorMessage = "not authorized" }
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
      applicationElement = function()
        local window = type(frontWindow) ~= "string" and frontWindow
          or setmetatable({}, {
            __index = {
              attributeValue = function()
                return frontWindow
              end,
            },
          })
        return {
          attributeValue = function()
            if windowProblem or frontWindow == false then
              return nil, windowProblem
            end
            return window
          end,
        }
      end,
    },
    pasteboard = {
      readAllData = function()
        return clipboard
      end,
      clearContents = function()
        changes = changes + 1
        if not clearFails then
          clipboard = nil
        end
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
      setContents = function(text)
        copied = text
        return true
      end,
    },
    eventtap = {
      keyStroke = function(mods, key)
        strokes[#strokes + 1] = mods[1] .. "+" .. key
        changes = changes + (pasteWrites and 1 or 0)
      end,
    },
  },
}, { __index = _G })
assert(loadfile(root .. "/init.lua", "t", env))()

-- AX ranges count UTF-16 units.
local function units(text)
  local count = 0
  for _, codepoint in utf8.codes(text) do
    count = count + (codepoint > 0xFFFF and 2 or 1)
  end
  return count
end

-- A text field; `deaf` takes writes but keeps its value (Chromium), `fixed` takes none (terminal).
local function field(before, selected, after, deaf, role, fixed)
  local element = {}
  function element:attributeValue(name)
    return ({
      AXValue = before .. selected .. after,
      AXSelectedTextRange = { location = units(before), length = units(selected) },
      AXSelectedText = selected,
      AXRole = role or "AXTextArea",
    })[name]
  end
  function element:isAttributeSettable()
    return not fixed
  end
  function element:setAttributeValue(_, text)
    element.written = text
    if not deaf then
      before, selected = before .. text, ""
    end
    return self
  end
  return element
end

-- One take: start, stop with `element` focused, then the backend's result after `moved` focus.
local function dictate(element, text, moved)
  alerts, strokes, focus, copied, saved = {}, {}, element, nil, {}
  toggle()
  toggle()
  done("take.wav", 1, 1)
  focus = moved or element
  handlers.onFinal({ id = serial, text = text })
end

-- First: init.lua kept the crash's leftovers as it loaded.
test("a recording a crash left is kept and announced at load", function()
  assert(kept[1] == "crashed.wav" and #kept == 1, tostring(kept[1]))
  assert(alerts[1] and alerts[1]:find("1 recording kept in .*left by a crash"), alerts[1])
end)

test("spacing joins the text to its neighbors", function()
  for _, case in ipairs({
    { "", "", "", "Hi.", "Hi." },
    { "Hello", "", "", "there.", " there." },
    { "Hello ", "", "", "there.", "there." },
    { "", "", "world", "hi", "hi " },
    { "Hello", "", "world", "there", " there " },
    { "Hi\u{a0}", "", "", "there.", "there." }, -- browsers' typed trailing space
    { "Hello\n", "", "", "there.", "there." },
    { "(", "", ")", "aside", "aside" },
    { "[", "", "]", "link", "link" },
    { "{", "", "}", "x", "x" },
    { "<", "", ">", "div", "div" },
    { "“", "", "”", "hi", "hi" }, -- smart quotes (Notes, Pages, Mail)
    { "‘", "", "’", "hi", "hi" },
    { "", "", "(aside)", "Note", "Note " },
    { "~/", "", "", "notes", "notes" },
    { "end", "", ".", "word", " word" },
    { 'He said "', "", '"', "hi", "hi" }, -- opening straight quote
    { 'She said "I want ', "", '" and left.', "it", "it" }, -- a closing quote after a space
    { "He said '", "", "'", "hi", "hi" },
    { '("', "", "", "hi", "hi" }, -- a quote opening after an opener
    { 'He said "hi"', "", "", "and left.", " and left." }, -- closing straight quote
    { "", "", '"quoted"', "Say", "Say " },
    { "", "Sam", "'s car", "John", "John" }, -- an apostrophe inside a word
    { "Ask ", "Sam", "'s mom.", "John", "John" }, -- a selected name before 's mid-sentence
    { "Sam", "", "'s", "uel", " uel" },
    { "a ", "foo ", "'quoted'", "bar", "bar " },
    { "run `", "", "`", "ls", "ls" }, -- an inline code span
    { "", "", "`ls`", "Run", "Run " },
    { "😀", "", "", "hi", " hi" },
    { "😀 ", "", "world", "hi", "hi " }, -- an emoji is two units
    { "a ", "foo", " b", "bar", "bar" },
    { "a😀", "foo", "b", "bar", " bar " },
    { "", "", "éclair", "hello", "hello " }, -- a word in any script
    { "", "", "日本", "hello", "hello " },
    { "", "", "—then", "hello", "hello" }, -- a dash is a mark, not a word
    { "", "", "？", "hello", "hello" }, -- fullwidth punctuation
    { "你好", "", "世界", "漂亮", "漂亮" }, -- scripts without spaces between words
    { "你好。", "", "", "漂亮", "漂亮" },
    { "你好", "", "", "hello", " hello" },
    { "/usr/", "local", "/bin", "share", "share" }, -- a path segment
    { "foo.", "local", ".bar", "remote", "remote" }, -- a dotted name's part
    { "foo.", "", "bar", "remote", "remote" },
    { "/usr/", "", "bin", "local", "local" },
    { "/usr", "", "/bin", "local", "local" },
    { "foo-", "bar", "", "remote", "remote" }, -- a hyphenated name's part
    { "foo_", "", "bar", "remote", "remote" },
    { "user@", "example", ".com", "work", "work" }, -- an email address's part
    { "user", "", "@example.com", "new", "new" },
    { "user+", "tag", "@example.com", "new", "new" },
    { "KEY=", "old", "", "new", "new" }, -- an assignment's value
    { "C:\\", "old", "\\file", "new", "new" }, -- a Windows path's part
    { "image:", "latest", "", "stable", "stable" }, -- an image tag
    { "fo", "ob", "ar", "baz", "baz" }, -- part of a word
    { "Note:", "", "", "hi", " hi" },
  }) do
    local before, selected, after, text, want = table.unpack(case)
    local element = field(before, selected, after)
    dictate(element, text)
    local got = ("%s[%s]%s + %s wrote '%s'"):format(before, selected, after, text, element.written)
    assert(element.written == want and #alerts == 0, got .. ", expected '" .. want .. "'")
  end
end)

test("a write the field ignores is pasted with ⌘V and the clipboard restored", function()
  clipboard = { ["public.utf8-plain-text"] = "mine" }
  local element = field("Hello", "", "", true)
  dictate(element, "there.")
  assert(element.written == " there." and strokes[1] == "cmd+v" and #alerts == 0)
  assert(clipboard["public.utf8-plain-text"] == " there.", "pasted the wrong text")
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", "did not restore the clipboard")
end)

test("dictating the selected text again writes it once", function()
  local element = field("a ", "hello", " b")
  dictate(element, "hello")
  assert(element.written == "hello" and #strokes == 0 and #alerts == 0, "pasted it again")
end)

test("focus moved while transcribing writes nothing and says so", function()
  local element = field("Hello", "", "")
  dictate(element, "there.", field("Other", "", ""))
  assert(element.written == nil and alerts[1] == "Dictation: focus moved while transcribing")
end)

test("a slider is not a text field: it says so and copies nothing", function()
  -- Chromium sliders take the write and drop it, like their fields do.
  local slider = field("", "", "1 minute of 3", true, "AXSlider")
  dictate(slider, "Note to self.")
  assert(slider.written == nil and #strokes == 0, "wrote into the slider")
  assert(alerts[1] == "Dictation: no text field is focused", tostring(alerts[1]))
  assert(copied == nil, "copied it")
end)

test("clipboard mode copies and inserts nothing", function()
  local element = field("Hello", "", "")
  config.insert = "clipboard"
  dictate(element, "there.")
  config.insert = "direct"
  assert(element.written == nil and #strokes == 0 and #alerts == 0, "inserted")
  assert(copied == "there.", "no copy")
end)

test("a combo box (search, autocomplete) is a text field", function()
  local search = field("", "", "", false, "AXComboBox")
  dictate(search, "tacos")
  assert(search.written == "tacos" and #alerts == 0)
end)

test("a single-line text field takes the text", function()
  local input = field("Hello", "", "", false, "AXTextField")
  dictate(input, "there.")
  assert(input.written == " there." and #alerts == 0)
end)

test("a terminal (no settable selection) is pasted with ⌘V", function()
  -- Ghostty and Terminal: an AXTextArea whose AXSelectedText is read-only.
  local terminal = field("$ ", "", "", false, "AXTextArea", true)
  dictate(terminal, "ls")
  assert(terminal.written == nil and strokes[1] == "cmd+v" and #alerts == 0, "not pasted")
  assert(clipboard["public.utf8-plain-text"] == "ls", "pasted the wrong text")
end)

-- A focused web page; an editable one (Mail's compose body) has a settable value, never selection.
local function page(editable)
  local element = {}
  function element:attributeValue(name)
    return ({ AXRole = "AXWebArea", AXValue = "" })[name]
  end
  function element:isAttributeSettable(name)
    return editable and name == "AXValue"
  end
  function element:setAttributeValue(_, text)
    element.written = text
    return self
  end
  return element
end

test("Mail's compose body (an editable page) is pasted into with ⌘V", function()
  clipboard = { ["public.utf8-plain-text"] = "mine" }
  local body = page(true)
  dictate(body, "Hi Sam, see you Friday.")
  assert(body.written == nil and #strokes == 1 and strokes[1] == "cmd+v" and #alerts == 0)
  assert(clipboard["public.utf8-plain-text"] == "Hi Sam, see you Friday.", "pasted the wrong text")
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", "did not restore the clipboard")
end)

test("a plain web page is not a text field: it says so and copies nothing", function()
  local web = page(false)
  dictate(web, "Note to self.")
  assert(web.written == nil and #strokes == 0, "pasted into a plain page")
  assert(alerts[1] == "Dictation: no text field is focused" and copied == nil, tostring(alerts[1]))
end)

-- A field whose isAttributeSettable fails with hs.axuielement's `problem` message.
local function unsettable(problem)
  local element = field("$ ", "", "")
  function element:isAttributeSettable()
    return nil, problem
  end
  return element
end

test("an accessibility error is reported, not pasted over", function()
  local element = unsettable("Messaging failed") -- kAXErrorCannotComplete, e.g. a hung app
  dictate(element, "ls")
  assert(element.written == nil and #strokes == 0, "wrote or pasted")
  local message = "Dictation: could not check the focused field's AXSelectedText: Messaging failed"
  assert(alerts[1] == message, tostring(alerts[1]))
end)

test("a field that takes no write is pasted spaced against its text", function()
  -- Messages (no settable selection) and Mail's compose body (an editable page).
  for _, element in ipairs({
    field("Hello.", "", "", false, nil, true),
    field("Hello.", "", "", false, "AXWebArea"),
  }) do
    clipboard, strokes = {}, {}
    dictate(element, "How are you?")
    local pasted = clipboard["public.utf8-plain-text"]
    assert(strokes[1] == "cmd+v" and pasted == " How are you?", tostring(pasted))
  end
end)

test("a paste path's failed read is reported, not pasted unspaced", function()
  local element = field("Hello.", "", "", false, nil, true)
  function element:attributeValue(name)
    if name == "AXValue" then
      return nil, "Messaging failed"
    end
    return name == "AXRole" and "AXTextArea" or nil
  end
  alerts, strokes = {}, {}
  dictate(element, "How are you?")
  assert(#strokes == 0, "pasted")
  assert(
    alerts[1] == "Dictation: could not read the focused field's AXValue: Messaging failed",
    tostring(alerts[1])
  )
end)

test("a field without a settable selection attribute is pasted with ⌘V", function()
  local element = unsettable("Attribute is not supported by target")
  dictate(element, "ls")
  assert(element.written == nil and strokes[1] == "cmd+v" and #alerts == 0, "not pasted")
end)

test("an Escape binding macOS refuses aborts the take", function()
  alerts, refused = {}, true
  local before = starts
  toggle()
  refused = false
  assert(starts == before, "recorded with no way to cancel")
  assert(alerts[1] == "Dictation: could not bind Escape to cancel", tostring(alerts[1]))
end)

test("a selection sent as context needs Accessibility first, in clipboard mode too", function()
  config.insert, config.includeSelection, config.cleanup = "clipboard", true, { enabled = true }
  alerts, trusted = {}, false
  local before = starts
  toggle()
  config.insert, config.includeSelection, config.cleanup = "direct", nil, { enabled = false }
  trusted = true
  local message = "Dictation: allow Accessibility access in System Settings"
  assert(starts == before, "recorded a take whose context it could not read")
  assert(alerts[1] == message, tostring(alerts[1]))
end)

test("a take that fails after transcription keeps what was heard", function()
  local element = field("", "", "")
  alerts, strokes, focus, saved, pruned = {}, {}, element, {}, 0
  toggle()
  toggle()
  done("take.wav", 1, 1)
  handlers.onError("KeyError: 'point'", serial, "Keep what I said.")
  assert(saved[1] == "Keep what I said." and element.written == nil, tostring(saved[1]))
  assert(pruned == 1, "saved past the size cap")
  assert(alerts[1] and alerts[1]:find("in history", 1, true), tostring(alerts[1]))
end)

test("a take with nothing to type keeps what was heard", function()
  local element = field("", "", "")
  alerts, focus, saved = {}, element, {}
  toggle()
  toggle()
  done("take.wav", 1, 1)
  handlers.onFinal({ id = serial, text = "", heard = "mumbled words" })
  assert(saved[1] == "mumbled words" and element.written == nil, tostring(saved[1]))
  assert(alerts[1] and alerts[1]:find("in history", 1, true), tostring(alerts[1]))
end)

test("a take cancelled while transcribing is saved, not inserted", function()
  local element = field("", "", "")
  alerts, strokes, focus, saved = {}, {}, element, {}
  toggle()
  toggle()
  done("take.wav", 1, 1)
  escape()
  handlers.onFinal({ id = serial, text = "Keep this." })
  assert(saved[1] == "Keep this." and element.written == nil and #alerts == 0)
end)

test("an app that writes the clipboard while pasting keeps its write", function()
  clipboard, pasteWrites = { ["public.utf8-plain-text"] = "mine" }, true
  dictate(field("Hello", "", "", true), "there.")
  pasteWrites = false
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == " there.", "restored over the app's write")
end)

test("an empty clipboard is empty again after a paste", function()
  clipboard = nil -- readAllData has no first item to return
  dictate(field("Hello", "", "", true), "there.")
  timers[#timers]()
  assert(clipboard == nil, "left the dictation on the clipboard")
end)

test("a clipboard that cannot be emptied again is reported", function()
  clipboard, clearFails = nil, true
  dictate(field("Hello", "", "", true), "there.")
  timers[#timers]()
  clearFails = false
  assert(alerts[#alerts] == "Dictation: could not clear the clipboard", tostring(alerts[#alerts]))
end)

test("a second paste before the restore restores the clipboard from before the first", function()
  clipboard = { ["public.utf8-plain-text"] = "mine" }
  dictate(field("Hello", "", "", true), "there.")
  dictate(field("Hello", "", "", true), "again.")
  timers[#timers]()
  assert(clipboard["public.utf8-plain-text"] == "mine", "restored the first dictation")
end)

test("a backend that dies keeps the recordings it had not transcribed", function()
  alerts, focus, kept = {}, field("", "", ""), {}
  toggle()
  toggle()
  done("take.wav", 1, 1)
  local wav = ("take%d.wav"):format(starts)
  handlers.onError("backend exited (code 9)")
  assert(kept[1] == wav and #kept == 1, tostring(kept[1]))
  assert(alerts[1] and alerts[1]:find("1 recording kept in", 1, true), tostring(alerts[1]))
end)

test("a take the backend dies under is kept once stopped", function()
  alerts, focus, kept, down = {}, field("", "", ""), {}, true
  toggle()
  toggle()
  handlers.onError("backend exited (code 9)") -- while the wav is finalizing
  done("take.wav", 1, 1)
  down = false
  assert(kept[1] == ("take%d.wav"):format(starts) and #kept == 1, tostring(kept[1]))
  assert(alerts[2] and alerts[2]:find("recording is kept in", 1, true), tostring(alerts[2]))
end)

test("context that cannot be read stops the take, its recording kept", function()
  config.includeSelection, config.cleanup = true, { enabled = true }
  front = {
    bundleID = function()
      return "com.google.Chrome"
    end,
  }
  alerts, focus, kept, sent = {}, field("", "picked", ""), {}, nil
  toggle()
  toggle()
  done("take.wav", 1, 1)
  config.includeSelection, config.cleanup, front = nil, { enabled = false }, nil
  assert(sent == nil, "transcribed without the context")
  assert(#kept == 1, "lost the recording")
  assert(alerts[1] and alerts[1]:find("could not read the URL", 1, true), tostring(alerts[1]))
  assert(alerts[1]:find("recording is kept in", 1, true), alerts[1])
end)

test("a window title that cannot be read stops the take too", function()
  config.cleanup = { enabled = true }
  front = {
    bundleID = function()
      return "com.apple.mail"
    end,
  }
  alerts, focus, kept, sent, windowProblem = {}, field("", "", ""), {}, nil, "Cannot complete"
  toggle()
  toggle()
  done("take.wav", 1, 1)
  config.cleanup, front, windowProblem = { enabled = false }, nil, nil
  assert(sent == nil and #kept == 1, "transcribed without the title")
  local message = "could not read the window title: Cannot complete"
  assert(alerts[1] and alerts[1]:find(message, 1, true), tostring(alerts[1]))
end)

test("a prompted take needs Accessibility first, in clipboard mode too", function()
  config.insert, config.cleanup = "clipboard", { enabled = true }
  alerts, trusted = {}, false
  local before = starts
  toggle()
  config.insert, config.cleanup, trusted = "direct", { enabled = false }, true
  assert(starts == before, "recorded a take whose window title it could not read")
  assert(
    alerts[1] == "Dictation: allow Accessibility access in System Settings",
    tostring(alerts[1])
  )
end)

test("a browser with no window has no URL to read, and the take goes on", function()
  config.cleanup = { enabled = true }
  front = {
    bundleID = function()
      return "com.google.Chrome"
    end,
  }
  alerts, focus, kept, sent, frontWindow = {}, field("", "", ""), {}, nil, false
  toggle()
  toggle()
  done("take.wav", 1, 1)
  config.cleanup, front, frontWindow = { enabled = false }, nil, "Inbox"
  handlers.onFinal({ id = serial, text = "" })
  assert(sent and sent.url == nil and sent.title == nil and #kept == 0, tostring(alerts[1]))
end)

test("a focused window that is no element is reported, not raised", function()
  config.cleanup = { enabled = true }
  front = {
    bundleID = function()
      return "com.apple.mail"
    end,
  }
  alerts, focus, kept, sent, frontWindow = {}, field("", "", ""), {}, nil, 42
  toggle()
  toggle()
  done("take.wav", 1, 1)
  config.cleanup, front, frontWindow = { enabled = false }, nil, "Inbox"
  assert(sent == nil and #kept == 1, "lost the take or sent it without its title")
  local message = "could not read the window title: the focused window is no accessibility element"
  assert(alerts[1] and alerts[1]:find(message, 1, true), tostring(alerts[1]))
end)

test("with no app in front, the selection is still read", function()
  config.includeSelection, config.cleanup = true, { enabled = true }
  alerts, focus, kept, sent = {}, field("", "picked", ""), {}, nil
  toggle()
  toggle()
  done("take.wav", 1, 1)
  config.includeSelection, config.cleanup = nil, { enabled = false }
  handlers.onFinal({ id = serial, text = "" })
  assert(sent and sent.selected == "picked" and sent.app == nil, "dropped the selection")
end)

test("every context problem is reported together", function()
  config.includeSelection, config.cleanup = true, { enabled = true }
  front = {
    bundleID = function()
      return "com.google.Chrome"
    end,
  }
  local unreadable = field("", "", "")
  function unreadable:attributeValue()
    return nil, "Cannot complete"
  end
  alerts, focus, kept, sent = {}, unreadable, {}, nil
  toggle()
  toggle()
  done("take.wav", 1, 1)
  config.includeSelection, config.cleanup, front = nil, { enabled = false }, nil
  local message = tostring(alerts[1])
  assert(message:find("could not read the URL", 1, true), message)
  assert(message:find("could not read the selection: Cannot complete", 1, true), message)
end)

test("a take whose speech recognition fails keeps its recording", function()
  alerts, focus, kept = {}, field("", "", ""), {}
  toggle()
  toggle()
  done("take.wav", 1, 1)
  local wav = ("take%d.wav"):format(starts)
  handlers.onError("expected 16000 Hz mono", serial)
  assert(kept[1] == wav and #kept == 1, tostring(kept[1]))
  assert(alerts[1] and alerts[1]:find("recording is kept in", 1, true), tostring(alerts[1]))
end)

test("a cancelled take whose transcript cannot be saved says so and keeps its recording", function()
  alerts, focus, kept, saveFails = {}, field("", "", ""), {}, "could not write the take"
  toggle()
  toggle()
  done("take.wav", 1, 1)
  escape()
  handlers.onError("cleanup failed", serial, "Keep what I said.")
  saveFails = nil
  assert(alerts[1] == "Dictation: could not write the take", tostring(alerts[1]))
  assert(#kept == 1, "lost the recording")
end)

test("a result neither saved nor delivered keeps its recording; one delivered does not", function()
  kept, saveFails = {}, "could not write the take"
  dictate(field("", "", ""), "Keep this.", field("", "", "")) -- focus moved: nothing is inserted
  assert(#kept == 1, "lost the recording")
  assert(alerts[1] == "Dictation: could not write the take", tostring(alerts[1]))
  local element = field("", "", "")
  dictate(element, "Delivered.")
  assert(element.written == "Delivered." and #kept == 1, "kept a delivered take's recording")
  dictate(field("", "", "", false, "AXTextArea", true), "Pasted.") -- ⌘V, which nothing confirms
  timers[#timers]() -- its clipboard restore
  saveFails = nil
  assert(strokes[1] == "cmd+v" and #kept == 2, "lost a pasted take's recording")
end)

test("a cancelled take that fails says where its recording went", function()
  alerts, focus, kept = {}, field("", "", ""), {}
  toggle()
  toggle()
  done("take.wav", 1, 1)
  escape()
  handlers.onError("expected 16000 Hz mono", serial)
  assert(#kept == 1, "lost the recording")
  assert(alerts[1] and alerts[1]:find("recording is kept in", 1, true), tostring(alerts[1]))
end)

-- Last: it tears everything down.
test(
  "a reload restores the clipboard and keeps the take transcribing, not cancelled ones",
  function()
    clipboard = { ["public.utf8-plain-text"] = "theirs" }
    dictate(field("Hello", "", "", true), "there.")
    kept = {}
    toggle()
    toggle()
    done("take.wav", 1, 1)
    escape() -- cancelled while transcribing
    toggle()
    toggle()
    done("take.wav", 1, 1) -- sent, no result yet
    local wav = ("take%d.wav"):format(starts)
    env.hs.shutdownCallback()
    assert(clipboard["public.utf8-plain-text"] == "theirs", "did not restore the clipboard")
    assert(kept[1] == wav and #kept == 1, "kept " .. tostring(kept[1]) .. ", " .. #kept)
  end
)

print(passed .. " insert tests passed")

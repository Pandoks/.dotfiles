local root = assert(arg[1], "pass the dictation directory")
local passed, serial, alerts, strokes, clipboard, timers = 0, 0, {}, {}, {}, {}
local toggle, handlers, done, escape, focus, copied, saved
local config = {
  insert = "direct",
  trigger = "hotkey",
  hotkey = { mods = { "alt" }, key = "space" },
  cleanup = { enabled = false },
  minDuration = 0,
  minLevel = 0,
  history = {},
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
assert(loadfile(
  root .. "/init.lua",
  "t",
  setmetatable({
    require = function(name)
      return ({
        ["dictation.config"] = config,
        ["dictation.engine"] = {
          new = function(_, callbacks)
            handlers = callbacks
            return {
              ready = true,
              transcribe = function()
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
          end,
          prune = function() end,
        },
        ["dictation.recorder"] = {
          start = function()
            return {}
          end,
          stop = function(_, callback)
            done = callback
          end,
          cleanup = function() end,
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
          return stub()
        end,
      },
      timer = {
        doEvery = stub,
        doAfter = function(_, callback)
          timers[#timers + 1] = callback
          return stub()
        end,
      },
      microphoneState = function()
        return true
      end,
      accessibilityState = function()
        return true
      end,
      application = { frontmostApplication = function() end },
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
          return { {} }
        end,
        writeAllData = function(data)
          clipboard = data
          return true
        end,
        changeCount = function()
          return 1
        end,
        setContents = function(text)
          copied = text
          return true
        end,
      },
      eventtap = {
        keyStroke = function(mods, key)
          strokes[#strokes + 1] = mods[1] .. "+" .. key
        end,
      },
    },
  }, { __index = _G })
))()

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

test("focus moved while transcribing writes nothing and says so", function()
  local element = field("Hello", "", "")
  dictate(element, "there.", field("Other", "", ""))
  assert(element.written == nil and alerts[1] == "Dictation: focus moved while transcribing")
end)

test("a slider is not a text field: auto copies, direct says so", function()
  -- Chromium sliders take the write and drop it, like their fields do.
  local slider = field("", "", "1 minute of 3", true, "AXSlider")
  config.insert = "auto"
  dictate(slider, "Note to self.")
  config.insert = "direct"
  assert(slider.written == nil and #strokes == 0, "wrote into the slider")
  assert(copied == "Note to self." and alerts[1] == "Dictation copied to clipboard", "no copy")
  dictate(slider, "Note to self.")
  assert(slider.written == nil and alerts[1] == "Dictation: no text field is focused")
  assert(copied == nil, "direct mode copied")
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

test("a plain web page is not a text field: auto copies", function()
  local web = page(false)
  config.insert = "auto"
  dictate(web, "Note to self.")
  config.insert = "direct"
  assert(web.written == nil and #strokes == 0, "pasted into a plain page")
  assert(copied == "Note to self." and alerts[1] == "Dictation copied to clipboard", "no copy")
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

test("a field without a settable selection attribute is pasted with ⌘V", function()
  local element = unsettable("Attribute is not supported by target")
  dictate(element, "ls")
  assert(element.written == nil and strokes[1] == "cmd+v" and #alerts == 0, "not pasted")
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

print(passed .. " insert tests passed")

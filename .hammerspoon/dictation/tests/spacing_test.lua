local spaced = assert(loadfile(arg[1] .. "/spacing.lua"))()

-- AX ranges count UTF-16 units.
local function units(text)
  local count = 0
  for _, codepoint in utf8.codes(text) do
    count = count + (codepoint > 0xFFFF and 2 or 1)
  end
  return count
end

-- Text before, the selection, text after, the dictation, and what is written.
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
  local range = { location = units(before), length = units(selected) }
  local got = spaced(text, before .. selected .. after, range)
  assert(
    got == want,
    ("%s[%s]%s + %s: '%s', not '%s'"):format(before, selected, after, text, got, want)
  )
end
print("spacing tests passed")

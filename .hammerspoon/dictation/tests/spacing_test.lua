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
  { "“", "", "”", "hi", "hi" },
  { "‘", "", "’", "hi", "hi" },
  { "", "", "(aside)", "Note", "Note " },
  { "~/", "", "", "notes", "notes" },
  { "end", "", ".", "word", " word" },
  { 'He said "', "", '"', "hi", "hi" },
  { 'She said "I want ', "", '" and left.', "it", "it" }, -- a closing quote after a space
  { "He said '", "", "'", "hi", "hi" },
  { '("', "", "", "hi", "hi" },
  { 'He said "hi"', "", "", "and left.", " and left." },
  { "", "", '"quoted"', "Say", "Say " },
  { "", "Sam", "'s car", "John", "John" },
  { "Ask ", "Sam", "'s mom.", "John", "John" },
  { "Sam", "", "'s", "uel", " uel" },
  { "a ", "foo ", "'quoted'", "bar", "bar " },
  { "run `", "", "`", "ls", "ls" },
  { "", "", "`ls`", "Run", "Run " },
  { "😀", "", "", "hi", " hi" },
  { "😀 ", "", "world", "hi", "hi " },
  { "a ", "foo", " b", "bar", "bar" },
  { "a😀", "foo", "b", "bar", " bar " },
  { "", "", "éclair", "hello", "hello " },
  { "", "", "日本", "hello", "hello " },
  { "", "", "—then", "hello", "hello" }, -- a dash is a mark, not a word
  { "", "", "？", "hello", "hello" },
  { "你好", "", "世界", "漂亮", "漂亮" }, -- scripts without spaces between words
  { "你好。", "", "", "漂亮", "漂亮" },
  { "你好", "", "", "hello", " hello" },
  { "/usr/", "local", "/bin", "share", "share" },
  { "foo.", "local", ".bar", "remote", "remote" },
  { "foo.", "", "bar", "remote", "remote" },
  { "/usr/", "", "bin", "local", "local" },
  { "/usr", "", "/bin", "local", "local" },
  { "foo-", "bar", "", "remote", "remote" },
  { "foo_", "", "bar", "remote", "remote" },
  { "user@", "example", ".com", "work", "work" },
  { "user", "", "@example.com", "new", "new" },
  { "user+", "tag", "@example.com", "new", "new" },
  { "KEY=", "old", "", "new", "new" },
  { "C:\\", "old", "\\file", "new", "new" },
  { "image:", "latest", "", "stable", "stable" },
  { "fo", "ob", "ar", "baz", "baz" },
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

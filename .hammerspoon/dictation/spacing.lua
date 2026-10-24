local function set(chars)
  local result = {}
  for _, code in utf8.codes(chars) do
    result[utf8.char(code)] = true
  end
  return result
end

-- Delimiters that open a run: no space goes between them and the text.
local openers = set("([{“‘</")
-- A straight quote or backtick opens after the start, a space, or an opener, and before a word.
local quotes = set("\"'`")
-- Parts of a name, address, or path stay joined ("foo.|bar", "user|@host"); "Note:|" still spaces.
local joiners = set(".-_@+=:")
local slashes = set("/\\") -- "/usr/|bin", "/usr|/bin", "C:\[old]\file"
-- Punctuation blocks and Latin-1 marks, not letters: "—", "？".
local marks = {
  { 0x80, 0xBF },
  { 0x2000, 0x206F },
  { 0x3000, 0x303F },
  { 0xFF01, 0xFF0F },
  { 0xFF1A, 0xFF20 },
  { 0xFF3B, 0xFF40 },
  { 0xFF5B, 0xFF65 },
}
-- Chinese, Japanese, Thai, and the like put no space between words: "你好|世界" + "漂亮".
local unspaced = {
  { 0x0E00, 0x0EFF }, -- Thai, Lao
  { 0x1000, 0x109F }, -- Myanmar
  { 0x1780, 0x17FF }, -- Khmer
  { 0x2E80, 0x2FDF }, -- CJK radicals
  { 0x3000, 0x31FF }, -- CJK punctuation, kana, Bopomofo
  { 0x3400, 0x9FFF }, -- CJK ideographs
  { 0xF900, 0xFAFF },
  { 0xFF00, 0xFFEF }, -- fullwidth and halfwidth forms
  { 0x20000, 0x3FFFF },
}

local function within(char, blocks)
  local code = char ~= "" and utf8.codepoint(char) or 0
  for _, block in ipairs(blocks) do
    if code >= block[1] and code <= block[2] then
      return true
    end
  end
  return false
end

local function starts(char)
  return char == "" or char:match("^%s$") or openers[char]
end

-- A letter or digit in any script: "é", "日".
local function wordy(char)
  return char:match("^%w$") ~= nil or (#char > 1 and not within(char, marks))
end

-- The text spaced against its neighbors in `value` around `range` (a selection or the cursor).
---@param text string
---@param value string
---@param range table?
return function(text, value, range)
  if type(range) ~= "table" or not range.location then
    return text
  end
  -- Two characters on each side of the selection and its last one (AX ranges count UTF-16 units).
  local prior, before, last, after, beyond, units = "", "", "", "", "", 0
  for _, codepoint in utf8.codes(value) do
    -- Browsers store a typed trailing space in a contenteditable as U+00A0.
    local char = codepoint == 0xA0 and " " or utf8.char(codepoint)
    if units >= range.location + (range.length or 0) then
      if after ~= "" then
        beyond = char
        break
      end
      after = char
    elseif units < range.location then
      prior, before = before, char
    else
      last = char
    end
    units = units + (codepoint > 0xFFFF and 2 or 1)
  end
  local joined = (joiners[before] and wordy(prior) or slashes[before])
      and (last ~= "" or wordy(after))
    or wordy(before) and (slashes[after] or joiners[after] and wordy(beyond))
    -- Part of a word replaced: "fo[ob]ar" + "baz" is "fobazar".
    or (before .. last .. after):match("^%w%w%w$") ~= nil
  local first, final = utf8.char(utf8.codepoint(text, 1)), text:sub(utf8.offset(text, -1))
  if
    not starts(before)
    and not slashes[before]
    and not (quotes[before] and starts(prior))
    and not joined
    and not (within(before, unspaced) and within(first, unspaced))
  then
    text = " " .. text
  end
  -- A quote opening a word, or a dash opening a flag: "ls |-la".
  local opens = (quotes[after] and wordy(beyond) or after == "-")
    and starts(last ~= "" and last or before)
  -- A "/" after is a path going on ("/usr/share/bin"), not an opener.
  if
    (wordy(after) or (openers[after] and after ~= "/") or opens)
    and not joined
    and not (within(final, unspaced) and within(after, unspaced))
  then
    text = text .. " "
  end
  return text
end

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

local function starts(char)
  return char == "" or char:match("^%s$") or openers[char]
end

-- A letter or digit in any script: "é", "日".
local function wordy(char)
  if #char < 2 then
    return char:match("^%w$") ~= nil
  end
  local code = utf8.codepoint(char)
  for _, block in ipairs(marks) do
    if code >= block[1] and code <= block[2] then
      return false
    end
  end
  return true
end

-- The text spaced against its neighbors in `value` around `range` (a selection or the cursor).
---@param text string
---@param value string
---@param range table?
return function(text, value, range)
  if type(range) ~= "table" or not range.location then
    return text
  end
  -- Units are code points until a 4-byte character: skip to the two before the selection.
  local skip = value:find("[\240-\244]") and 0 or math.max(0, range.location - 2)
  -- Two characters on each side of the selection and its last one (AX ranges count UTF-16 units).
  local prior, before, last, after, beyond, units = "", "", "", "", "", skip
  for _, codepoint in utf8.codes(value:sub(utf8.offset(value, skip + 1) or #value + 1)) do
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
  if
    not starts(before)
    and not slashes[before]
    and not (quotes[before] and starts(prior))
    and not joined
  then
    text = " " .. text
  end
  -- A quote opening a word, or a dash opening a flag: "ls |-la".
  local opens = (quotes[after] and wordy(beyond) or after == "-")
    and starts(last ~= "" and last or before)
  -- A "/" after is a path going on ("/usr/share/bin"), not an opener.
  if (wordy(after) or (openers[after] and after ~= "/") or opens) and not joined then
    text = text .. " "
  end
  return text
end

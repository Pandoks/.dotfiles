local utils = require("lib.utils")

local history = {}

-- Transcripts are <timestamp>.txt; the folder's other files are never counted or deleted.
local transcript = "^%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d_?%d*%.txt$"
-- Transcript bytes, once prune() has listed the folder.
local bytes

---@param settings DictationHistory
local function folder(settings)
  return (
    settings.directory:gsub("^~", os.getenv("HOME") --[[@as string]])
  )
end

---@param settings DictationHistory
---@return string? failure
function history.prepare(settings)
  local directory = folder(settings)
  local quoted = utils.quote(directory)
  if not os.execute(("mkdir -p %s && chmod 700 %s"):format(quoted, quoted)) then
    return "could not create " .. directory .. " owner-only"
  end
end

---@param settings DictationHistory
---@param extension string
local function slot(settings, extension)
  local directory = folder(settings)
  local stamp = tostring(os.date("%Y-%m-%d_%H-%M-%S"))
  local path, count = ("%s/%s.%s"):format(directory, stamp, extension), 1
  while hs.fs.attributes(path) do
    count = count + 1
    path = ("%s/%s_%d.%s"):format(directory, stamp, count, extension)
  end
  return path
end

---@param text string
---@param settings DictationHistory
---@return string? failure
function history.save(text, settings)
  local path = slot(settings, "txt")
  -- Closed even after a failed write; a full disk may surface only at close.
  local file = io.open(path, "w")
  local written = file and file:write(text, "\n")
  if not (file and file:close() and written) then
    os.remove(path)
    return "could not write " .. path
  end
  bytes = bytes and bytes + hs.fs.attributes(path, "blocks") * 512
end

---@param wav string
---@param settings DictationHistory
---@return string? failure
function history.keep(wav, settings)
  local path = slot(settings, "wav")
  -- mv, not os.rename: the folder may be on another volume.
  if not os.execute(("mv %s %s"):format(utils.quote(wav), utils.quote(path))) then
    return "could not move it to " .. path
  end
end

-- Oldest first, never the newest; sizes are du-style blocks.
---@param settings DictationHistory
---@return string? failure
function history.prune(settings)
  local limit = settings.maxMegabytes * 1024 * 1024
  if bytes and bytes <= limit then
    return
  end
  local directory = folder(settings)
  local takes = {}
  bytes = 0
  for entry in hs.fs.dir(directory) do
    local blocks = entry:match(transcript) and hs.fs.attributes(directory .. "/" .. entry, "blocks")
    if blocks then
      takes[#takes + 1] = { name = entry, size = blocks * 512 }
      bytes = bytes + blocks * 512
    end
  end
  table.sort(takes, function(older, newer)
    return older.name < newer.name
  end)
  for index = 1, #takes - 1 do
    if bytes <= limit then
      break
    end
    local removed, problem = os.remove(directory .. "/" .. takes[index].name)
    if not removed then
      return problem
    end
    bytes = bytes - takes[index].size
  end
end

return history

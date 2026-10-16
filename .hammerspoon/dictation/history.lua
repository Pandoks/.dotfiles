local history = {}

-- Transcripts are <timestamp>.txt; the folder's other files are never counted or deleted.
local take = "^%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d_?%d*%.txt$"
-- Bytes of transcripts once prune() has counted them: it lists the folder again only past the cap.
local total

---@param settings DictationHistoryConfig
local function folder(settings)
  return (
    settings.directory:gsub("^~", os.getenv("HOME") --[[@as string]])
  )
end

-- Create the folder, owner-only even if it already existed; once, at load.
---@param settings DictationHistoryConfig
---@return string? failure
function history.prepare(settings)
  local directory = folder(settings)
  local quoted = directory:gsub("'", "'\\''")
  if not os.execute(("mkdir -p '%s' && chmod 700 '%s'"):format(quoted, quoted)) then
    return "could not create " .. directory .. " owner-only"
  end
end

-- A free <timestamp>.<extension> path in the folder.
---@param settings DictationHistoryConfig
---@param extension string
local function slot(settings, extension)
  local directory = folder(settings)
  -- A second take in the same second gets a suffix.
  local stamp = tostring(os.date("%Y-%m-%d_%H-%M-%S"))
  local path, count = ("%s/%s.%s"):format(directory, stamp, extension), 1
  while hs.fs.attributes(path) do
    count = count + 1
    path = ("%s/%s_%d.%s"):format(directory, stamp, count, extension)
  end
  return path
end

-- Save `text` as <timestamp>.txt.
---@param text string
---@param settings DictationHistoryConfig
---@return string? failure
function history.save(text, settings)
  local path = slot(settings, "txt")
  -- A full disk surfaces only at close.
  local file = io.open(path, "w")
  if not (file and file:write(text, "\n") and file:close()) then
    os.remove(path)
    return "could not write " .. path
  end
  total = total and total + hs.fs.attributes(path, "blocks") * 512
end

-- Move a recording in as <timestamp>.wav, never pruned: it is the only copy of what was said.
---@param wav string
---@param settings DictationHistoryConfig
---@return string? failure
function history.keep(wav, settings)
  local _, problem = os.rename(wav, slot(settings, "wav"))
  return problem
end

-- Delete the oldest transcripts over the cap, never the newest; sizes are du-style blocks.
---@param settings DictationHistoryConfig
---@return string? failure
function history.prune(settings)
  local limit = settings.maxMegabytes * 1024 * 1024
  if total and total <= limit then
    return
  end
  local directory = folder(settings)
  local takes = {}
  total = 0
  for entry in hs.fs.dir(directory) do
    local blocks = entry:match(take) and hs.fs.attributes(directory .. "/" .. entry, "blocks")
    if blocks then
      takes[#takes + 1] = { name = entry, size = blocks * 512 }
      total = total + blocks * 512
    end
  end
  table.sort(takes, function(a, b)
    return a.name < b.name
  end)
  for i = 1, #takes - 1 do
    if total <= limit then
      break
    end
    local removed, problem = os.remove(directory .. "/" .. takes[i].name)
    if not removed then
      return problem
    end
    total = total - takes[i].size
  end
end

return history

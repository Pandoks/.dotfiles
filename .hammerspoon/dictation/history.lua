local history = {}

-- Quoted for the shell.
---@param text string
local function quote(text)
  return "'" .. text:gsub("'", "'\\''") .. "'"
end

---@param settings DictationHistoryConfig
local function folder(settings)
  return (
    settings.directory:gsub("^~", os.getenv("HOME") --[[@as string]])
  )
end

-- Save `text` as <timestamp>.txt.
---@param text string
---@param settings DictationHistoryConfig
---@return string? failure
function history.save(text, settings)
  local directory = folder(settings)
  -- Owner-only: transcripts may hold anything said.
  if
    not hs.fs.attributes(directory, "mode")
    and not os.execute("umask 077 && mkdir -p " .. quote(directory))
  then
    return "could not create " .. directory
  end

  -- Timestamped names sort oldest first; a second take in the same second gets a suffix.
  local stamp = tostring(os.date("%Y-%m-%d_%H-%M-%S"))
  local name, count = stamp .. ".txt", 1
  while hs.fs.attributes(directory .. "/" .. name, "mode") do
    count = count + 1
    name = ("%s_%d.txt"):format(stamp, count)
  end
  local path = directory .. "/" .. name
  -- Owner-only, and set -C never writes through a file or symlink planted at the name.
  local write = "umask 077 && set -C && printf '%%s\\n' %s > %s"
  if not os.execute(write:format(quote(text), quote(path))) then
    return "could not write " .. path
  end
end

-- Delete the oldest transcripts over the cap, never the newest; sizes are du-style blocks.
---@param settings DictationHistoryConfig
---@return string? failure
function history.prune(settings)
  local directory = folder(settings)
  local limit = settings.maxMegabytes * 1024 * 1024
  local stamp = "^%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d"
  local files, total = {}, 0
  for entry in hs.fs.dir(directory) do
    -- Only names save() writes: the folder may hold the user's own files.
    if entry:match(stamp .. "%.txt$") or entry:match(stamp .. "_%d+%.txt$") then
      local attributes = hs.fs.attributes(directory .. "/" .. entry) or {}
      local size = (attributes.blocks or 0) * 512
      files[#files + 1] = { name = entry, size = size, created = attributes.creation or 0 }
      total = total + size
    end
  end
  -- By creation: names repeat an hour when daylight saving ends.
  table.sort(files, function(a, b)
    return a.created < b.created or (a.created == b.created and a.name < b.name)
  end)
  for i = 1, #files - 1 do
    if total <= limit then
      break
    end
    local removed, message = os.remove(directory .. "/" .. files[i].name)
    if not removed then
      return "could not delete " .. files[i].name .. ": " .. tostring(message)
    end
    total = total - files[i].size
  end
end

return history

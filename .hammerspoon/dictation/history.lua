local history = {}

-- Run `command path` owner-only: transcripts may hold anything said.
---@param command string
---@param path string
local function private(command, path)
  return os.execute(("umask 077 && %s '%s'"):format(command, (path:gsub("'", "'\\''"))))
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
  if not hs.fs.attributes(directory, "mode") and not private("mkdir -p", directory) then
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
  -- Created 0600 first; writing keeps the mode.
  if not private(": >", path) then
    return "could not create " .. path
  end
  local file, message = io.open(path, "w")
  if not file then
    return "could not write " .. path .. ": " .. tostring(message)
  end
  -- Writes are buffered: a full disk surfaces only at close.
  local written, problem = file:write(text, "\n")
  local closed, reason = file:close()
  if not (written and closed) then
    os.remove(path)
    return "could not write " .. path .. ": " .. tostring(problem or reason)
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

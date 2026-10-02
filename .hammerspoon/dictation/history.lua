local history = {}

-- The extended attribute that marks a file as a take save() wrote.
local MARK = "org.hammerspoon.dictation"
-- Bytes of takes per folder, once prune() has counted them: it rescans only past the cap.
local totals = {}

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

-- A free <timestamp>.<extension> path in the history folder, which is created owner-only.
---@param settings DictationHistoryConfig
---@param extension string
---@return string? path, string? failure
local function slot(settings, extension, time)
  local directory = folder(settings)
  -- Owner-only: transcripts may hold anything said.
  if
    not hs.fs.attributes(directory, "mode")
    and not os.execute("umask 077 && mkdir -p " .. quote(directory))
  then
    return nil, "could not create " .. directory
  end
  -- Anyone else who could write the folder could swap a take for a symlink while it is written.
  local owner = hs.fs.attributes(directory) or {}
  local mode = owner.permissions or ""
  if
    owner.uid ~= hs.fs.attributes(os.getenv("HOME") --[[@as string]], "uid")
    or mode:find("^....w")
    or mode:find("^.......w")
  then
    return nil, directory .. " must be yours and writable only by you"
  end

  -- Timestamped names sort oldest first; a second take in the same second gets a suffix.
  local stamp = tostring(os.date("%Y-%m-%d_%H-%M-%S", time))
  local name, count = ("%s.%s"):format(stamp, extension), 1
  while hs.fs.attributes(directory .. "/" .. name, "mode") do
    count = count + 1
    name = ("%s_%d.%s"):format(stamp, count, extension)
  end
  return directory .. "/" .. name
end

-- Save `text` as <timestamp>.txt.
---@param text string
---@param settings DictationHistoryConfig
---@return string? failure
function history.save(text, settings)
  local path, failure = slot(settings, "txt")
  if not path then
    return failure
  end
  -- Created owner-only first, and set -C never through a file or symlink planted at the name;
  -- the text stays out of the command line, which other users can see.
  if not os.execute("umask 077 && set -C && : > " .. quote(path)) then
    return "could not create " .. path
  end
  -- hs.fs.xattr raises on failure (a volume without extended attributes).
  local ok, marked = pcall(hs.fs.xattr.set, path, MARK, "take")
  if not ok or not marked then
    os.remove(path)
    return "could not mark " .. path .. " as a take: " .. tostring(marked)
  end
  local file, message = io.open(path, "w")
  if not file then
    os.remove(path)
    return "could not write " .. path .. ": " .. tostring(message)
  end
  -- Writes are buffered: a full disk surfaces only at close.
  local written, problem = file:write(text, "\n")
  local closed, reason = file:close()
  if not (written and closed) then
    os.remove(path)
    return "could not write " .. path .. ": " .. tostring(problem or reason)
  end
  local directory = folder(settings)
  if totals[directory] then
    totals[directory] = totals[directory] + (hs.fs.attributes(path, "blocks") or 0) * 512
  end
end

-- Move a recording in as <timestamp>.wav. Unmarked, so never counted or pruned: audio would push
-- out the transcripts under the cap, and this is the only copy until the user deletes it.
---@param file string
---@param settings DictationHistoryConfig
---@return string? failure
function history.keep(file, settings)
  local time = hs.fs.attributes(file, "modification")
  if not time then
    return "the recording " .. file .. " is gone"
  end
  -- Named for when it was recorded, not when it was kept.
  local path, failure = slot(settings, "wav", time)
  if not path then
    return failure
  end
  -- mv, which copies across volumes where a rename cannot; owner-only already (umask 077).
  local mv = assert(io.popen("mv " .. quote(file) .. " " .. quote(path) .. " 2>&1"))
  local output = mv:read("a")
  if not mv:close() then
    return "could not move " .. file .. " to " .. path .. ": " .. output:gsub("%s+$", "")
  end
end

-- Delete the oldest transcripts over the cap, never the newest; sizes are du-style blocks.
---@param settings DictationHistoryConfig
---@return string? failure
function history.prune(settings)
  local directory = folder(settings)
  local limit = settings.maxMegabytes * 1024 * 1024
  if totals[directory] and totals[directory] <= limit then
    return -- under the cap: no need to list the folder after every take
  end
  local files, total = {}, 0
  for entry in hs.fs.dir(directory) do
    local path = directory .. "/" .. entry
    -- Only takes save() marked: the folder may hold the user's own files, whatever their names.
    -- Regular files only: a link (dangling or to a take) is never read or counted.
    local attributes = hs.fs.symlinkAttributes(path) or {}
    if attributes.mode == "file" then
      -- hs.fs.xattr raises on a file it cannot read, which save() never wrote.
      local ok, marked = pcall(hs.fs.xattr.get, path, MARK)
      if ok and marked then
        local size = (attributes.blocks or 0) * 512
        files[#files + 1] = { name = entry, size = size, created = attributes.creation or 0 }
        total = total + size
      end
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
  totals[directory] = total
end

return history

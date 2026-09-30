local history = {}

-- Save `text` as <timestamp>.txt, then delete the oldest files past the size cap.
---@param text string
---@param settings DictationHistoryConfig
---@return string? failure
function history.save(text, settings)
  local directory = (settings.directory:gsub("^~", os.getenv("HOME") or "~"))
  local limit = settings.maxMegabytes * 1024 * 1024
  if not hs.fs.attributes(directory, "mode") then
    local ok, message = hs.fs.mkdir(directory)
    if not ok then
      return "could not create " .. directory .. ": " .. tostring(message)
    end
  end

  -- Timestamped names sort oldest first; a second take in the same second gets a suffix.
  local stamp = tostring(os.date("%Y-%m-%d_%H-%M-%S"))
  local name, count = stamp .. ".txt", 1
  while hs.fs.attributes(directory .. "/" .. name, "mode") do
    count = count + 1
    name = ("%s_%d.txt"):format(stamp, count)
  end
  local path = directory .. "/" .. name
  local file, message = io.open(path, "w")
  if not file then
    return "could not write " .. path .. ": " .. tostring(message)
  end
  file:write(text, "\n")
  file:close()

  -- Prune oldest first, never the newest; sizes are allocated 512-byte blocks, as `du` counts.
  local files, total = {}, 0
  for entry in hs.fs.dir(directory) do
    if entry:match("%.txt$") then
      local size = (hs.fs.attributes(directory .. "/" .. entry, "blocks") or 0) * 512
      files[#files + 1] = { name = entry, size = size }
      total = total + size
    end
  end
  table.sort(files, function(a, b)
    return a.name < b.name
  end)
  for i = 1, #files - 1 do
    if total <= limit then
      break
    end
    os.remove(directory .. "/" .. files[i].name)
    total = total - files[i].size
  end
end

return history

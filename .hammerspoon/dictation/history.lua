-- Keeps every dictation result as a .txt file, so a failed insert never loses
-- a take. The oldest files are deleted once the directory exceeds its cap.

local history = {}

-- Save `text` as <timestamp>.txt in `directory` (created if missing; "~" is the
-- home directory), then delete the oldest files until the directory's on-disk
-- size is <= maxBytes. The file just written is always kept. Returns the saved path.
---@param text string
---@param directory string
---@param maxBytes number on-disk bytes, as `du` counts them
---@return string? path, string? failure
function history.save(text, directory, maxBytes)
  directory = (directory:gsub("^~", os.getenv("HOME") or "~"))
  if not hs.fs.attributes(directory, "mode") then
    local ok, message = hs.fs.mkdir(directory)
    if not ok then
      return nil, "could not create " .. directory .. ": " .. tostring(message)
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
    return nil, "could not write " .. path .. ": " .. tostring(message)
  end
  file:write(text, "\n")
  file:close()

  -- Prune oldest first, never the newest. Sizes are allocated disk blocks
  -- (st_blocks, 512 bytes each): a one-line take still occupies 4 KB.
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
    if total <= maxBytes then
      break
    end
    os.remove(directory .. "/" .. files[i].name)
    total = total - files[i].size
  end
  return path
end

return history

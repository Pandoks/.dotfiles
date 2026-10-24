local root, frameworks, scratch = arg[1], arg[2], arg[3]
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
local date, clock = os.date, 0
-- os.date reads a clock the tests set, so take names are known.
local history = assert(loadfile(
  root .. "/history.lua",
  "t",
  setmetatable({
    hs = { fs = fs },
    os = setmetatable({
      date = function(format)
        return date(format, clock)
      end,
    }, { __index = os }),
  }, { __index = _G })
))()

local function list(directory)
  local names = {}
  for entry in fs.dir(directory) do
    if entry ~= "." and entry ~= ".." then
      names[#names + 1] = entry
    end
  end
  table.sort(names)
  return table.concat(names, " ")
end

local directory = scratch .. "/history"
local settings = { directory = directory, maxMegabytes = 3 * 4096 / 1024 / 1024 } -- three blocks

os.execute(("mkdir -m 755 '%s'"):format(directory))
assert(not history.prepare(settings) and fs.attributes(directory, "permissions") == "rwx------")
io.open(scratch .. "/file", "w"):close()
local unmade = scratch .. "/file/history"
assert(history.prepare({ directory = unmade }) == "could not create " .. unmade .. " owner-only")
local quoted = scratch .. "/it's"
assert(not history.prepare({ directory = quoted }))
assert(fs.attributes(quoted, "permissions") == "rwx------")
clock = os.time({ year = 2026, month = 1, day = 2, hour = 3, min = 4, sec = 5 })
assert(not history.save("one", settings) and not history.save("two", settings))
assert(list(directory) == "2026-01-02_03-04-05.txt 2026-01-02_03-04-05_2.txt", list(directory))

-- Past the cap the oldest takes go; other files, a Finder copy of a take too, stay.
for _, name in ipairs({ "notes.txt", "2026-01-02_03-04-05 copy.txt" }) do
  io.open(directory .. "/" .. name, "w"):close()
end
for second = 6, 8 do
  clock = clock + 1
  assert(not history.save(("take %d"):format(second), settings))
  assert(not history.prune(settings))
end
local want = "2026-01-02_03-04-05 copy.txt 2026-01-02_03-04-06.txt 2026-01-02_03-04-07.txt "
  .. "2026-01-02_03-04-08.txt notes.txt"
assert(list(directory) == want, list(directory))

-- Pruning never deletes a kept recording.
local wav = scratch .. "/take.wav"
local file = assert(io.open(wav, "w"))
file:write("RIFF")
file:close()
assert(not history.keep(wav, settings) and not fs.attributes(wav))
clock = clock + 1
assert(not history.save("take 9", settings) and not history.prune(settings))
want = "2026-01-02_03-04-05 copy.txt 2026-01-02_03-04-07.txt 2026-01-02_03-04-08.txt "
  .. "2026-01-02_03-04-08.wav 2026-01-02_03-04-09.txt notes.txt"
assert(list(directory) == want, list(directory))
-- Never the newest, even past the cap.
assert(not history.prune({ directory = directory, maxMegabytes = 0 }))
want = "2026-01-02_03-04-05 copy.txt 2026-01-02_03-04-08.wav 2026-01-02_03-04-09.txt notes.txt"
assert(list(directory) == want, list(directory))
print("history tests passed")

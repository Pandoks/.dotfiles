local root, frameworks, scratch = arg[1], arg[2], arg[3]
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
local date, clock = os.date, 0
-- history.lua with the real hs.fs, stamping takes at a clock the tests set.
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

-- Owner-only even if it already existed; stamped, suffixed within the second.
os.execute(("mkdir -m 755 '%s'"):format(directory))
assert(not history.prepare(settings) and fs.attributes(directory, "permissions") == "rwx------")
clock = os.time({ year = 2026, month = 1, day = 2, hour = 3, min = 4, sec = 5 })
assert(not history.save("one", settings) and not history.save("two", settings))
assert(list(directory) == "2026-01-02_03-04-05.txt 2026-01-02_03-04-05_2.txt", list(directory))

-- Past the cap the oldest takes go; other files stay.
io.open(directory .. "/notes.txt", "w"):close()
for second = 6, 8 do
  clock = clock + 1
  assert(not history.save(("take %d"):format(second), settings))
  assert(not history.prune(settings))
end
local want = "2026-01-02_03-04-06.txt 2026-01-02_03-04-07.txt 2026-01-02_03-04-08.txt notes.txt"
assert(list(directory) == want, list(directory))

-- A kept recording moves in, and pruning never deletes it.
local wav = scratch .. "/take.wav"
local file = assert(io.open(wav, "w"))
file:write("RIFF")
file:close()
assert(not history.keep(wav, settings) and not fs.attributes(wav))
clock = clock + 1
assert(not history.save("take 9", settings) and not history.prune(settings))
want = "2026-01-02_03-04-07.txt 2026-01-02_03-04-08.txt 2026-01-02_03-04-08.wav "
  .. "2026-01-02_03-04-09.txt notes.txt"
assert(list(directory) == want, list(directory))
print("history tests passed")

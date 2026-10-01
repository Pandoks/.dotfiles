local root, frameworks, scratch = assert(arg[1], "pass the dictation directory"), arg[2], arg[3]
---@type hs.fs
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
local date, clock, passed = os.date, 0, 0
-- save() stamps takes in its own format, at a clock the tests set.
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

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

local function list(directory)
  local names = {}
  for entry in fs.dir(directory) do
    if entry ~= "." and entry ~= ".." then
      names[#names + 1] = entry
    end
  end
  table.sort(names)
  return names
end

local function expect(directory, names)
  table.sort(names)
  local got, want = table.concat(list(directory), " "), table.concat(names, " ")
  assert(got == want, "left " .. got .. ", expected " .. want)
end

test("save stamps each take and suffixes a repeat within the second", function()
  local settings = { directory = scratch .. "/save", maxMegabytes = 10 }
  clock = 1790000000
  assert(history.save("first", settings) == nil and history.save("second", settings) == nil)
  local names = list(settings.directory)
  assert(#names == 2 and names[2] == names[1]:gsub("%.txt$", "_2.txt"), table.concat(names, " "))
  -- Owner-only whatever the umask: transcripts may hold anything said.
  assert(fs.attributes(settings.directory, "permissions") == "rwx------", "folder not private")
  for _, name in ipairs(names) do
    local mode = fs.attributes(settings.directory .. "/" .. name, "permissions")
    assert(mode == "rw-------", name .. " is " .. tostring(mode))
  end
  for i, text in ipairs({ "first\n", "second\n" }) do
    local file = assert(io.open(settings.directory .. "/" .. names[i]))
    assert(file:read("a") == text, names[i] .. " holds the wrong text")
    file:close()
  end
end)

test("prune deletes the oldest takes past the cap, never the newest or other files", function()
  local settings = { directory = scratch .. "/prune", maxMegabytes = 10 }
  for _, time in ipairs({ 1767000000, 1790000000, 1790000000 }) do
    clock = time
    assert(history.save("take", settings) == nil)
  end
  local takes = list(settings.directory)
  local mine = { "notes.txt", "2020-01-01.txt", "todo.md" }
  for _, name in ipairs(mine) do
    local file = assert(io.open(settings.directory .. "/" .. name, "w"))
    file:write(("mine "):rep(4096))
    file:close()
  end

  -- A cap of two takes deletes only the oldest.
  local blocks = fs.attributes(settings.directory .. "/" .. takes[1], "blocks")
  settings.maxMegabytes = 2 * blocks * 512 / 1024 / 1024
  assert(history.prune(settings) == nil)
  expect(settings.directory, { takes[2], takes[3], table.unpack(mine) })

  -- Every take is over a zero cap: the newest still stays.
  settings.maxMegabytes = 0
  assert(history.prune(settings) == nil)
  expect(settings.directory, { takes[3], table.unpack(mine) })
end)

test("prune reports a take it cannot delete", function()
  local settings = { directory = scratch .. "/locked", maxMegabytes = 10 }
  for _, time in ipairs({ 1790000000, 1790000001 }) do
    clock = time
    assert(history.save("take", settings) == nil)
  end
  local oldest = settings.directory .. "/" .. list(settings.directory)[1]
  assert(os.execute(("chflags uchg %q"):format(oldest)))
  settings.maxMegabytes = 0
  local failure = history.prune(settings)
  assert(os.execute(("chflags nouchg %q"):format(oldest)))
  assert(failure and failure:find("could not delete", 1, true), tostring(failure))
end)

print(passed .. " history tests passed")

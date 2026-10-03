local root, frameworks, scratch = assert(arg[1], "pass the dictation directory"), arg[2], arg[3]
---@type hs.fs
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
local xattr =
  assert(package.loadlib(frameworks .. "/hs/libfsxattr.dylib", "luaopen_hs_libfsxattr"))()
local date, execute, clock, passed, commands = os.date, os.execute, 0, 0, {}
local opening = io.open -- what save() opens files with; a test swaps in a failing one
local popening = io.popen -- what keep() runs mv with; likewise
local listings = 0 -- folders prune() listed
-- save() stamps takes in its own format, at a clock the tests set; its shell commands are kept.
local history = assert(loadfile(
  root .. "/history.lua",
  "t",
  setmetatable({
    hs = {
      fs = setmetatable({
        xattr = xattr,
        dir = function(...)
          listings = listings + 1
          return fs.dir(...)
        end,
      }, { __index = fs }),
    },
    io = setmetatable({
      open = function(...)
        return opening(...)
      end,
      popen = function(...)
        return popening(...)
      end,
    }, { __index = io }),
    os = setmetatable({
      date = function(format, time)
        return date(format, time or clock)
      end,
      execute = function(command)
        commands[#commands + 1] = command
        return execute(command)
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
  -- The user's own files, one named like a take, and a link to a take.
  local mine = { "notes.txt", "2020-01-01_00-00-00.txt" }
  for _, name in ipairs(mine) do
    local file = assert(io.open(settings.directory .. "/" .. name, "w"))
    file:write(("mine "):rep(4096))
    file:close()
  end
  mine[#mine + 1] = "link.txt"
  assert(fs.link(settings.directory .. "/" .. takes[3], settings.directory .. "/link.txt", true))

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

test("prune goes by creation time when the clock went back", function()
  local settings = { directory = scratch .. "/clock", maxMegabytes = 10 }
  -- The second take is stamped an hour earlier, as when daylight saving ends.
  for _, time in ipairs({ 1790003600, 1790000000 }) do
    clock = time
    assert(history.save("take", settings) == nil)
  end
  local newer, older = table.unpack(list(settings.directory))
  -- An older mtime moves the birth time back: the takes' creation order stays clear.
  assert(os.execute(("touch -t 202601010000 %q"):format(settings.directory .. "/" .. older)))
  settings.maxMegabytes = 0
  assert(history.prune(settings) == nil)
  expect(settings.directory, { newer })
end)

test("save never writes through a symlink planted at its name", function()
  local settings = { directory = scratch .. "/planted", maxMegabytes = 10 }
  clock = 1790000000
  assert(fs.mkdir(settings.directory))
  -- Dangling, so the name looks free; the take would land in the link's target.
  local target, name = scratch .. "/stolen.txt", date("%Y-%m-%d_%H-%M-%S", clock) .. ".txt"
  assert(fs.link(target, settings.directory .. "/" .. name, true))
  local failure = history.save("secret", settings)
  assert(failure and failure:find("could not create", 1, true), tostring(failure))
  assert(not fs.attributes(target), "wrote through the symlink")
end)

test("save keeps the text out of shell commands, which other users can see", function()
  local settings = { directory = scratch .. "/argv", maxMegabytes = 10 }
  commands = {}
  assert(history.save("my password is hunter2", settings) == nil)
  assert(#commands > 0 and not table.concat(commands, "\n"):find("hunter2", 1, true))
end)

test("save refuses a folder other users can write", function()
  local settings = { directory = scratch .. "/shared", maxMegabytes = 10 }
  assert(fs.mkdir(settings.directory))
  assert(os.execute(("chmod 777 %q"):format(settings.directory)))
  local failure = history.save("secret", settings)
  assert(failure and failure:find("writable only by you", 1, true), tostring(failure))
  expect(settings.directory, {})
end)

test("save leaves no empty take when it cannot open it", function()
  local settings = { directory = scratch .. "/unopened", maxMegabytes = 10 }
  opening = function()
    return nil, "Too many open files"
  end
  local failure = history.save("secret", settings)
  opening = io.open
  assert(failure and failure:find("could not write", 1, true), tostring(failure))
  expect(settings.directory, {})
end)

test("keep moves a recording in, where prune never deletes it", function()
  local settings = { directory = scratch .. "/kept", maxMegabytes = 0 }
  clock = 1790000000
  local recording = scratch .. "/take.wav"
  local file = assert(io.open(recording, "w"))
  file:write("RIFF")
  file:close()
  -- Named for when it was recorded.
  assert(os.execute(("touch -t 202601020304.05 %q"):format(recording)))
  assert(history.keep(recording, settings) == nil and not fs.attributes(recording))
  assert(history.save("take", settings) == nil and history.prune(settings) == nil)
  local stamp = date("%Y-%m-%d_%H-%M-%S", clock)
  expect(settings.directory, { "2026-01-02_03-04-05.wav", stamp .. ".txt" })
end)

test("keep reports why a recording could not move, and leaves it", function()
  local settings = { directory = scratch .. "/unmoved", maxMegabytes = 10 }
  local locked = scratch .. "/locked"
  assert(fs.mkdir(locked))
  local recording = locked .. "/take.wav"
  assert(io.open(recording, "w")):close()
  assert(os.execute(("chmod 555 %q"):format(locked))) -- mv cannot unlink it from here
  local failure = history.keep(recording, settings)
  os.execute(("chmod 755 %q"):format(locked))
  assert(failure and failure:find("Permission denied", 1, true), tostring(failure))
  assert(fs.attributes(recording), "lost the recording")
end)

test("keep reports a move it cannot start, not raises", function()
  local recording = scratch .. "/unstarted.wav"
  assert(io.open(recording, "w")):close()
  popening = function()
    return nil, "Too many open files"
  end
  local ok, failure = pcall(history.keep, recording, { directory = scratch .. "/unstarted" })
  popening = io.popen
  assert(ok and failure and failure:find("Too many open files", 1, true), tostring(failure))
  assert(fs.attributes(recording), "lost the recording")
end)

test("keep reports a recording that is gone, leaving nothing", function()
  local settings = { directory = scratch .. "/gone", maxMegabytes = 10 }
  local failure = history.keep(scratch .. "/missing.wav", settings)
  assert(failure and failure:find("is gone", 1, true), tostring(failure))
  assert(not fs.attributes(settings.directory), "created the folder for nothing")
end)

test("prune lists the folder only while it may be over the cap", function()
  local settings = { directory = scratch .. "/counted", maxMegabytes = 10 }
  clock = 1790000000
  assert(history.save("take", settings) == nil)
  -- A cap of one take: counting it lists the folder once, and it is not listed again under it.
  local blocks = fs.attributes(settings.directory .. "/" .. list(settings.directory)[1], "blocks")
  settings.maxMegabytes = blocks * 512 / 1024 / 1024
  listings = 0
  assert(history.prune(settings) == nil and history.prune(settings) == nil)
  assert(listings == 1, "listed a folder under its cap")
  -- The next take puts it over: the oldest goes.
  clock = 1790000001
  assert(history.save("take", settings) == nil)
  local takes = list(settings.directory)
  assert(history.prune(settings) == nil)
  expect(settings.directory, { takes[2] })
end)

test("prune skips a file it cannot read", function()
  local settings = { directory = scratch .. "/unreadable", maxMegabytes = 0 }
  clock = 1790000000
  assert(history.save("take", settings) == nil)
  local take = list(settings.directory)[1]
  local mine = settings.directory .. "/mine.txt"
  assert(io.open(mine, "w")):close()
  assert(os.execute(("chmod 000 %q"):format(mine)))
  local ok, failure = pcall(history.prune, settings)
  os.execute(("chmod 600 %q"):format(mine))
  assert(ok and failure == nil, tostring(failure))
  -- Not counted as a take: the take stays the newest, and the user's file is never deleted.
  expect(settings.directory, { take, "mine.txt" })
end)

test("save reports a folder that takes no extended attributes, leaving nothing", function()
  local settings = { directory = scratch .. "/unmarked", maxMegabytes = 10 }
  local set = xattr.set
  xattr.set = function()
    error("Operation not supported")
  end
  local ok, failure = pcall(history.save, "secret", settings)
  xattr.set = set
  assert(ok and failure and failure:find("could not mark", 1, true), tostring(failure))
  expect(settings.directory, {})
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

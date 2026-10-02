local root, frameworks, scratch = assert(arg[1], "pass the dictation directory"), arg[2], arg[3]
---@type hs.fs
local fs = assert(package.loadlib(frameworks .. "/hs/libfs.dylib", "luaopen_hs_libfs"))()
local passed, args, gone = 0, nil, false

local function test(name, callback)
  local ok, failure = pcall(callback)
  assert(ok, name .. ": " .. tostring(failure))
  passed = passed + 1
  print("PASS " .. name)
end

-- recorder.lua with ffmpeg found at a fake path and its capture task's arguments kept.
local recorder = assert(loadfile(
  root .. "/recorder.lua",
  "t",
  setmetatable({
    require = function(name)
      return name == "dictation.spectrum" and { new = function() end } or require(name)
    end,
    hs = {
      fs = setmetatable({
        pathToAbsolute = function() end,
        attributes = function(path, ...)
          if path:find("/ffmpeg$") then
            return not gone and "file" or nil
          end
          return fs.attributes(path, ...)
        end,
        temporaryDirectory = function()
          return scratch .. "/"
        end,
      }, { __index = fs }),
      execute = function()
        return ""
      end,
      host = {
        uuid = function()
          return "take"
        end,
      },
      task = {
        new = function(_, _, _, arguments)
          args = arguments
        end,
      },
    },
  }, { __index = _G })
))()

test("ffmpeg removed since load is reported, not run", function()
  gone = true
  local recording, message = recorder.start(8, function() end)
  gone = false
  assert(not recording and message:find("is gone; reload Hammerspoon", 1, true), tostring(message))
end)

test("the capture shell writes recordings owner-only", function()
  recorder.start(8, function() end)
  local watchdog = assert(args and args[2], "no capture task")
  local file = scratch .. "/written.wav"
  -- The capture's own shell, running touch in place of ffmpeg; stdin stays open until it is done.
  local command = ("sleep 1 | /bin/sh -c '%s' /usr/bin/touch %q"):format(watchdog, file)
  assert(os.execute(command))
  assert(fs.attributes(file, "permissions") == "rw-------", tostring(fs.attributes(file, "mode")))
end)

print(passed .. " recorder tests passed")

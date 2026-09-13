local utils = require("lib.utils")

local sockfile = string.format("/tmp/yabai_%s.socket", os.getenv("USER") or "")

---@alias YabaiCallback fun(ok: boolean, stdout: string, stderr: string)
---@alias YabaiSpaceCallback fun(ok: boolean, errorMessage?: string)

---@class YabaiNative
---@field run fun(socketPath: string, args: string[], timeoutMs: integer, done: YabaiCallback)

---Quote for /bin/sh: single quotes disable every kind of expansion.
---@param s string
---@return string
local function shellQuote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Load lib/yabai/native.m, compiling it into the app's cache directory on
-- first use or after an edit. The output name carries the arch, Hammerspoon
-- version and a hash of the source, so a stale binary is never loaded against
-- a changed LuaSkin ABI and a rebuilt module loads as a fresh image instead of
-- dyld handing back the one already mapped.
---@return YabaiNative
local function loadNative()
  local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]*$")
  local src = here .. "/yabai/native.m"
  local file = assert(io.open(src, "rb"), "missing " .. src)
  local sourceHash = hs.hash.SHA256(file:read("a")):sub(1, 16)
  file:close()
  local info = hs.processInfo
  local cache = string.format("%s/Library/Caches/%s/yabai", os.getenv("HOME"), info.bundleID)
  local so = string.format(
    "%s/native-%s-%s.%s-%s.so",
    cache,
    info.arch,
    info.version,
    info.build,
    sourceHash
  )
  if not hs.fs.attributes(so) then
    local frameworks = info.frameworksPath
    local argv = {
      "clang",
      "-arch",
      info.arch,
      "-O2",
      "-Wall",
      "-Wextra",
      "-Wshadow",
      "-fobjc-arc",
      "-fmodules",
      "-bundle",
      "-undefined",
      "dynamic_lookup",
      "-F" .. frameworks,
      "-I" .. frameworks .. "/LuaSkin.framework/Headers",
      src,
      "-o",
      so,
    }
    for i, arg in ipairs(argv) do
      argv[i] = shellQuote(arg)
    end
    local output, ok = hs.execute(
      string.format("mkdir -p %s && %s 2>&1", shellQuote(cache), table.concat(argv, " "))
    )
    if not ok then
      error("yabai: building native.m failed:\n" .. output, 0)
    elseif output ~= "" then
      print("yabai: native.m built with warnings:\n" .. output)
    end
    for entry in hs.fs.dir(cache) do
      if entry:match("^native%-.+%.so$") and cache .. "/" .. entry ~= so then
        os.remove(cache .. "/" .. entry)
      end
    end
  end
  return assert(package.loadlib(so, "luaopen_yabai_native"))()
end

local native = loadNative()

---@class YabaiClient
local yabai = {}

---@param ok boolean
---@param stdout? string stdout for `run`, or error message for `switchSpace`
---@param stderr? string stderr for `run`
local function report(ok, stdout, stderr)
  if ok then
    return
  end
  print("yabai error: " .. ((stderr and stderr ~= "") and stderr or stdout or ""))
end

---@param args string[] yabai arguments, with or without a leading "-m"
---@param done? YabaiCallback
---@param timeout? number seconds; defaults to 10
function yabai.run(args, done, timeout)
  local first = args[1] == "-m" and 2 or 1
  native.run(
    sockfile,
    table.move(args, first, #args, 1, {}),
    math.floor((timeout or 10) * 1000),
    done or report
  )
end

---@type table<integer, { callbacks: YabaiSpaceCallback[], timer: hs.timer, deadline: number }>
local pendingSpaceChanges = {} -- native Space ID -> waiters for that Space

---@param spaceID integer
---@param ok boolean
---@param errorMessage? string
local function settleSpaceChange(spaceID, ok, errorMessage)
  local pending = pendingSpaceChanges[spaceID]
  if not pending then
    return
  end
  pendingSpaceChanges[spaceID] = nil
  pending.timer:stop()
  for _, callback in ipairs(pending.callbacks) do
    -- one failing waiter must not starve the others
    local called, traceback = xpcall(callback, debug.traceback, ok, errorMessage)
    if not called then
      print("yabai: switchSpace callback failed: " .. tostring(traceback))
    end
  end
end

---@param spaceIndex integer yabai Mission Control index
---@param done? YabaiSpaceCallback
---@param timeout? number seconds; defaults to 10
function yabai.switchSpace(spaceIndex, done, timeout)
  done = done or report

  local spaceList, err = utils.spaces()
  if not spaceList then
    done(false, err)
    return
  end
  local space = spaceList[spaceIndex]
  if not space then
    done(false, "space " .. spaceIndex .. " does not exist")
    return
  end
  local spaceID = space.ManagedSpaceID
  if type(spaceID) ~= "number" then
    done(false, "invalid Space id")
    return
  end

  if hs.spaces.focusedSpace() == spaceID then
    done(true)
    return
  end
  timeout = timeout or 10
  local deadline = hs.timer.secondsSinceEpoch() + timeout
  local pending = pendingSpaceChanges[spaceID]
  if pending then -- a switch is already in flight; settle both callers together
    pending.callbacks[#pending.callbacks + 1] = done
    if deadline < pending.deadline then -- never make a waiter wait longer than it asked
      pending.deadline = deadline
      pending.timer:setNextTrigger(timeout)
    end
    return
  end

  pendingSpaceChanges[spaceID] = {
    callbacks = { done },
    deadline = deadline,
    timer = hs.timer.doAfter(timeout, function()
      settleSpaceChange(spaceID, false, "timed out waiting for Space " .. spaceIndex)
    end),
  }
  yabai.run({ "space", "--focus", tostring(spaceIndex) }, function(ok, _, stderr)
    if not ok then
      settleSpaceChange(spaceID, false, stderr)
    end
  end, timeout)
end

-- hs.spaces.watcher retains itself in the LuaSkin registry while started
-- (libspaces_watcher.m: `spaceWatcher->self = [skin luaRef:refTable]`), so a
-- local is enough to keep it alive; keeping it local also means nothing
-- outside this module can stop it.
---@diagnostic disable-next-line: unused-local
local spaceWatcher = hs.spaces.watcher
  .new(function(_)
    settleSpaceChange(hs.spaces.focusedSpace(), true)
  end)
  :start()

---@return YabaiClient
return yabai

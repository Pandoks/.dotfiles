local root, cache = assert(arg[1]), assert(arg[2])
local builds, loaded, alerts = 0, {}, {}
local environment = setmetatable({
  hs = {
    processInfo = {
      arch = "arm64",
      version = "audit",
      build = "1",
      bundleID = "audit",
      frameworksPath = os.getenv("HAMMERSPOON_APP")
          and os.getenv("HAMMERSPOON_APP") .. "/Contents/Frameworks"
        or "/Applications/Hammerspoon.app/Contents/Frameworks",
    },
    hash = {
      SHA256 = function()
        return "isolated-build"
      end,
    },
    fs = {
      attributes = function(path)
        local file = io.open(path, "rb")
        if file then
          file:close()
          return true
        end
      end,
      dir = function()
        return function() end
      end,
    },
    execute = function(command)
      builds = builds + 1
      local process = assert(io.popen(command))
      local output = process:read("a")
      local ok = process:close()
      return output, ok
    end,
  },
  os = setmetatable({
    getenv = function(name)
      return name == "HOME" and cache or os.getenv(name)
    end,
  }, { __index = os }),
  package = {
    loadlib = function(path, symbol)
      local file = assert(io.open(path, "rb"), "native compiler produced no image")
      file:close()
      loaded[#loaded + 1] = symbol
      return function()
        return { path = path }
      end
    end,
  },
  require = function(name)
    assert(name == "lib.logger")
    return {
      error = function(message)
        alerts[#alerts + 1] = message
      end,
    }
  end,
}, { __index = _G })
local utils = assert(loadfile(root .. "/utils.lua", "t", environment))()
local value = "space ' quote $HOME $(printf expanded) `printf expanded`\nnewline"
local process = assert(io.popen("printf %s " .. utils.quote(value)))
assert(process:read("a") == value)
assert(process:close())
print("PASS shell quoting preserves expansions and newlines literally")
for _, name in ipairs({ "wm", "previews" }) do
  local first = utils.native(name)
  local second = utils.native(name)
  assert(first.path == second.path)
end
assert(builds == 2 and #loaded == 4 and #alerts == 0)
print("PASS both native modules build through one loader and reuse their caches")
environment.package.loadlib = function()
  return nil, "load failed"
end
assert(not pcall(utils.native, "wm"))
assert(#alerts == 1 and alerts[1]:find("load failed", 1, true))
print("PASS native loading errors log, alert, and stop")
print("RESULT 3 passed, 0 failed")

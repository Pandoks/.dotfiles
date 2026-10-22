local classify = require("lib.url_router.match")
local logger = require("lib.logger")
local router = {}

---@alias URLAction fun(url: string, report?: fun(message: string)): boolean

---@class URLRule
---@field host? string domain, including its subdomains
---@field pattern? string Lua pattern matched against the complete URL
---@field open URLAction

---@class URLRouterNative
---@field publish fun(path: string, contents: string): boolean, string?
---@field read fun(path: string): string?, string?, integer?
---@field watch fun(path: string, changed: fun(error?: string)): fun()?, string?
---@field process fun(pid: integer, executable: string, stopped: fun(error: string)): fun()?, string?

local native = require("lib.utils").native("url_router") --[[@as URLRouterNative]]
local directory = os.getenv("HOME") .. "/Library/Application Support/HammerspoonURLRouter"
local selectors = directory .. "/selectors/rules.json"
---@type { generation: string, rules: URLRule[], sha256: string }?
local current
local ready, failure = false, nil
---@type fun()?
local cancel
---@type fun()?
local cancelProcess

local function fail(message)
  ready = false
  if message ~= failure then
    logger.error("URL routing failed: " .. message)
  end
  failure = message
end

---@param url string
---@return integer index -1 invalid, 0 unmatched
---@return string? error
function router.match(url)
  if not current then
    return -1, "rules are not installed"
  end
  local parts = type(url) == "string" and hs.http.urlParts(url) or nil
  return classify(current.rules, url, parts and parts.host, parts and parts.scheme)
end

---@return { generation?: string, ready: boolean, error?: string }
function router.status()
  return { generation = current and current.generation, ready = ready, error = failure }
end

---Opens a URL with the action for the key its adapter finds, or `default` for other keys.
---@param adapter fun(url: string, done: fun(key?: string, error?: string)) calls `done` once, now or later
---@param actions table<string, URLAction>
---@param default URLAction
---@return URLAction
function router.by(adapter, actions, default)
  return function(url, report)
    report = report or logger.error
    local result
    adapter(url, function(key, message)
      if message then
        report(message)
        result = false
      else
        result = (actions[key] or default)(url, report)
      end
    end)
    -- Adapters that finish later report their own failures.
    return result ~= false
  end
end

---@param rules URLRule[]
---@return boolean
function router.install(rules)
  local actions, values = {}, {}
  if type(rules) ~= "table" then
    logger.error("Invalid URL rules: expected an ordered array")
    return false
  end
  for index in pairs(rules) do
    if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > #rules then
      logger.error("Invalid URL rules: expected an ordered array")
      return false
    end
  end
  for index = 1, #rules do
    local rule = rules[index]
    local valid = type(rule) == "table"
      and type(rule.open) == "function"
      and (
        (type(rule.host) == "string" and rule.host ~= "" and rule.pattern == nil)
        or (
          type(rule.pattern) == "string"
          and rule.host == nil
          and pcall(string.match, "", rule.pattern)
        )
      )
    if not valid then
      logger.error("Invalid URL rule " .. index)
      return false
    end
    actions[index] = { host = rule.host, pattern = rule.pattern, open = rule.open }
    values[index] = { host = rule.host, pattern = rule.pattern }
  end

  local generation = hs.host.uuid()
  local encoded, contents =
    pcall(hs.json.encode, { version = 1, generation = generation, rules = values }, false)
  if not encoded or type(contents) ~= "string" then
    logger.error("Could not encode URL selectors: " .. tostring(contents))
    return false
  end
  for _, path in ipairs({ directory, directory .. "/selectors" }) do
    local mode = hs.fs.attributes(path, "mode")
    if not mode then
      local created, message = hs.fs.mkdir(path)
      if not created then
        logger.error("Could not create URL selector directory: " .. tostring(message))
        return false
      end
    elseif mode ~= "directory" then
      logger.error("URL selector path is not a directory: " .. path)
      return false
    end
  end
  local published, message = native.publish(selectors, contents)
  if not published then
    logger.error("Could not publish URL selectors: " .. tostring(message))
    return false
  end
  if cancel then
    cancel()
    cancel = nil
  end
  if cancelProcess then
    cancelProcess()
    cancelProcess = nil
  end
  current = { generation = generation, rules = actions, sha256 = hs.hash.SHA256(contents) }
  ready, failure = false, nil

  local function route(url, expected)
    if not ready or (expected and expected ~= generation) then
      logger.error("URL routing failed: selector generation is not ready")
      return false
    end
    local index, error = router.match(url)
    if index < 0 then
      logger.error("URL routing failed: " .. (error or "rule classification failed"))
      return false
    elseif index == 0 then
      return "native"
    end
    local reported = false
    local function report(cause)
      if not reported then
        reported = true
        logger.error(cause)
      end
    end
    local ok, result = xpcall(actions[index].open, debug.traceback, url, report)
    if not ok or type(result) ~= "boolean" then
      report("URL rule failed: " .. tostring(result))
      return false
    elseif not result then
      report("URL rule failed: action returned false")
    end
    return result
  end

  RouteHTTPURL = route
  hs.urlevent.httpCallback = function(_, _, _, url)
    if route(url) ~= "native" then
      return
    end
    local path = hs.application.pathForBundleID("local.pandoks.HammerspoonURLRouter")
    if not path then
      logger.error("Native URL handler is not installed")
      return
    end
    local task = hs.task.new(
      path .. "/Contents/MacOS/HammerspoonURLRouter",
      function(code, _, output)
        if code ~= 0 then
          logger.error("Native URL handling failed: " .. output)
        end
      end,
      { "--native", url }
    )
    if not task or task:start() == false then
      logger.error("Could not start native URL handler")
    end
  end

  local document, reason = native.read(directory .. "/state.json")
  if not document then
    fail("Universal Link interception is not installed: " .. tostring(reason))
    return false
  end
  local decoded, state = pcall(hs.json.decode, document)
  if not decoded or type(state) ~= "table" or type(state.statusPath) ~= "string" then
    fail("invalid Universal Link installation state")
    return false
  end
  local pid
  local function cleanup()
    local saved, issue, code = native.read(directory .. "/state.json")
    local ending = not saved and code == 2
    if saved then
      local ok, phase = pcall(hs.json.decode, saved)
      if not ok or type(phase) ~= "table" or type(phase.statusPath) ~= "string" then
        return false, "invalid Universal Link installation state"
      end
      ending = phase.statusPath == state.statusPath
        and (phase.phase == "uninstalling" or phase.phase == "restored")
    elseif not ending then
      return false, "could not read installation state: " .. tostring(issue)
    end
    if ending then
      ready, failure, pid = false, nil, nil
      if cancel then
        cancel()
        cancel = nil
      end
      if cancelProcess then
        cancelProcess()
        cancelProcess = nil
      end
    end
    return ending
  end
  local starting = true
  local function changed(error)
    if error then
      fail(error)
      return
    end
    local snapshot, readError, code = native.read(state.statusPath)
    if not snapshot then
      if code == 2 then
        local ending, stateError = cleanup()
        if ending then
          return
        elseif stateError then
          fail(stateError)
          return
        end
      end
      if code == 2 and starting then
        ready = false
      else
        fail("could not read interception status: " .. tostring(readError))
      end
      return
    end
    starting = false
    local valid, status = pcall(hs.json.decode, snapshot)
    if not valid or type(status) ~= "table" or status.version ~= 1 then
      fail("invalid interception status")
    elseif status.kind == "error" then
      fail(tostring(status.stage or "interception") .. ": " .. tostring(status.error or "failed"))
    elseif status.kind == "pending" then
      ready = false
    elseif status.kind ~= "ready" then
      fail("invalid interception status kind")
    elseif status.generation == generation then
      if
        status.sha256 ~= current.sha256
        or status.count ~= #actions
        or type(status.pid) ~= "number"
        or status.pid <= 0
        or status.pid > 0x7FFFFFFF
        or status.pid % 1 ~= 0
      then
        fail("interception acknowledgement does not match published selectors")
      else
        if status.pid ~= pid then
          if cancelProcess then
            cancelProcess()
          end
          cancelProcess, readError = native.process(status.pid, "/usr/libexec/swcd", function(cause)
            pid = nil
            local ending, stateError = cleanup()
            if not ending then
              fail(stateError or cause)
            end
          end)
          if not cancelProcess then
            fail("could not watch interception process: " .. tostring(readError))
            return
          end
          pid = status.pid
        end
        ready, failure = true, nil
      end
    else
      ready = false
    end
  end
  cancel, reason = native.watch(state.statusPath, changed)
  if not cancel then
    fail("could not watch interception status: " .. tostring(reason))
    return false
  end
  changed()
  return true
end

return router

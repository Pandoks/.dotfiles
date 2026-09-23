---@class DictationResult
---@field id integer
---@field raw string
---@field text string

---@class DictationEngineHandlers
---@field onReady? fun()
---@field onFinal fun(result: DictationResult)
---@field onError fun(message: string, id?: integer)
---@field onLog? fun(message: string)

---@class DictationTranscribeRequest
---@field wav string
---@field app? string
---@field title? string
---@field url? string
---@field selected? string
---@field cmd? string
---@field id? integer

---@class DictationEngine
---@field task? hs.task
---@field ready boolean
---@field stopped boolean
---@field serial integer
---@field buffer string
local engine = {}
engine.__index = engine
local directory = debug.getinfo(1, "S").source:match("^@(.*/)") or "./"

---@param config DictationConfig
---@param handlers DictationEngineHandlers
---@return DictationEngine?, string?
function engine.new(config, handlers)
  local python = directory .. ".venv/bin/python"
  if not hs.fs.attributes(python) then
    return nil, "backend venv missing; run dictation/setup.sh"
  end
  local self = setmetatable({ ready = false, stopped = false, serial = 0, buffer = "" }, engine)
  local function failure(message)
    if self.stopped then
      return
    end
    self:stop()
    handlers.onError(message)
  end
  local function output(_, stdout, _)
    if self.stopped then
      return true
    end
    self.buffer = self.buffer .. (stdout or "")
    while true do
      local newline = self.buffer:find("\n")
      if not newline then
        break
      end
      local line = self.buffer:sub(1, newline - 1)
      self.buffer = self.buffer:sub(newline + 1)
      if line ~= "" then
        local ok, event = pcall(hs.json.decode, line)
        if not ok or type(event) ~= "table" then
          failure("invalid backend response: " .. line)
          return true
        elseif event.event == "ready" then
          self.ready = true
          if handlers.onReady then
            handlers.onReady()
          end
        elseif event.event == "final" then
          if
            type(event.id) ~= "number"
            or type(event.raw) ~= "string"
            or type(event.text) ~= "string"
          then
            failure("invalid transcription response")
            return true
          end
          handlers.onFinal(event)
        elseif event.event == "error" then
          if event.id then
            handlers.onError(event.msg or "unknown error", event.id)
          else
            failure(event.msg or "unknown error")
          end
        elseif event.event == "log" and handlers.onLog then
          handlers.onLog(event.msg or "")
        end
      end
    end
    return true
  end
  local path = table.concat({
    os.getenv("HOME") .. "/.local/share/mise/installs/ffmpeg/latest/.mise-bins",
    "/opt/homebrew/bin",
    "/usr/local/bin",
    os.getenv("PATH") or "/usr/bin:/bin",
  }, ":")
  local task = hs.task.new(
    "/usr/bin/env",
    function(code, stdout, stderr)
      output(nil, stdout, nil)
      if not self.stopped then
        failure("backend exited (code " .. tostring(code) .. "): " .. (stderr or ""))
      end
    end,
    output,
    {
      "PATH=" .. path,
      "PYTHONUNBUFFERED=1",
      python,
      directory .. "server.py",
      "--config",
      hs.json.encode({
        stt = config.stt,
        cleanup = config.cleanup,
        style = config.style,
        vocabulary = config.vocabulary,
        dictionary = config.dictionary,
        apps = config.apps,
      }),
    }
  )
  if not task then
    return nil, "failed to create backend task"
  end
  self.task = task
  if not task:start() then
    return nil, "failed to start backend"
  end
  return self
end

---@param request DictationTranscribeRequest
---@return integer?, string?
function engine:transcribe(request)
  if not self.ready or self.stopped or not self.task:isRunning() then
    return nil, "backend is not ready"
  end
  self.serial = self.serial + 1
  request.cmd, request.id = "transcribe", self.serial
  self.task:setInput(hs.json.encode(request) .. "\n")
  return self.serial
end

function engine:isReady()
  return self.ready and not self.stopped
end

function engine:stop()
  self.stopped, self.ready = true, false
  if self.task and self.task:isRunning() then
    self.task:terminate()
  end
end

return engine

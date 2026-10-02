local recorder = require("dictation.recorder")

---@class DictationTranscribeRequest
---@field wav string
---@field app? string
---@field title? string
---@field url? string
---@field selected? string
---@field cmd? string
---@field id? integer

---@class DictationEngine
---@field task hs.task
local engine = {}
engine.__index = engine
local directory = debug.getinfo(1, "S").source:match("^@(.*/)")

---@param config DictationConfig
---@param handlers {
---  onFinal: fun(result: { id: integer, text: string, heard?: string }),
---  onError: fun(message: string, id?: integer, heard?: string),
---}
function engine.new(config, handlers)
  local python = directory .. ".venv/bin/python"
  if not hs.fs.attributes(python) then
    return nil, "backend venv missing; run dictation/setup.sh"
  end
  if not recorder.ffmpeg then
    return nil, "ffmpeg not found; run mise install"
  end
  local self =
    setmetatable({ ready = false, stopped = false, serial = 0, buffer = "", errors = "" }, engine)
  local function failure(message)
    if self.stopped then
      return
    end
    self:stop()
    handlers.onError(message)
  end
  -- A handler's error is reported, never raised: an error here would stop hs.task reading the
  -- backend's output, leaving every later take waiting.
  local function call(handler, ...)
    local ok, problem = pcall(handler, ...)
    if not ok then
      print("Dictation: " .. tostring(problem))
      hs.alert.show("Dictation: " .. tostring(problem):match("^[^\n]*"), 5)
    end
  end
  local function output(_, stdout, stderr)
    if self.stopped then
      -- hs.task may deliver the last stderr after the exit callback; keep it in the log.
      if stderr and stderr ~= "" then
        print("Dictation backend: " .. stderr)
      end
      return true
    end
    self.errors = (self.errors .. (stderr or "")):sub(-4000)
    -- Load chatter (progress bars) stays out of the console; what comes later goes in it.
    if self.ready and stderr and stderr ~= "" then
      print("Dictation backend: " .. stderr:gsub("%s+$", ""))
    end
    local buffer = self.buffer .. (stdout or "")
    self.buffer = buffer:match("[^\n]*$") -- a partial line waits for the next chunk
    for line in buffer:gmatch("(.-)\n") do
      if line ~= "" then
        local ok, event = pcall(hs.json.decode, line)
        if not ok or type(event) ~= "table" then
          failure("invalid backend response: " .. line)
          return true
        elseif event.event == "ready" then
          -- Load chatter (HF warnings, progress bars) is no crash reason.
          self.ready, self.errors = true, ""
          print("Dictation: backend ready")
        elseif event.event == "final" then
          if type(event.id) ~= "number" or type(event.text) ~= "string" then
            failure("invalid transcription response")
            return true
          end
          call(handlers.onFinal, event)
        elseif event.event == "error" then
          if event.id then
            local heard = type(event.heard) == "string" and event.heard or nil
            call(handlers.onError, event.msg or "unknown error", event.id, heard)
          else
            failure(event.msg or "unknown error")
          end
        elseif event.event == "log" then
          print("Dictation backend: " .. (event.msg or ""))
        else
          -- Not one this client knows: a take waiting on it would never end.
          failure("unknown backend event: " .. line)
          return true
        end
      end
    end
    return true
  end
  local task = hs.task.new(
    "/usr/bin/env",
    function(code, stdout, stderr)
      output(nil, stdout, stderr)
      if not self.stopped then
        -- The last stderr line goes in the popup: an exception's, or whatever was printed last.
        local reason = self.errors:match("([^\n]*%S)%s*$")
        local exit = "backend exited (code " .. tostring(code) .. ")"
        failure(reason and exit .. "; last output: " .. reason .. "\n" .. self.errors or exit)
      end
    end,
    output,
    {
      "PATH=" .. recorder.ffmpeg:match("^(.*)/") .. ":" .. os.getenv("PATH"),
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

function engine:stop()
  self.stopped, self.ready = true, false
  if self.task:isRunning() then
    self.task:terminate()
  end
end

return engine

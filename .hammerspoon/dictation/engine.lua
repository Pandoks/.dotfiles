local recorder = require("dictation.recorder")

---@class DictationEngine
---@field task hs.task
---@field sending? integer the request the backend has, answered before the next is sent
---@field queued { id: integer, line: string }[]
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
  local self = setmetatable(
    { ready = false, stopped = false, serial = 0, buffer = "", errors = "", queued = {} },
    engine
  )
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
  -- The next request goes once the last is answered: hs.task:setInput discards what it has not
  -- written yet when called again, and a busy backend leaves it unwritten in a full pipe.
  local function answered(id)
    if id ~= self.sending then
      return
    end
    local queued = table.remove(self.queued, 1)
    self.sending = queued and queued.id
    if queued then
      self.task:setInput(queued.line)
    end
  end
  local function output(_, stdout, stderr)
    stderr = stderr or ""
    -- Load chatter (progress bars) stays out of the console; later output, even past exit, goes in.
    if stderr ~= "" and (self.ready or self.stopped) then
      print("Dictation backend: " .. stderr:gsub("\n$", ""))
    end
    if self.stopped then
      return true
    end
    self.errors = (self.errors .. stderr):sub(-4000)
    local buffer = self.buffer .. (stdout or "")
    self.buffer = buffer:match("[^\n]*$") -- a partial line waits for the next chunk
    for line in buffer:gmatch("(.-)\n") do
      if line ~= "" then
        local event = hs.json.decode(line)
        if type(event) ~= "table" then
          failure("invalid backend response: " .. line)
          return true
        elseif event.event == "ready" then
          -- Load chatter (HF warnings, progress bars) is no crash reason.
          self.ready, self.errors = true, ""
          print("Dictation: backend ready")
        elseif event.event == "final" then
          answered(event.id)
          call(handlers.onFinal, event)
        elseif event.event == "error" then
          if event.id then
            answered(event.id)
            call(handlers.onError, event.msg or "unknown error", event.id, event.heard)
          else
            -- A failed load: its traceback is in what it printed.
            failure((event.msg or "unknown error") .. "\n" .. self.errors)
          end
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
      hs.json.encode({
        speech = config.speech,
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

-- Queue `wav`, recorded with app `app` in front; its id, or nil and why not.
---@param wav string
---@param app string?
---@return integer?, string?
function engine:transcribe(wav, app)
  if not self.ready or self.stopped or not self.task:isRunning() then
    return nil, "backend is not ready"
  end
  self.serial = self.serial + 1
  local line = hs.json.encode({ id = self.serial, wav = wav, app = app }) .. "\n"
  if self.sending then
    self.queued[#self.queued + 1] = { id = self.serial, line = line }
  else
    self.sending = self.serial
    self.task:setInput(line)
  end
  return self.serial
end

function engine:stop()
  self.stopped, self.ready = true, false
  if self.task:isRunning() then
    self.task:terminate()
  end
end

return engine

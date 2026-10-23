local recorder = require("dictation.recorder")

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
  local settings = hs.json.encode(config)
  if not settings then
    return nil, "config.lua holds a value JSON cannot encode (inf, nan, or a function)"
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
  -- A raise here stops hs.task's later replies; so does hs.ipc's print with a dead `hs` CLI.
  local function call(handler, ...)
    local ok, problem = pcall(handler, ...)
    if not ok then
      hs.alert.show("Dictation: " .. tostring(problem):match("^[^\n]*"), 5)
      pcall(print, "Dictation: " .. tostring(problem))
    end
  end
  -- One request at a time: a second setInput drops what the full pipe has not taken yet.
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
      pcall(print, "Dictation backend: " .. stderr:gsub("\n$", ""))
    end
    if self.stopped then
      return true
    end
    self.errors = (self.errors .. stderr):sub(-4000)
    -- Anchored and greedy, so one pass however long the line: an unanchored match is quadratic.
    local buffer = self.buffer .. (stdout or "")
    local lines, partial = buffer:match("^(.*\n)(.*)$")
    self.buffer = partial or buffer
    for line in (lines or ""):gmatch("[^\n]+") do
      local event = hs.json.decode(line)
      if type(event) ~= "table" then
        failure("invalid backend response: " .. line)
        return true
      elseif event.event == "ready" then
        -- Load chatter (HF warnings, progress bars) is no crash reason.
        self.ready, self.errors = true, ""
        pcall(print, "Dictation: backend ready")
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
    return true
  end
  self.task = hs.task.new(
    "/usr/bin/env",
    function(code, stdout, stderr)
      output(nil, stdout, stderr)
      -- The last stderr line goes in the popup: an exception's, or whatever was printed last.
      local reason = self.errors:match("([^\n]*%S)%s*$")
      local exit = "backend exited (code " .. tostring(code) .. ")"
      failure(reason and exit .. "; last output: " .. reason .. "\n" .. self.errors or exit)
    end,
    output,
    {
      -- mlx-whisper reads the wav with the ffmpeg CLI.
      "PATH=" .. recorder.ffmpeg:match("^(.*)/") .. ":" .. os.getenv("PATH"),
      "PYTHONUNBUFFERED=1",
      python,
      directory .. "server.py",
      settings,
    }
  )
  if not self.task:start() then
    return nil, "failed to start backend"
  end
  return self
end

---@param wav string
---@param app string?
function engine:transcribe(wav, app)
  if not self.ready or not self.task:isRunning() then
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

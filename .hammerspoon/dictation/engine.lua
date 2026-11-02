local logger = require("lib.logger")

local engine = {}
engine.__index = engine
local directory = debug.getinfo(1, "S").source:match("^@(.*/)")

---@param config DictationConfig
---@param handlers {
---  onFinal: fun(result: { id: integer, text: string }),
---  onError: fun(message: string, id?: integer, heard?: string),
---}
function engine.new(config, handlers)
  local python = directory .. ".venv/bin/python"
  if not hs.fs.attributes(python) then
    return nil, "backend venv missing; run uv sync --locked --project ~/.hammerspoon/dictation"
  end
  local settings = hs.json.encode(config)
  if not settings then
    return nil, "a config.lua value JSON cannot encode (inf, nan, or a function)"
  end
  -- Per-user 0700 temp dir; ffmpeg streams each take here while it records.
  local socket = hs.fs.temporaryDirectory() .. "dictation-" .. hs.host.uuid() .. ".sock"
  local self = setmetatable({
    ready = false,
    stopped = false,
    serial = 0,
    buffer = "",
    errors = "",
    queued = {},
    socket = socket,
  }, engine)
  local function failure(message)
    if self.stopped then
      return
    end
    self:stop()
    handlers.onError(message)
  end
  -- A raise here stops hs.task's later replies.
  local function call(handler, ...)
    local ok, problem = pcall(handler, ...)
    if not ok then
      logger.error("Dictation: " .. tostring(problem))
    end
  end
  local function output(_, stdout, stderr)
    stderr = stderr or ""
    -- Load chatter (progress bars) stays out of the console.
    if stderr ~= "" and (self.ready or self.stopped) then
      pcall(print, "Dictation backend: " .. stderr:gsub("\n$", ""))
    end
    if self.stopped then
      return true
    end
    self.errors = (self.errors .. stderr):sub(-4000)
    -- Anchored: an unanchored match is quadratic on a long line.
    local buffer = self.buffer .. (stdout or "")
    local lines, partial = buffer:match("^(.*\n)(.*)$")
    self.buffer = partial or buffer
    for line in (lines or ""):gmatch("[^\n]+") do
      local event = hs.json.decode(line)
      if type(event) ~= "table" then
        failure("invalid response: " .. line)
        return true
      elseif event.event == "ready" then
        -- Load chatter is no crash reason.
        self.ready, self.errors = true, ""
        pcall(print, "Dictation: backend ready")
      elseif event.event == "received" then
        -- One at a time: a second setInput drops what hs.task hasn't written yet.
        self.sending = table.remove(self.queued, 1)
        if self.sending then
          self.task:setInput(self.sending)
        end
      elseif event.event == "final" then
        call(handlers.onFinal, event)
      elseif event.event == "error" then
        if event.id then
          call(handlers.onError, event.msg or "unknown error", event.id, event.heard)
        else
          -- A failed load: its traceback is in what it printed.
          failure((event.msg or "unknown error") .. "\n" .. self.errors)
        end
      else
        -- A take waiting on an unknown event would never end.
        failure("unknown event: " .. line)
        return true
      end
    end
    return true
  end
  self.task = hs.task.new(python, function(code, stdout, stderr)
    output(nil, stdout, stderr)
    -- The last stderr line, an exception's if any, goes in the popup.
    local reason = self.errors:match("([^\n]*%S)%s*$")
    local exit = self.task:terminationReason() == "interrupt" and "killed by signal " .. code
      or "exited (code " .. code .. ")"
    failure(reason and exit .. "; last output: " .. reason .. "\n" .. self.errors or exit)
  end, output, { directory .. "server.py", settings, socket })
  if not self.task:start() then
    return nil, "could not start the backend"
  end
  return self
end

---@param self table
---@param request { id: integer, pid?: integer, app?: string, wav?: string }
local function send(self, request)
  if not self.ready or not self.task:isRunning() then
    return nil, "backend is not ready"
  end
  local line = hs.json.encode(request) .. "\n"
  if self.sending then
    self.queued[#self.queued + 1] = line
  else
    self.sending = line
    self.task:setInput(line)
  end
  return request.id
end

-- A take records from ffmpeg `pid`, which streams it to `engine.socket`.
---@param pid integer
---@param app string?
function engine:start(pid, app)
  self.serial = self.serial + 1
  return send(self, { id = self.serial, pid = pid, app = app })
end

-- Take `id` stopped; `wav` holds the audio it streamed.
---@param id integer
---@param wav string
function engine:transcribe(id, wav)
  return send(self, { id = id, wav = wav })
end

function engine:stop()
  self.stopped, self.ready = true, false
  if self.task:isRunning() then
    self.task:terminate()
  end
  os.remove(self.socket)
end

return engine

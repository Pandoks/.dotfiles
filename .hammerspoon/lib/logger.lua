local toast = require("lib.toast")

---@class Logger
local logger = {}

local consolePrint = print
local directory = os.getenv("HOME") .. "/Library/Logs/Hammerspoon"

logger.path = directory .. "/config.log"

---@param message string
function logger.error(message)
  -- hs.ipc's print raises while a dead `hs` CLI is registered.
  pcall(print, message)
  toast.show(message:match("[^\n]+") or message, { failure = true, seconds = 5 })
end

function logger.install()
  local function failure(message)
    print = consolePrint
    logger.error("Could not write Hammerspoon file log: " .. tostring(message))
  end
  if not hs.fs.attributes(directory) then
    local created, message = hs.fs.mkdir(directory)
    if not created then
      failure(message or "could not create log directory")
      return
    end
  end

  print = function(...)
    local values = table.pack(...)
    for index = 1, values.n do
      values[index] = tostring(values[index])
    end

    local file, message = io.open(logger.path, "a")
    if not file then
      failure(message or "could not open log")
    else
      local timestamp = os.date("%Y-%m-%d %H:%M:%S") --[[@as string]]
      local written, writeError = file:write(timestamp, "\t", table.concat(values, "\t"), "\n")
      local closed, closeError = file:close()
      if not written or not closed then
        failure(writeError or closeError or "could not flush log")
      end
    end

    return consolePrint(table.unpack(values, 1, values.n))
  end
end

---@return Logger
return logger

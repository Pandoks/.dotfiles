local logger = {}
local consolePrint = print
local logDirectory = os.getenv("HOME") .. "/Library/Logs/Hammerspoon"

local failurePrefix = "Could not write Hammerspoon file log: "

logger.path = logDirectory .. "/config.log"

function logger.install()
  if not hs.fs.attributes(logDirectory) then
    local created, errorMessage = hs.fs.mkdir(logDirectory)
    if not created then
      consolePrint(failurePrefix .. (errorMessage or "could not create log directory"))
      return
    end
  end

  print = function(...)
    local values = table.pack(...)
    for index = 1, values.n do
      values[index] = tostring(values[index])
    end

    local file, errorMessage = io.open(logger.path, "a")
    if not file then
      consolePrint(failurePrefix .. (errorMessage or "unknown error"))
    else
      local timestamp = os.date("%Y-%m-%d %H:%M:%S") --[[@as string]]
      file:write(timestamp, "\t", table.concat(values, "\t"), "\n")
      file:close()
    end

    return consolePrint(table.unpack(values, 1, values.n))
  end
end

return logger

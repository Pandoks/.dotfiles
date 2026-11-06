local logger = require("lib.logger")
local module = {}
local dock, element, failure, deadline
local stopped = false

-- No app watcher reports the Dock relaunching, so each read checks the attached one still runs.
local function attached()
  if not (dock and dock:isRunning()) then
    dock = hs.application.applicationsForBundleID("com.apple.dock")[1]
    element, failure = dock and hs.axuielement.applicationElement(dock), nil
    deadline = hs.timer.secondsSinceEpoch() + 1
  end
  return element ~= nil
end

-- macOS 27 posts no Dock AXExpose notifications.
function module.isActive()
  if stopped or not attached() then
    return false
  end
  assert(not failure, failure)
  local children, message = element:attributeValue("AXChildren")
  if type(children) ~= "table" then
    -- A relaunched Dock can't answer for its first moments.
    if hs.timer.secondsSinceEpoch() < deadline then
      return false
    end
    failure = "Mission Control: " .. tostring(message or "Dock children unavailable")
    logger.error(failure)
    error(failure, 0)
  end
  deadline = 0
  for _, child in ipairs(children) do
    if child:attributeValue("AXIdentifier") == "mc" then
      return true
    end
  end
  return false
end

attached()
deadline = 0

function module.stop()
  stopped = true
  dock, element, failure = nil, nil, nil
end

return module

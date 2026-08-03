-- Focuses a window matching the profile, spawning it if none exists.
-- Handles both whole apps (no match = any window of the app) and specific
-- windows (match by forced title or custom function).
local YABAI = "/opt/homebrew/bin/yabai"

---@param profile WindowProfile
local function openOrFocusWindow(profile)
  local matches = profile.match
  if type(matches) ~= "function" then
    local title = matches
    ---@param window YabaiWindow
    matches = function(window)
      return title == nil or window.title == title
    end
  end

  local output = hs.execute(YABAI .. " -m query --windows")
  local ok, windows = pcall(hs.json.decode, output)
  if not ok or type(windows) ~= "table" then
    print("Failed to query yabai windows")
    return
  end
  ---@cast windows YabaiWindow[]

  -- current space = space of the focused window; nil on an empty space, where
  -- the preference below can't apply anyway
  local currentSpace = nil
  for _, window in ipairs(windows) do
    if window["has-focus"] then
      currentSpace = window.space
      break
    end
  end

  -- prefer a matching window on the current space, otherwise take  first match
  ---@type YabaiWindow?
  local found = nil
  for _, window in ipairs(windows) do
    if window.app == profile.app and matches(window) then
      if window.space == currentSpace then
        found = window
        break
      end
      found = found or window
    end
  end

  if found then
    -- also unhides the app if it was hidden
    hs.execute(YABAI .. " -m window --focus " .. tostring(found.id))
    print("Focused window", profile.app, found.id)
    return
  end

  if profile.space then
    hs.execute(YABAI .. " -m space --focus " .. tostring(profile.space))
    print("Focused space", profile.space)
  end
  hs.task.new("/usr/bin/open", nil, profile.spawn):start()
  print("Spawned window", profile.app)
end

return openOrFocusWindow

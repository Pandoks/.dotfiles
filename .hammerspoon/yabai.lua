local function yabai(args)
  -- Runs fast as fuck in background
  hs.task
    .new("/opt/homebrew/bin/yabai", nil, function(_, ...)
      print("stream", hs.inspect(table.pack(...)))
      return true
    end, args)
    :start()
end

-- toggle window float
hs.hotkey.bind({ "shift", "alt" }, "f", function()
  yabai({ "-m", "window", "--toggle", "float" })
end)

-- maximize window
hs.hotkey.bind({ "alt" }, "return", function()
  yabai({ "-m", "window", "--toggle", "zoom-fullscreen" })
end)

local directions = { ["north"] = "k", ["south"] = "j", ["east"] = "l", ["west"] = "h" }
for direction, key in pairs(directions) do
  -- change window focus within space
  hs.hotkey.bind({ "alt" }, key, function()
    yabai({ "-m", "window", "--focus", direction })
  end)

  -- move window around within space
  hs.hotkey.bind({ "shift", "alt" }, key, function()
    yabai({ "-m", "window", "--swap", direction })
  end)

  -- warp window around within space
  hs.hotkey.bind({ "ctrl", "alt" }, key, function()
    yabai({ "-m", "window", "--warp", direction })
  end)
end

for i = 1, 7 do
  local number = tostring(i)

  -- move to space
  hs.hotkey.bind({ "alt" }, number, function()
    yabai({ "-m", "space", "--focus", number })
  end)

  -- move window to space
  hs.hotkey.bind({ "shift", "alt" }, number, function()
    yabai({ "-m", "window", "--space", number })
    yabai({ "-m", "space", "--focus", number })
  end)
end
-- move to fullscreened space
hs.hotkey.bind({ "alt" }, "8", function()
  yabai({ "-m", "space", "--focus", "8" })
end)

-- starting and stopping yabai
hs.hotkey.bind({ "ctrl", "alt" }, "q", function()
  yabai({ "--stop-service" })
  hs.alert.show("yabai stopped", 2)
end)
hs.hotkey.bind({ "ctrl", "alt" }, "s", function()
  hs.execute("/opt/homebrew/bin/yabai --start-service")
  hs.alert.show("yabai started", 2)
end)
hs.hotkey.bind({ "ctrl", "alt" }, "r", function()
  yabai({ "--restart-service" })
  hs.alert.show("yabai restarted", 2)
end)

-- notifies when yabai starts
hs.timer.waitUntil(function()
  local yabai_app = hs.application.get("yabai")
  return yabai_app
end, function()
  hs.alert.show("yabai started", 2)
end, 1)
return yabai

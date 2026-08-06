local openOrFocusWindow = require("window_profiles")

NeedsToBeHidden = nil
-- needs to be a global variable or else it will get garbage collected and lose scope
ApplicationWatcher = hs.application.watcher.new(function(app, event, object)
  -- deactivated will happen before unhidden event when switching between 2 apps
  if event == hs.application.watcher.deactivated and app == NeedsToBeHidden then
    object:hide()
    NeedsToBeHidden = nil
    print("Hid", app)
  elseif event == hs.application.watcher.unhidden then
    NeedsToBeHidden = app
    print("Set hidden toggle", app)
  end
end)
ApplicationWatcher:start()

hs.hotkey.bind({ "cmd", "shift" }, "h", function()
  NeedsToBeHidden = nil
  print("Clear hidden toggle")
end)

hs.hotkey.bind({ "alt" }, "s", function()
  openOrFocusWindow({ bundleId = "net.imput.helium" })
end)
hs.hotkey.bind({ "alt" }, "n", function()
  openOrFocusWindow({ bundleId = "com.apple.MobileSMS" })
end)
hs.hotkey.bind({ "alt" }, "b", function()
  openOrFocusWindow({ bundleId = "com.bambulab.bambu-studio" })
end)
hs.hotkey.bind({ "alt" }, "p", function()
  openOrFocusWindow({ bundleId = "me.proton.pass.electron" })
end)
hs.hotkey.bind({ "alt" }, "w", function()
  openOrFocusWindow({ bundleId = "com.tinyspeck.slackmacgap" })
end)
hs.hotkey.bind({ "alt" }, "q", function()
  openOrFocusWindow({ bundleId = "notion.id" })
end)
hs.hotkey.bind({ "alt" }, "i", function()
  openOrFocusWindow({ bundleId = "com.t3tools.t3code" })
end)
hs.hotkey.bind({ "alt" }, "v", function()
  openOrFocusWindow({ bundleId = "com.blackmagic-design.DaVinciResolve" })
end)

local chromium = require("lib.window_adapters.chromium")
local openOrFocusWindow = require("window_profiles")

local personal = chromium.window({ bundleID = "net.imput.helium", profile = "Personal" })
local work = chromium.window({ bundleID = "net.imput.helium", profile = "Work" })

NeedsToBeHiddenPids = {}
ApplicationWatcher = hs.application.watcher.new(function(_, event, application)
  if not application then
    return
  end
  local pid = application:pid()
  local bundleId = application:bundleID()

  if event == hs.application.watcher.deactivated and NeedsToBeHiddenPids[pid] then
    application:hide()
    NeedsToBeHiddenPids[pid] = nil
    print("Hid", bundleId)
  elseif event == hs.application.watcher.unhidden then
    NeedsToBeHiddenPids[pid] = true
    print("Set hidden toggle", bundleId)
  end
end)
ApplicationWatcher:start()

hs.hotkey.bind({ "cmd", "shift" }, "h", function()
  local app = hs.application.frontmostApplication()
  if app then
    NeedsToBeHiddenPids[app:pid()] = nil
    print("Clear hidden toggle", app:bundleID())
  end
end)

hs.hotkey.bind({ "alt" }, "s", function()
  openOrFocusWindow(personal)
end)
hs.hotkey.bind({ "alt" }, "a", function()
  openOrFocusWindow(work)
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
hs.hotkey.bind({ "alt" }, "c", function()
  openOrFocusWindow({ bundleId = "com.cron.electron" }) -- Notion Calendar
end)
hs.hotkey.bind({ "alt" }, "i", function()
  openOrFocusWindow({ bundleId = "com.t3tools.t3code" })
end)
hs.hotkey.bind({ "alt" }, "v", function()
  openOrFocusWindow({ bundleId = "com.blackmagic-design.DaVinciResolve" })
end)
hs.hotkey.bind({ "alt" }, "o", function()
  openOrFocusWindow({ bundleId = "com.anysphere.sand" }) -- Grok Bot
end)

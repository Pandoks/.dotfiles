local chromium = require("lib.window_adapters.chromium")
local router = require("lib.url_router")

local work = chromium.url({ bundleID = "net.imput.helium", profile = "Work" })
local personal = chromium.url({ bundleID = "net.imput.helium", profile = "Personal" })

return router.install({
  { host = "ramp.com", open = work },
  { pattern = "^https?://app%.notion%.com/p/sieve%-data/", open = work },
  -- Every other Notion app link opens in the browser, not the Notion app.
  { host = "app.notion.com", open = personal },
  { host = "www.notion.so", open = personal },
})

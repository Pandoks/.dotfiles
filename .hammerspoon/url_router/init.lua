local chromium = require("lib.window_adapters.chromium")
local notion = require("lib.url_router.notion")
local router = require("lib.url_router")

local work = chromium.url({ bundleID = "net.imput.helium", profile = "Work" })
local personal = chromium.url({ bundleID = "net.imput.helium", profile = "Personal" })

-- Notion links open in the browser by workspace, never in the Notion app.
local workspaces = notion.url({
  workspaces = { ["sieve-data"] = work },
  default = personal,
  lookup = true, -- ask Notion which workspace owns links that only have a page ID
})

return router.install({
  { host = "ramp.com", open = work },
  { host = "app.notion.com", open = workspaces },
  { host = "www.notion.so", open = workspaces },
})

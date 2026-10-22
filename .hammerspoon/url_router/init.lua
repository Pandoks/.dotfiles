local chromium = require("lib.window_adapters.chromium")
local notion = require("lib.url_adapters.notion")
local router = require("lib.url_router")

local work = chromium.url({ bundleID = "net.imput.helium", profile = "Work" })
local personal = chromium.url({ bundleID = "net.imput.helium", profile = "Personal" })

-- Notion opens in the browser by workspace, never in the Notion app.
local workspace = notion.workspace({ lookup = true }) -- `lookup` resolves page-ID-only links
local notionLinks = router.by(workspace, { ["sieve-data"] = work }, personal)

return router.install({
  { host = "ramp.com", open = work },
  { host = "app.notion.com", open = notionLinks },
  { host = "www.notion.so", open = notionLinks },
})

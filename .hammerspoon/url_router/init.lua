local chromium = require("lib.window_adapters.chromium")
local notion = require("lib.url_adapters.notion")
local router = require("lib.url_router")

local work = chromium.url({ bundleID = "net.imput.helium", profile = "Work" })
local personal = chromium.url({ bundleID = "net.imput.helium", profile = "Personal" })

-- Notion opens in the browser by workspace, never in the Notion app.
local workspace = notion.workspace({ lookup = true }) -- `lookup` resolves page-ID-only links
local notionLinks = router.by(workspace, { ["sieve-data"] = work }, personal)

return router.install({
  { host = "sieve.ai", open = work },
  { host = "sieve.ghost.io", open = work },
  { host = "sieve.atlasgo.cloud", open = work },
  { host = "sieve-data.notion.site", open = work },
  { host = "sievehq.slack.com", open = work },
  { pattern = "sievedata%.com", open = work }, -- the work account in a sign-in or `authuser` link
  { pattern = "^https://github%.com/sieve%-data/", open = work },
  { pattern = "^https://github%.com/orgs/sieve%-data/", open = work },
  { pattern = "^https://linear%.app/sieve/", open = work },
  { pattern = "^https://vercel%.com/sieve/", open = work },
  { pattern = "^https://console%.cloud%.google%.com/[^#]*[?&]project=sieve%-", open = work },

  -- Services only ever signed in to with the work account.
  { host = "ramp.com", open = work },
  { host = "rippling.com", open = work },
  { host = "app.ashbyhq.com", open = work },
  { host = "you.ashbyhq.com", open = work },
  { host = "console.runpod.io", open = work },

  { host = "notion.so", open = notionLinks },
  { host = "notion.com", open = notionLinks },
})

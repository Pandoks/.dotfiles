local logger = require("lib.logger")
local notion = {}

---@alias URLAction fun(url: string, report?: fun(message: string)): boolean

---@class NotionLinks
---@field workspaces table<string, URLAction> workspace domain, as in `app.notion.com/p/<domain>/`
---@field default URLAction other workspaces
---@field lookup? boolean ask Notion which workspace owns links that only have a page ID

---@param options NotionLinks
---@return URLAction
function notion.url(options)
  return function(url, report)
    report = report or logger.error
    local path = url:match("^%a[%w+.-]*://[^/?#]+(/[^?#]*)") or "/"
    local segment = (path:gsub("^/p/", "/")):match("^/([^/]+)")
    local page = segment and segment:match("(" .. string.rep("%x", 32) .. ")$")
    if not page then
      return (options.workspaces[segment] or options.default)(url, report)
    elseif not options.lookup then
      return options.default(url, report)
    end

    -- Notion only resolves dashed page IDs.
    local id = page:gsub("^(........)(....)(....)(....)", "%1-%2-%3-%4-")
    local task = hs.task.new("/usr/bin/curl", function(code, output, message)
      local decoded, data = pcall(hs.json.decode, output)
      if code ~= 0 or not decoded or type(data) ~= "table" then
        report("Notion workspace lookup failed: " .. (code ~= 0 and message or "invalid response"))
        return
      end
      if not (options.workspaces[data.spaceDomain] or options.default)(url, report) then
        report("Notion link action failed")
      end
    end, {
      "--silent",
      "--show-error",
      "--fail",
      "--max-time",
      "3",
      "--header",
      "Content-Type: application/json",
      "--data",
      '{"type":"block-space","name":"page","blockId":"' .. id .. '"}',
      "https://app.notion.com/api/v3/getPublicPageData",
    })
    return task ~= nil and task:start() ~= false
  end
end

return notion

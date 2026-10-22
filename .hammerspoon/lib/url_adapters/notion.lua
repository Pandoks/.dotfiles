local notion = {}

---Finds a Notion link's workspace domain, as in `app.notion.com/p/<domain>/`.
---@param options { lookup?: boolean } `lookup` asks Notion which workspace owns links that only have a page ID
---@return fun(url: string, done: fun(workspace?: string, error?: string))
function notion.workspace(options)
  return function(url, done)
    local path = url:match("^%a[%w+.-]*://[^/?#]+(/[^?#]*)") or "/"
    local segment = (path:gsub("^/p/", "/")):match("^/([^/]+)")
    local page = segment and segment:match("(" .. string.rep("%x", 32) .. ")$")
    if not page then
      done(segment)
      return
    elseif not options.lookup then
      done()
      return
    end

    -- Notion only resolves lowercase, dashed page IDs.
    local id = page:lower():gsub("^(........)(....)(....)(....)", "%1-%2-%3-%4-")
    local task = hs.task.new("/usr/bin/curl", function(code, output, message)
      local decoded, data = pcall(hs.json.decode, output)
      if code ~= 0 or not decoded or type(data) ~= "table" then
        done(
          nil,
          "Notion workspace lookup failed: " .. (code ~= 0 and message or "invalid response")
        )
      elseif type(data.spaceDomain) ~= "string" then
        done(nil, "Notion workspace lookup failed: no workspace for this page")
      else
        done(data.spaceDomain)
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
    if not task or task:start() == false then
      done(nil, "Could not start the Notion workspace lookup")
    end
  end
end

return notion

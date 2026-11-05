---@param rules { host?: string, pattern?: string }[]
---@param url string
---@param host string?
---@param scheme string?
---@return integer index -1 invalid, 0 unmatched
---@return string? error
return function(rules, url, host, scheme)
  if
    type(url) ~= "string"
    or type(host) ~= "string"
    or host == ""
    or not (scheme or ""):lower():match("^https?$")
  then
    return -1, "invalid HTTP URL"
  end

  host = host:lower():gsub("%.$", "")
  for index, rule in ipairs(rules) do
    if rule.host and (host == rule.host or host:sub(-#rule.host - 1) == "." .. rule.host) then
      return index
    elseif rule.pattern then
      local ok, matched = pcall(string.match, url, rule.pattern)
      if not ok then
        return -1, matched
      elseif matched then
        return index
      end
    end
  end
  return 0
end

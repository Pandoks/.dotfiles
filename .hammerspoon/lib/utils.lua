---@class UtilityModule
local utils = {}

---@class ManagedSpace
---@field ManagedSpaceID integer native CGS id (`hs.spaces.focusedSpace()`)
---@field id64 integer same id as `ManagedSpaceID` in practice
---@field type integer 0 = user, 4 = fullscreen
---@field uuid string empty for some Spaces (often the first)

---@return ManagedSpace[]? spaces 1-based; `spaces[i]` is Mission Control index `i`
---@return string? errorMessage
function utils.spaces()
  local data, err = hs.spaces.data_managedDisplaySpaces()
  if type(data) ~= "table" then
    return nil, err or "could not read managed Spaces"
  end

  ---@type ManagedSpace[]
  local result = {}
  for _, display in ipairs(data) do
    for _, space in ipairs(display.Spaces or {}) do
      result[#result + 1] = space
    end
  end

  return result
end

---@return UtilityModule
return utils

---@class Glass
---@field hide fun(self: Glass, fadeSeconds: number)
---@field paint fun(self: Glass, darkAppearance: boolean, tint: number)

---@alias GlassTint { light: number, dark: number } White over light glass, black over dark; 0 to 1.

-- Liquid Glass under a canvas, its child window.
---@class GlassNative
---@field new fun(canvas: hs.canvas, cornerRadius: number, fadeSeconds: number, darkAppearance: boolean, tint: number): Glass
local glass = require("lib.utils").native("glass") --[[@as GlassNative]]

---@type GlassTint
glass.tint = { light = 0.5, dark = 0.6 }

---@param tint any
---@return string? problem nil for a GlassTint
function glass.problem(tint)
  for _, appearance in ipairs({ "light", "dark" }) do
    local alpha = type(tint) == "table" and tint[appearance] or nil
    if type(alpha) ~= "number" or not (alpha >= 0 and alpha <= 1) then
      return ("tint.%s is %s; use 0 to 1"):format(appearance, tostring(alpha))
    end
  end
end

return glass

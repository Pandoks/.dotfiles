---@class Glass
---@field hide fun(self: Glass, fadeSeconds: number)
---@field paint fun(self: Glass, darkAppearance: boolean)

-- Liquid Glass under a canvas, its child window.
---@class GlassNative
---@field new fun(canvas: hs.canvas, cornerRadius: number, fadeSeconds: number, darkAppearance: boolean): Glass

return require("lib.utils").native("glass") --[[@as GlassNative]]

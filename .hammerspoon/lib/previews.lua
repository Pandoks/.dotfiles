---@class PreviewNative
---@field capture fun(windows: { id: integer, pid: integer }[], done: fun(id: integer?, image: hs.image?, errorMessage?: string)): fun()

require("hs.image") -- Register the native image converter.
return require("lib.utils").native("previews") --[[@as PreviewNative]]

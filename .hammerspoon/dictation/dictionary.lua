-- Explicit spoken variants for stubborn mishearings the fuzzy `vocabulary`
-- match cannot reach (e.g. "meez" for mise). Word -> variants, replaced
-- case-insensitively at word boundaries before and after cleanup. Most words
-- belong in `vocabulary` in config.lua, not here.
---@type table<string, string[]>
return {
  Raycast = { "ray cast", "re cast", "ray cost" },
  yabai = { "yabe", "ya bye", "yah bye", "ya buy" },
  Hammerspoon = { "hammer spoon", "hammers spoon" },
  Ghostty = { "ghosty", "ghost tea", "ghost e" },
  mise = { "meez", "mees" },
  Neovim = { "neo vim", "neo them" },
  rtorrent = { "r torrent", "are torrent" },
  macOS = { "mac os", "mac o s" },
  GitHub = { "git hub" },
}

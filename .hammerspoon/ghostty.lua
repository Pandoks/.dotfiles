local openOrFocusWindow = require("window_profiles")

---@param title string forced window title -- also the profile's exact-match identity
---@param command string command the window runs (its lifetime = the window's)
---@return WindowProfile
local function ghosttyProfile(title, command)
  return {
    bundleId = "com.mitchellh.ghostty",
    match = title,
    args = {
      "--title=" .. title,
      "--window-save-state=never",
      "--quit-after-last-window-closed-delay=1s",
      "--command=" .. command,
    },
  }
end

hs.hotkey.bind({ "alt" }, "e", function()
  openOrFocusWindow(
    ghosttyProfile("sieve", [[ssh -t sieve "/bin/zsh -lc 'exec tmux new-session -A -s Sieve'"]])
  )
end)
hs.hotkey.bind({ "alt" }, "r", function()
  openOrFocusWindow(ghosttyProfile("dev", "ssh -t dev tmux new-session -A -s Dev"))
end)
hs.hotkey.bind({ "alt" }, "t", function()
  openOrFocusWindow(ghosttyProfile("local", [[/bin/zsh -lc 'exec tmux new-session -A -s Pandoks']]))
end)

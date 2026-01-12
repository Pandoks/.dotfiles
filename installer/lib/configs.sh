# shellcheck shell=sh

install_configs() {
  create_symlink "${REPO_ROOT}/.aws/config" "${HOME}/.aws/config"

  create_symlink "${REPO_ROOT}/.config/btop" "${HOME}/.config/btop"
  create_symlink "${REPO_ROOT}/.config/fastfetch" "${HOME}/.config/fastfetch"
  create_symlink "${REPO_ROOT}/.config/gh" "${HOME}/.config/gh"
  create_symlink "${REPO_ROOT}/.config/ghostty" "${HOME}/.config/ghostty"
  create_symlink "${REPO_ROOT}/.config/k9s" "${HOME}/.config/k9s"
  create_symlink "${REPO_ROOT}/.config/lazydocker" "${HOME}/.config/lazydocker"
  create_symlink "${REPO_ROOT}/.config/lazygit" "${HOME}/.config/lazygit"
  create_symlink "${REPO_ROOT}/.config/nvim" "${HOME}/.config/nvim"
  create_symlink "${REPO_ROOT}/.config/opencode" "${HOME}/.config/opencode"
  create_symlink "${REPO_ROOT}/.config/yabai" "${HOME}/.config/yabai"

  create_symlink "${REPO_ROOT}/.hammerspoon" "${HOME}/.hammerspoon"

  create_symlink "${REPO_ROOT}/.local/bin/tailscale-startup.sh" "${HOME}/.local/bin/tailscale-startup.sh"
  create_symlink "${REPO_ROOT}/Library/LaunchAgents/com.tailscale.startup.plist" "${HOME}/Library/LaunchAgents/com.tailscale.startup.plist"

  create_symlink "${REPO_ROOT}/.fzf.zsh" "${HOME}/.fzf.zsh"
  create_symlink "${REPO_ROOT}/.fzfignore" "${HOME}/.fzfignore"
  create_symlink "${REPO_ROOT}/.gitconfig" "${HOME}/.gitconfig"
  create_symlink "${REPO_ROOT}/.p10k.zsh" "${HOME}/.p10k.zsh"
  create_symlink "${REPO_ROOT}/.rtorrent.rc" "${HOME}/.rtorrent.rc"
  create_symlink "${REPO_ROOT}/.tmux.conf" "${HOME}/.tmux.conf"
  create_symlink "${REPO_ROOT}/.vimrc" "${HOME}/.vimrc"
  create_symlink "${REPO_ROOT}/.zprofile" "${HOME}/.zprofile"
  create_symlink "${REPO_ROOT}/.zshrc" "${HOME}/.zshrc"

  create_symlink "${REPO_ROOT}/Brewfile" "${HOME}/Brewfile"
}

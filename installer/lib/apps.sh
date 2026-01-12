# shellcheck shell=sh
#
apps() {
  brew bundle --file="${REPO_ROOT}/Brewfile"

  create_symlink "${REPO_ROOT}/Library/LaunchAgents/com.tailscale.startup.plist" "${HOME}/Library/LaunchAgents/com.tailscale.startup.plist"
}

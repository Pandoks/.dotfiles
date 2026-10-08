#!/bin/sh

set -eu

casks=$(brew list --cask)
extensions=$(systemextensionsctl list)

if [ -e /Applications/Tailscale.app ] || [ -e "$HOME/Applications/Tailscale.app" ] ||
  printf '%s\n' "$casks" | grep -Eq '^tailscale(-app)?$' ||
  printf '%s\n' "$extensions" | grep -q 'io\.tailscale\.ipn'; then
  cat >&2 <<'EOF'
Tailscale desktop is still installed. Uninstall the Homebrew app with:
  brew uninstall --cask tailscale-app
For an older tailscale cask, use brew uninstall --cask tailscale instead.
Delete any remaining Tailscale.app, empty the Trash, reboot, then bootstrap again.
EOF
  exit 1
fi

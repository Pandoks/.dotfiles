#!/bin/sh

set -eu

script_directory="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$script_directory/lib/system.sh"

apt_is_available || exit 0

# Tailscale's own installer adds tailscale.list; a second entry with another key breaks apt
if grep -qrs --exclude=tailscale.sources pkgs.tailscale.com /etc/apt/sources.list /etc/apt/sources.list.d; then
  exit 0
fi

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) tailscale_distribution="$ID" ;;
  *)
    echo "Skipping Tailscale repository setup: ${ID:-unknown} is not a supported Tailscale apt distribution."
    exit 0
    ;;
esac

tailscale_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [ -z "$tailscale_codename" ]; then
  echo "Cannot determine the apt distribution codename for Tailscale." >&2
  exit 1
fi

configure_apt_repository \
  "tailscale" \
  "https://pkgs.tailscale.com/stable/$tailscale_distribution/$tailscale_codename.asc" \
  "https://pkgs.tailscale.com/stable/$tailscale_distribution" \
  "$tailscale_codename" \
  "main" \
  "$(dpkg --print-architecture)"

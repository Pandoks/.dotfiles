#!/bin/sh

set -eu

script_directory="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$script_directory/lib/system.sh"

apt_is_available || exit 0

configure_apt_repository \
  "protonvpn" \
  "https://repo.protonvpn.com/debian/public_key.asc" \
  "https://repo.protonvpn.com/debian" \
  "stable" \
  "main" \
  "$(dpkg --print-architecture)"

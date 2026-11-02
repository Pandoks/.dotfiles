#!/bin/sh

set -eu

script_directory="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$script_directory/lib/system.sh"

# Proton's own repo package lists the Proton VPN source with another key, and
# apt then refuses to read any source next to mise's copy
if dpkg-query -W -f '${db:Status-Status}' protonvpn-stable-release 2>/dev/null |
  grep -qv '^not-installed$'; then
  run_as_root dpkg --purge protonvpn-stable-release
fi

sh "$script_directory/setup-docker-apt.sh"

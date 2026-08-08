#!/bin/sh

set -eu

script_directory="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$script_directory/lib/system.sh"

apt_is_available || exit 0

. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) docker_distribution="$ID" ;;
  *)
    echo "Skipping Docker repository setup: ${ID:-unknown} is not a supported Docker apt distribution."
    exit 0
    ;;
esac

docker_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [ -z "$docker_codename" ]; then
  echo "Cannot determine the apt distribution codename for Docker." >&2
  exit 1
fi

configure_apt_repository \
  "docker" \
  "https://download.docker.com/linux/$docker_distribution/gpg" \
  "https://download.docker.com/linux/$docker_distribution" \
  "$docker_codename" \
  "stable" \
  "$(dpkg --print-architecture)"

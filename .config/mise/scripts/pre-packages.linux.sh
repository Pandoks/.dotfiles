#!/bin/sh

set -eu

script_directory="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$script_directory/lib/system.sh"

if apt_is_available; then
  pre_packages_script="$script_directory/pre-packages.apt.sh"
elif pacman_is_available; then
  pre_packages_script="$script_directory/pre-packages.pacman.sh"
else
  echo "Unsupported Linux package manager: expected apt or pacman." >&2
  exit 1
fi

sh "$pre_packages_script"

#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  print -u2 'usage: build.sh OUTPUT.app'
  exit 1
fi

script_dir=${0:a:h}
app_path=${1:a}
if [[ "$app_path" != *.app || -e "$app_path" || -L "$app_path" ]]; then
  print -u2 'OUTPUT.app must be a new application path'
  exit 1
fi

build_dir=$(mktemp -d "${TMPDIR:-/var/tmp}/url-router-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
contents_path="$build_dir/Hammerspoon URL Router.app/Contents"
mkdir -p "$contents_path/MacOS"
install -m 0644 "$script_dir/Info.plist" "$contents_path/Info.plist"

swiftc -swift-version 6 -warnings-as-errors \
  "$script_dir/main.swift" "$script_dir/native.swift" \
  -framework AppKit -o "$contents_path/MacOS/HammerspoonURLRouter"
/usr/bin/codesign --force --sign - --entitlements "$script_dir/entitlements.plist" "${contents_path:h}"
/usr/bin/codesign --verify --strict "${contents_path:h}"
mkdir -p "${app_path:h}"
mv "${contents_path:h}" "$app_path"
print -r -- "$app_path"

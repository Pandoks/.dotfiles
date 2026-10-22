#!/bin/zsh
set -euo pipefail

if (( $# != 1 && $# != 3 )); then
  print -u2 'usage: build.sh OUTPUT.app [SIGNING_IDENTITY PROVISIONING_PROFILE]'
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
identity=-
signing=(--entitlements "$script_dir/entitlements.plist")

if (( $# == 3 )); then
  identity=$2
  if [[ -z "$identity" || "$identity" == - ]]; then
    print -u2 'An Apple signing identity is required for the Universal Link entitlement'
    exit 1
  fi
  /usr/bin/security cms -D -i "$3" -o "$build_dir/profile.plist"
  python3 "$script_dir/provision.py" "$build_dir/profile.plist" \
    "$contents_path/Info.plist" "$build_dir/entitlements.plist"
  install -m 0644 "$3" "$contents_path/embedded.provisionprofile"
  signing=(--options runtime --entitlements "$build_dir/entitlements.plist")
fi

swiftc -swift-version 6 -warnings-as-errors \
  "$script_dir/main.swift" "$script_dir/native.swift" "$script_dir/universal.swift" \
  -framework AppKit -framework SafariServices -framework Security \
  -o "$contents_path/MacOS/HammerspoonURLRouter"
/usr/bin/codesign --force --sign "$identity" "${signing[@]}" "${contents_path:h}"
/usr/bin/codesign --verify --strict "${contents_path:h}"
mkdir -p "${app_path:h}"
mv "${contents_path:h}" "$app_path"
print -r -- "$app_path"

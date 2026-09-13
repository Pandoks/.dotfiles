#!/bin/zsh
set -euo pipefail

script_dir=${0:a:h}
app_path="$HOME/Applications/Hammerspoon URL Router.app"
contents_path="$app_path/Contents"

mkdir -p "$contents_path/MacOS"
swiftc "$script_dir/main.swift" \
  -framework AppKit \
  -o "$contents_path/MacOS/HammerspoonURLRouter"
install -m 0644 "$script_dir/Info.plist" "$contents_path/Info.plist"
codesign --force --sign - "$app_path"
"/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister" \
  -f "$app_path"
swift "$script_dir/set_default.swift" "$app_path"

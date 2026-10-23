#!/bin/sh
set -eu
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
build=$(mktemp -d "${TMPDIR:-/var/tmp}/dictation-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM

# A Lua linked to Hammerspoon's LuaSkin, so the tests can load its hs.fs and hs.json.
frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"
clang -Wall -Wextra -Werror -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework LuaSkin -Wl,-rpath,"$frameworks" "$dir/lua_runner.c" -o "$build/lua"
for suite in spacing history engine init recorder; do
  "$build/lua" "$dir/${suite}_test.lua" "$dir/.." "$frameworks" "$build"
done

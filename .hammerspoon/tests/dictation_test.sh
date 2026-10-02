#!/bin/sh
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test_build=$(mktemp -d "${TMPDIR:-/var/tmp}/dictation-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT HUP INT TERM

frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"
clang -Wall -Wextra -Werror \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/lua_runner.c" -o "$test_build/lua"
for suite in insert history engine recorder; do
  "$test_build/lua" "$test_dir/${suite}_test.lua" "$test_dir/../dictation" "$frameworks" "$test_build"
done

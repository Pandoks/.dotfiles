#!/bin/sh
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test_build=$(mktemp -d "${TMPDIR:-/var/tmp}/insert-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT HUP INT TERM

frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"
clang -Wall -Wextra -Werror \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/lua_runner.c" -o "$test_build/lua"
"$test_build/lua" "$test_dir/insert_test.lua" "$test_dir/../dictation"

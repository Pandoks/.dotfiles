#!/bin/sh
set -eu

test_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
test_build=$(mktemp -d "${TMPDIR:-/var/tmp}/yabai-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT HUP INT TERM

frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"
clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules -bundle -undefined dynamic_lookup \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  "$test_dir/../lib/yabai/yabai.m" -o "$test_build/yabai.so"
clang -Wall -Wextra -Werror \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/lua_runner.c" -o "$test_build/lua"
"$test_build/lua" "$test_dir/yabai_test.lua" "$test_dir/../lib"

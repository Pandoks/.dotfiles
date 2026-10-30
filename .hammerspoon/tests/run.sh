#!/bin/sh
# Exercise Hammerspoon modules without launching their UI.
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test_build=$(mktemp -d "${TMPDIR:-/var/tmp}/window-switcher-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT HUP INT TERM

frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"
clang -Wall -Wextra -Werror \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/lua_runner.c" -o "$test_build/lua"
"$test_build/lua" "$test_dir/window_switcher_test.lua" "$test_dir/../lib"

"$test_build/lua" "$test_dir/window_filter_test.lua" "$test_dir/../lib"

"$test_build/lua" "$test_dir/space_focus_test.lua" "$test_dir/../lib"

"$test_build/lua" "$test_dir/mission_control_test.lua" "$test_dir/../lib"

"$test_build/lua" "$test_dir/utils_test.lua" "$test_dir/../lib"

"$test_build/lua" "$test_dir/tiling_test.lua" "$test_dir/../lib"
"$test_build/lua" "$test_dir/window_manager_test.lua" "$test_dir/../lib"

"$test_build/lua" "$test_dir/logger_test.lua" "$test_dir/../lib"
"$test_build/lua" "$test_dir/window_profiles_test.lua" "$test_dir/../lib"
"$test_build/lua" "$test_dir/native_loader_test.lua" "$test_dir/../lib" "$test_build/cache"

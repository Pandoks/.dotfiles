#!/bin/sh
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test_build=$(mktemp -d "${TMPDIR:-/var/tmp}/url-router-native-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT HUP INT TERM
frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"

clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules -bundle -undefined dynamic_lookup \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  "$test_dir/../lib/url_router/url_router.m" -o "$test_build/url_router.so"
clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework Cocoa -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/url_router_native_test.m" -o "$test_build/native"
mkdir "$test_build/selectors"
"$test_build/native" "$test_build/url_router.so" "$test_build/selectors" \
  "$test_dir/url_router_metadata_test.lua" "$test_dir/../lib"

#!/bin/sh
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test_build=$(mktemp -d "${TMPDIR:-/var/tmp}/previews-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT HUP INT TERM
frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"

clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules -bundle -undefined dynamic_lookup \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  "$test_dir/../lib/previews/previews.m" -o "$test_build/previews.so"
clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules -DPREVIEWS_TEST_MODULE -bundle \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework Cocoa -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/previews_test.m" -o "$test_build/fixture.so"
clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework Cocoa -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/previews_test.m" -o "$test_build/previews"
"$test_build/previews" "$test_build/fixture.so" "$test_dir/previews_test.lua"

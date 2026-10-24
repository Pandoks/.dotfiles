#!/bin/sh
set -eu

test_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
test_build=$(mktemp -d "${TMPDIR:-/var/tmp}/stream-tests.XXXXXX")
trap 'rm -rf "$test_build"' EXIT HUP INT TERM
frameworks="${HAMMERSPOON_APP:-/Applications/Hammerspoon.app}/Contents/Frameworks"
ffmpeg=$(command -v ffmpeg) || { echo "stream tests need ffmpeg on PATH" >&2; exit 1; }

clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules -bundle -undefined dynamic_lookup \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  "$test_dir/../lib/stream/stream.m" -o "$test_build/stream.so"
clang -O2 -Wall -Wextra -Wshadow -Wconversion -Wpedantic -Werror \
  -fobjc-arc -fmodules \
  -I"$frameworks/LuaSkin.framework/Headers" -F"$frameworks" \
  -framework Foundation -framework LuaSkin -Wl,-rpath,"$frameworks" \
  "$test_dir/stream_test.m" -o "$test_build/stream"
clang -O2 -Wall -Wextra -Wconversion -Wpedantic -Werror -dynamiclib \
  "$test_dir/stream_fault.c" -o "$test_build/fault.dylib"
DYLD_INSERT_LIBRARIES="$test_build/fault.dylib" \
  "$test_build/stream" "$test_build/stream.so" "$ffmpeg" "$test_build"

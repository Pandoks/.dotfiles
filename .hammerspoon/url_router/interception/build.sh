#!/bin/zsh
set -euo pipefail

if (( $# != 1 && $# != 2 )); then
  print -u2 'usage: build.sh OUTPUT.dylib [LUA_5.4.9_ARCHIVE]'
  exit 1
fi
script_dir=${0:a:h}
output=${1:a}
if [[ -e "$output" || -L "$output" || -e "$output.probe" || -L "$output.probe" ]]; then
  print -u2 'Output files must not exist'
  exit 1
fi
build_dir=$(mktemp -d "${TMPDIR:-/var/tmp}/url-interception-build.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
archive="$build_dir/lua.tar.gz"
if (( $# == 2 )); then
  cp "$2" "$archive"
else
  curl --fail --silent --show-error --location --proto '=https' \
    https://www.lua.org/ftp/lua-5.4.9.tar.gz -o "$archive"
fi
expected=2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6
actual=$(/usr/bin/shasum -a 256 "$archive")
if [[ "${actual%% *}" != "$expected" ]]; then
  print -u2 'Lua 5.4.9 archive checksum mismatch'
  exit 1
fi
tar -xzf "$archive" -C "$build_dir"
lua_dir="$build_dir/lua-5.4.9/src"
python3 - "$script_dir/../../lib/url_router/match.lua" "$build_dir/matcher.h" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_bytes()
rows = [','.join(str(byte) for byte in source[index:index + 24]) for index in range(0, len(source), 24)]
Path(sys.argv[2]).write_text('static const unsigned char matcher[] = {\n' + ',\n'.join(rows) + '\n};\n')
PY
objects=()
for source in "$lua_dir"/*.c; do
  [[ "${source:t}" == lua.c || "${source:t}" == luac.c ]] && continue
  object="$build_dir/${source:t:r}.o"
  clang -arch arm64e -O2 -fPIC -fvisibility=hidden -DLUA_USE_MACOSX -I "$lua_dir" -c "$source" -o "$object"
  objects+=("$object")
done
clang -arch arm64e -O2 -fobjc-arc -fvisibility=hidden -Wall -Wextra -Werror -dynamiclib \
  -I "$lua_dir" -I "$build_dir" "$script_dir/hook.m" "$script_dir/selectors.m" \
  "$script_dir/platform.m" "$script_dir/status.m" "${objects[@]}" \
  -framework Foundation -framework Security -lbsm -o "$build_dir/hook.dylib"
clang -arch arm64 -O2 -fobjc-arc -Wall -Wextra -Werror \
  "$script_dir/probe.m" "$script_dir/platform.m" "$script_dir/status.m" \
  -framework Foundation -framework Security -lbsm -o "$build_dir/probe"
/usr/bin/codesign --force --sign - "$build_dir/hook.dylib"
/usr/bin/codesign --force --sign - "$build_dir/probe"
/usr/bin/codesign --verify --strict "$build_dir/hook.dylib"
/usr/bin/codesign --verify --strict "$build_dir/probe"
mkdir -p "${output:h}"
install -m 0644 "$build_dir/hook.dylib" "$output"
install -m 0755 "$build_dir/probe" "$output.probe"
print -r -- "$output"

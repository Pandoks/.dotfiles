#!/bin/sh
set -eu
dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)

# Apple Silicon even from a Rosetta shell, where uname -m says x86_64.
[ "$(sysctl -n hw.optional.arm64 2> /dev/null)" = 1 ] \
  && [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] \
  || {
    echo "dictation needs Apple Silicon and macOS 14+ (MLX)" >&2
    exit 1
  }
uv sync --project "$dir" --locked
"$dir/.venv/bin/python" -c 'import parakeet_mlx, mlx_audio, mlx_whisper, mlx_lm'
echo "Done. Reload Hammerspoon; its first start downloads the models pinned in config.lua."

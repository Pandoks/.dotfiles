#!/bin/sh
# Create the local Python backend for Hammerspoon dictation.
# Syncs dictation/.venv to the hashed lock requirements.txt. Safe to re-run.
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
venv="$dir/.venv"

[ "$(uname -m)" = arm64 ] && [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] \
  || {
    echo "dictation needs Apple Silicon and macOS 14+ (MLX)" >&2
    exit 1
  }
uv --version > /dev/null 2>&1 || {
  echo "uv missing: run mise install" >&2
  exit 1
}
uv venv --allow-existing -p 3.12 "$venv"
uv pip sync -p "$venv/bin/python" "$dir/requirements.txt"

echo
echo "Done. Verify with:"
echo "  \"$venv/bin/python\" -c \\"
echo "    'import parakeet_mlx, mlx_audio, mlx_whisper, mlx_lm; print(\"ok\")'"
echo
echo "Reload Hammerspoon: the backend's first start downloads the models pinned in config.lua"
echo "into ~/.cache/huggingface."

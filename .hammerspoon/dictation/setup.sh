#!/bin/sh
# Create the local Python backend for Hammerspoon dictation.
# Builds dictation/.venv with the speech + LLM runtimes. Safe to re-run.
set -eu

dir=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
venv="$dir/.venv"

# Find a working uv: prefer a real mise-installed binary over the shim (the shim
# errors when no global uv version is set), then fall back to PATH.
uv=""
works() { [ -x "$1" ] && "$1" --version >/dev/null 2>&1; }

for cand in "$HOME"/.local/share/mise/installs/uv/*/*/uv \
            "$HOME"/.local/share/mise/installs/uv/*/uv; do
  if works "$cand"; then uv="$cand"; break; fi
done

if [ -z "$uv" ] && command -v uv >/dev/null 2>&1; then
  cand=$(command -v uv)
  works "$cand" && uv="$cand"
fi

if [ -z "$uv" ]; then
  echo "No working uv found. Install it (https://docs.astral.sh/uv/) or set one:" >&2
  echo "  mise use -g uv" >&2
  exit 1
fi

echo "Using uv: $uv"
"$uv" venv -p 3.12 "$venv"
"$uv" pip install -p "$venv/bin/python" -r "$dir/requirements.txt"

echo
echo "Done. Verify with:"
echo "  \"$venv/bin/python\" -c 'import parakeet_mlx, mlx_audio, mlx_lm; print(\"ok\")'"
echo
echo "First dictation downloads the models named in config.lua into ~/.cache/huggingface."

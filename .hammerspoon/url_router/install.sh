#!/bin/zsh
set -euo pipefail
script_dir=${0:a:h}
exec python3 "$script_dir/install.py" "$@"

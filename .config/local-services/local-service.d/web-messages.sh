#!/bin/sh
set -eu

trap 'exit 0' INT TERM HUP

while :; do
  ~/.local/bin/webmessages-v0.0.25 --port 55001
  code=$?
  echo "[web-messages] exited with code $code; restarting in 3s" >&2
  sleep 3
done

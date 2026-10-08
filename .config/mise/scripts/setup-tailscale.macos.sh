#!/bin/sh

set -eu

brew=$(command -v brew)
tailscale="$("$brew" --prefix tailscale)/bin/tailscale"
user=$(id -un)

sudo "$brew" services start tailscale
status=$(sudo "$tailscale" status --json)
state=$(printf '%s\n' "$status" | plutil -extract BackendState raw -o - -)

if [ "$state" = NeedsLogin ]; then
  sudo "$tailscale" up --ssh --operator="$user" --accept-dns=true
elif [ "$state" != Running ]; then
  sudo "$tailscale" up
fi

sudo "$tailscale" set --ssh --operator="$user" --accept-dns=true

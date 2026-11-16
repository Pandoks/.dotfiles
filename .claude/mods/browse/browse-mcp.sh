#!/bin/sh
# Runs the browse MCP server of the Mac at SSH host alias $1. The relay only answers agents on
# its own machine, so another machine runs the server there over SSH. Tailscale SSH can't reach
# the machine it runs on, so this machine runs its own directly.
host=$(ssh -G "$1" | awk '$1 == "hostname" { print $2 }')
self=$(tailscale ip -4 2> /dev/null)
if [ -n "$self" ] && [ "$(tailscale ip -4 "$host" 2> /dev/null)" = "$self" ]; then
  exec "$HOME/.local/bin/browse" mcp
fi
exec ssh -T -o BatchMode=yes -o ConnectTimeout=5 "$1" .local/bin/browse mcp

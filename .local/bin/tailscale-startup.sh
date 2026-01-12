#!/bin/bash

/opt/homebrew/bin/tailscale switch pandoks
/usr/bin/sudo /bin/mkdir -p /etc/resolver
echo "nameserver 100.100.100.100" | /usr/bin/sudo /usr/bin/tee /etc/resolver/ts.net > /dev/null
/opt/homebrew/bin/tailscale up

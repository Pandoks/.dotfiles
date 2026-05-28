#!/bin/sh

set -eu

if [ ! -x /usr/bin/afplay ] || [ ! -f /System/Library/Sounds/Glass.aiff ]; then
  exit 0
fi

/usr/bin/afplay /System/Library/Sounds/Glass.aiff > /dev/null 2>&1 &
exit 0

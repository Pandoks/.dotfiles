#!/bin/sh

set -eu

script_directory="$(CDPATH= cd "$(dirname "$0")" && pwd)"

sh "$script_directory/setup-docker-apt.sh"

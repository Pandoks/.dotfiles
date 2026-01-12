#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
readonly SCRIPT_DIR
readonly REPO_ROOT

. "${SCRIPT_DIR}/lib/symlink.sh"
. "${SCRIPT_DIR}/lib/configs.sh"

usage() {
  printf "Usage: %s <command>\n\n" "$0" >&2
  printf "Install and configure dotfiles.\n\n" >&2

  printf "Commands:\n" >&2
  printf "  bootstrap    Initial system setup (Xcode CLI tools, Homebrew, Oh My Zsh)\n" >&2
  printf "  apps         Install applications via Homebrew bundle\n" >&2
  printf "  configs      Symlink configuration files\n" >&2
  printf "  all          Run all setup steps (bootstrap, configs, apps)\n\n" >&2

  printf "Run '%s <command>' to execute a command.\n\n" "$0" >&2

  exit "${1:-0}"
}

setup() {
  xcode-select --install
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
}

install_brew() {
  brew bundle --file="${REPO_ROOT}/Brewfile"
}

main() {
  if [ $# -eq 0 ]; then
    usage 1
  fi

  cmd="$1"
  shift

  case "${cmd}" in
    bootstrap) setup ;;
    apps) install_brew ;;
    configs) install_configs ;;
    all) setup && install_configs && install_brew ;;
    -h|--help|help) usage 0 ;;
    *) echo "Error: Unknown command '${cmd}'" >&2; usage 1 ;;
  esac
}

main "$@"

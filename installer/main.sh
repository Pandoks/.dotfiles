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
  xcode-select --install 2>&1 | grep -q "already installed" || {
    echo "Waiting for Xcode Command Line Tools installation to complete..."
    until xcode-select -p > /dev/null 2>&1; do
      sleep 5
    done
    echo "Xcode Command Line Tools installed successfully"
  }
  RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
}

install_brew() {
  eval "$(/opt/homebrew/bin/brew shellenv)"
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
    -h | --help | help) usage 0 ;;
    *)
      echo "Error: Unknown command '${cmd}'" >&2
      usage 1
      ;;
  esac

  exec zsh
}

main "$@"

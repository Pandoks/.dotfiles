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
  if ! xcode-select -p > /dev/null 2>&1; then
    echo "Installing Xcode Command Line Tools..."
    xcode-select --install
    echo "Waiting for Xcode Command Line Tools installation to complete..."
    until xcode-select -p > /dev/null 2>&1; do
      sleep 5
    done
    echo "Xcode Command Line Tools installed successfully"
  else
    echo "Xcode Command Line Tools already installed"
  fi

  if [ -d "${REPO_ROOT}/.git" ]; then
    echo "Git repository already initialized"
    return 0
  fi

  echo "Initializing git repository..."
  git -C "${REPO_ROOT}" init -b master
  git -C "${REPO_ROOT}" remote add origin "https://github.com/Pandoks/.dotfiles.git"
  git -C "${REPO_ROOT}" fetch origin
  git -C "${REPO_ROOT}" reset origin/master
  git -C "${REPO_ROOT}" branch --set-upstream-to=origin/master master
  echo "Git repository initialized"

  if [ "$(uname -m)" = "arm64" ]; then
    if ! /usr/bin/pgrep -q oahd; then
      echo "Installing Rosetta 2..."
      softwareupdate --install-rosetta --agree-to-license
      echo "Rosetta 2 installed successfully"
    else
      echo "Rosetta 2 already installed"
    fi
  fi

  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Installing Oh My Zsh..."
    RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    echo "Oh My Zsh installed successfully"
  else
    echo "Oh My Zsh already installed"
  fi

  if ! command -v brew > /dev/null 2>&1; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo "Homebrew installed successfully"
  else
    echo "Homebrew already installed"
  fi
}

install_brew() {
  eval "$(/opt/homebrew/bin/brew shellenv)"
  brew bundle install --file="${REPO_ROOT}/Brewfile"

  yabai_string="$(whoami) ALL=(root) NOPASSWD: sha256:$(shasum -a 256 "$(which yabai)" | cut -d " " -f 1) $(which yabai) --load-sa"
  echo "$yabai_string" | sudo tee /private/etc/sudoers.d/yabai > /dev/null
}

main() {
  if [ -n "${SUDO_USER:-}" ] || [ "$(id -u)" -eq 0 ]; then
    echo "Error: This script should not be run with sudo" >&2
    exit 1
  fi

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

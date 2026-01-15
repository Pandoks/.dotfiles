#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
readonly SCRIPT_DIR
readonly REPO_ROOT

. "${SCRIPT_DIR}/lib/font.sh"
. "${SCRIPT_DIR}/lib/symlink.sh"
. "${SCRIPT_DIR}/lib/configs.sh"
. "${SCRIPT_DIR}/lib/macos.sh"

DOTFILES_REPO="https://github.com/Pandoks/.dotfiles.git"
readonly DOTFILES_REPO

usage() {
  printf "%bUsage:%b %s <command>\n\n" "${BOLD}" "${NORMAL}" "$0" >&2
  printf "Install and configure dotfiles.\n\n" >&2

  printf "%bCommands:%b\n" "${BOLD}" "${NORMAL}" >&2
  printf "  %bbootstrap%b    Initial system setup (Xcode CLI tools, Homebrew, Oh My Zsh)\n" "${GREEN}" "${NORMAL}" >&2
  printf "  %bapps%b         Install applications via Homebrew bundle\n" "${GREEN}" "${NORMAL}" >&2
  printf "  %bconfigs%b      Symlink configuration files\n" "${GREEN}" "${NORMAL}" >&2
  printf "  %bmacos%b        Manage macOS system settings [apply|export|diff]\n" "${GREEN}" "${NORMAL}" >&2
  printf "  %ball%b          Run all setup steps (bootstrap, configs, apps, macos)\n\n" "${GREEN}" "${NORMAL}" >&2

  printf "Run '%s <command>' to execute a command.\n\n" "$0" >&2

  exit "${1:-0}"
}

setup_git() {
  if [ -d "${REPO_ROOT}/.git" ]; then
    printf "%b✓ Git repository already initialized%b\n" "${GREEN}" "${NORMAL}"
    return 0
  fi

  printf "Initializing git repository...\n"
  git -C "${REPO_ROOT}" init
  git -C "${REPO_ROOT}" remote add origin "${DOTFILES_REPO}"
  git -C "${REPO_ROOT}" fetch origin
  git -C "${REPO_ROOT}" branch --set-upstream-to=origin/master master 2>/dev/null || true
  printf "%b✓ Git repository initialized and connected to %s%b\n" "${GREEN}" "${DOTFILES_REPO}" "${NORMAL}"
}

setup() {
  setup_git

  if ! xcode-select -p > /dev/null 2>&1; then
    printf "Installing Xcode Command Line Tools...\n"
    xcode-select --install
    printf "Waiting for Xcode Command Line Tools installation to complete...\n"
    until xcode-select -p > /dev/null 2>&1; do
      sleep 5
    done
    printf "%b✓ Xcode Command Line Tools installed%b\n" "${GREEN}" "${NORMAL}"
  else
    printf "%b✓ Xcode Command Line Tools already installed%b\n" "${GREEN}" "${NORMAL}"
  fi

  if [ "$(uname -m)" = "arm64" ]; then
    if ! /usr/bin/pgrep -q oahd; then
      printf "Installing Rosetta 2...\n"
      softwareupdate --install-rosetta --agree-to-license
      printf "%b✓ Rosetta 2 installed%b\n" "${GREEN}" "${NORMAL}"
    else
      printf "%b✓ Rosetta 2 already installed%b\n" "${GREEN}" "${NORMAL}"
    fi
  fi

  if [ ! -d "${HOME}/.oh-my-zsh" ]; then
    printf "Installing Oh My Zsh...\n"
    RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    printf "%b✓ Oh My Zsh installed%b\n" "${GREEN}" "${NORMAL}"
  else
    printf "%b✓ Oh My Zsh already installed%b\n" "${GREEN}" "${NORMAL}"
  fi

  if ! command -v brew > /dev/null 2>&1; then
    printf "Installing Homebrew...\n"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    printf "%b✓ Homebrew installed%b\n" "${GREEN}" "${NORMAL}"
  else
    printf "%b✓ Homebrew already installed%b\n" "${GREEN}" "${NORMAL}"
  fi
}

install_brew() {
  eval "$(/opt/homebrew/bin/brew shellenv)"
  printf "Installing Homebrew packages...\n"
  brew bundle install --file="${REPO_ROOT}/Brewfile"
  printf "%b✓ Homebrew packages installed%b\n" "${GREEN}" "${NORMAL}"

  setup_yabai_string="$(whoami) ALL=(root) NOPASSWD: sha256:$(shasum -a 256 "$(which yabai)" | cut -d " " -f 1) $(which yabai) --load-sa"
  printf "%s" "${setup_yabai_string}" | sudo tee /private/etc/sudoers.d/yabai > /dev/null
  printf "%b✓ yabai sudoers configured%b\n" "${GREEN}" "${NORMAL}"
}

main() {
  if [ -n "${SUDO_USER:-}" ] || [ "$(id -u)" -eq 0 ]; then
    printf "%bError:%b This script should not be run with sudo\n" "${RED}" "${NORMAL}" >&2
    exit 1
  fi

  if [ $# -eq 0 ]; then
    usage 1
  fi

  main_cmd="$1"
  shift

  case "${main_cmd}" in
    bootstrap) setup && exec zsh ;;
    apps) install_brew && exec zsh ;;
    configs) install_configs && exec zsh ;;
    macos) macos_defaults "$@" ;;
    all) setup && install_configs && install_brew && macos_defaults apply && exec zsh ;;
    -h | --help | help) usage 0 ;;
    *)
      printf "%bError:%b Unknown command '%s'\n" "${RED}" "${NORMAL}" "${main_cmd}" >&2
      usage 1
      ;;
  esac
}

main "$@"

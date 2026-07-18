# shellcheck shell=sh

OS="$(uname -s)"
readonly OS

is_macos() {
  [ "${OS}" = "Darwin" ]
}

is_linux() {
  [ "${OS}" = "Linux" ]
}

linux_install_packages() {
  if command -v apt-get > /dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y git curl ca-certificates zsh tmux vim \
      build-essential libssl-dev libyaml-dev zlib1g-dev
  elif command -v dnf > /dev/null 2>&1; then
    sudo dnf install -y git curl ca-certificates zsh tmux vim \
      gcc make openssl-devel libyaml-devel zlib-devel
  elif command -v pacman > /dev/null 2>&1; then
    sudo pacman -Sy --noconfirm --needed git curl ca-certificates zsh tmux vim \
      base-devel openssl libyaml zlib
  else
    echo "Warning: No supported package manager found (apt-get, dnf, pacman)" >&2
    echo "Warning: Install git, curl, zsh, and build tools manually" >&2
  fi
}

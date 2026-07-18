#!/bin/sh

set -eu

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."
readonly SCRIPT_DIR
readonly REPO_ROOT

. "${SCRIPT_DIR}/lib/os.sh"
. "${SCRIPT_DIR}/lib/symlink.sh"
. "${SCRIPT_DIR}/lib/configs.sh"

usage() {
  printf "Usage: %s <command>\n\n" "$0" >&2
  printf "Install and configure dotfiles.\n\n" >&2

  printf "Commands:\n" >&2
  printf "  bootstrap    Initial system setup (build tools, package manager, Oh My Zsh)\n" >&2
  printf "  apps         Install applications (Homebrew bundle on macOS, mise everywhere)\n" >&2
  printf "  configs      Symlink configuration files\n" >&2
  printf "  ssh          Install SSH keys and configure SSH daemon\n" >&2
  printf "  all          Run all setup steps (bootstrap, configs, apps)\n\n" >&2

  printf "Run '%s <command>' to execute a command.\n\n" "$0" >&2

  exit "${1:-0}"
}

setup_macos() {
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

  if [ "$(uname -m)" = "arm64" ]; then
    if ! /usr/bin/pgrep -q oahd; then
      echo "Installing Rosetta 2..."
      softwareupdate --install-rosetta --agree-to-license
      echo "Rosetta 2 installed successfully"
    else
      echo "Rosetta 2 already installed"
    fi
  fi

  if ! command -v brew > /dev/null 2>&1; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo "Homebrew installed successfully"
  else
    echo "Homebrew already installed"
  fi
}

setup_linux() {
  echo "Installing system packages..."
  linux_install_packages
  echo "System packages installed successfully"

  if ! command -v mise > /dev/null 2>&1 && [ ! -x "${HOME}/.local/bin/mise" ]; then
    echo "Installing mise..."
    curl -fsSL https://mise.run | sh
    echo "mise installed successfully"
  else
    echo "mise already installed"
  fi
}

setup_git_repo() {
  if [ -e "${REPO_ROOT}/.git" ]; then
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
}

setup_zsh_addons() {
  setup_zsh_addons_custom_dir="${ZSH_CUSTOM:-${HOME}/.oh-my-zsh/custom}"

  if [ ! -d "${setup_zsh_addons_custom_dir}/themes/powerlevel10k" ]; then
    echo "Installing Powerlevel10k..."
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \
      "${setup_zsh_addons_custom_dir}/themes/powerlevel10k"
    echo "Powerlevel10k installed successfully"
  else
    echo "Powerlevel10k already installed"
  fi

  if [ ! -d "${setup_zsh_addons_custom_dir}/plugins/zsh-vi-mode" ]; then
    echo "Installing zsh-vi-mode..."
    git clone --depth=1 https://github.com/jeffreytse/zsh-vi-mode.git \
      "${setup_zsh_addons_custom_dir}/plugins/zsh-vi-mode"
    echo "zsh-vi-mode installed successfully"
  else
    echo "zsh-vi-mode already installed"
  fi

  if [ ! -d "${HOME}/.tmux/plugins/tpm" ]; then
    echo "Installing tpm..."
    git clone --depth=1 https://github.com/tmux-plugins/tpm.git "${HOME}/.tmux/plugins/tpm"
    echo "tpm installed successfully"
  else
    echo "tpm already installed"
  fi
}

setup() {
  if is_macos; then
    setup_macos
  else
    setup_linux
  fi

  setup_git_repo

  if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "Installing Oh My Zsh..."
    RUNZSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
    echo "Oh My Zsh installed successfully"
  else
    echo "Oh My Zsh already installed"
  fi

  if is_linux; then
    setup_zsh_addons
  fi
}

install_apps() {
  if is_macos; then
    if [ -x /opt/homebrew/bin/brew ]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
      eval "$(/usr/local/bin/brew shellenv)"
    fi
    brew bundle install -v --file="${REPO_ROOT}/Brewfile"

    yabai_string="$(whoami) ALL=(root) NOPASSWD: sha256:$(shasum -a 256 "$(which yabai)" | cut -d " " -f 1) $(which yabai) --load-sa"
    echo "$yabai_string" | sudo tee /private/etc/sudoers.d/yabai > /dev/null

    tailscale completion zsh > "$(brew --prefix)/share/zsh/site-functions/_tailscale"
  fi

  PATH="${HOME}/.local/bin:${PATH}"
  mise install --yes
}

install_ssh() {
  mkdir -p "${HOME}/.ssh"
  if is_macos; then
    create_symlink --sudo "${REPO_ROOT}/private/etc/ssh/sshd_config" "/private/etc/ssh/sshd_config"
  else
    create_symlink --sudo "${REPO_ROOT}/private/etc/ssh/sshd_config" "/etc/ssh/sshd_config"
  fi
  create_symlink "${REPO_ROOT}/.ssh/authorized_keys" "${HOME}/.ssh/authorized_keys"
  create_symlink "${REPO_ROOT}/.ssh/config" "${HOME}/.ssh/config"

  sudo ssh-keygen -A
  if is_macos; then
    sudo launchctl kickstart -k system/com.openssh.sshd
  elif [ -d /run/systemd/system ]; then
    sudo systemctl restart sshd 2> /dev/null || sudo systemctl restart ssh
  else
    echo "Warning: Restart the SSH daemon manually to apply the new configuration" >&2
  fi
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
    apps) install_apps ;;
    configs) install_configs ;;
    ssh) install_ssh ;;
    all) setup && install_configs && install_apps ;;
    -h | --help | help) usage 0 ;;
    *)
      echo "Error: Unknown command '${cmd}'" >&2
      usage 1
      ;;
  esac

  exec zsh
}

main "$@"

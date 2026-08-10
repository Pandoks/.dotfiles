# dotfiles

**Opinionated macOS and Linux workstation configuration, managed by [mise].**

[![macOS](https://img.shields.io/badge/macOS-Apple_Silicon_%7C_Intel-000000?style=flat-square&logo=apple&logoColor=white)](#supported-systems)
[![Linux](https://img.shields.io/badge/Linux-Debian_%7C_Ubuntu_%7C_Arch-FCC624?style=flat-square&logo=linux&logoColor=black)](#supported-systems)
[![mise](https://img.shields.io/badge/managed_with-mise-2F80ED?style=flat-square)](https://mise.jdx.dev/)
[![Last commit](https://img.shields.io/github/last-commit/Pandoks/.dotfiles?style=flat-square)](https://github.com/Pandoks/.dotfiles/commits/master)

Installs system packages and developer tools, clones shell plugins, selects
Zsh, and links application config.

## Supported systems

| System | Package manager |
| --- | --- |
| macOS on Apple Silicon or Intel | Homebrew |
| Debian / Ubuntu | apt |
| Arch Linux | pacman |

Other platforms are not configured.

## Install

Install Git and [mise] first.

### Debian / Ubuntu

```sh
sudo apt update
sudo apt install -y git extrepo
sudo extrepo enable mise
sudo apt update
sudo apt install -y mise
```

### Arch Linux

```sh
sudo pacman -Syu --needed git mise
```

### macOS (Apple Silicon or Intel)

Install the Xcode Command Line Tools and complete its prompt:

```sh
xcode-select --install
```

Then install [Homebrew] and mise:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  eval "$(/usr/local/bin/brew shellenv)"
fi
brew install mise
```

Bootstrap the machine:

```sh
git clone https://github.com/Pandoks/.dotfiles.git "$HOME/.dotfiles"
cd "$HOME/.dotfiles"
mise bootstrap --yes
```

Bootstrap is idempotent and refuses to overwrite conflicting files. Start a
new login shell when it finishes.

### Existing files

Preview migration before replacing any existing dotfiles:

```sh
cd /path/to/.dotfiles
export MISE_GLOBAL_CONFIG_FILE="$PWD/.config/mise/config.toml"
mise bootstrap --yes --only dotfiles --dry-run --verbose
```

Reconcile every conflict, then run `mise bootstrap --yes`. Use
`--force-dotfiles` only after reviewing the preview.

## After bootstrap

Authenticate services locally; credentials are not stored in this repository:

```sh
gh auth login
aws sso login --profile PROFILE_NAME
```

SSH configuration and `authorized_keys` are managed, but SSH private keys are
not. Ensure the managed SSH files have the required permissions:

```sh
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/authorized_keys"
```

The source of truth is
[`.config/mise/config.toml`](.config/mise/config.toml), with OS-specific
packages in the adjacent `config.linux.toml` and `config.macos.toml` files.

[Homebrew]: https://brew.sh/
[mise]: https://mise.jdx.dev/

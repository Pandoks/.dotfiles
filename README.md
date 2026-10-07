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

#### Disable SIP

Some of the features need [SIP] disabled.

1. Shut down. Hold power (Apple Silicon) or hold Command-R during startup (Intel).
2. Apple Silicon: **Options → Continue**. Authenticate when prompted.
3. **Utilities → Terminal**: `csrutil disable`. Confirm and authenticate.
4. Restart. Check `csrutil status` reports `disabled`.

## Bootstrap

```sh
git clone https://github.com/Pandoks/.dotfiles.git "$HOME/.dotfiles"
cd "$HOME/.dotfiles"
export MISE_GLOBAL_CONFIG_FILE="$PWD/.config/mise/config.toml"
sudo -v && mise bootstrap --yes
```

Bootstrap is idempotent and refuses to overwrite conflicting files. Start a
new login shell when it finishes.

### Update

```sh
cd "$HOME/.dotfiles"
git pull --ff-only
export MISE_GLOBAL_CONFIG_FILE="$PWD/.config/mise/config.toml"
sudo -v && mise bootstrap --yes
```

### Existing files

Preview migration before replacing any existing dotfiles:

```sh
cd "$HOME/.dotfiles"
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

Linux also installs [fwupd]; firmware checks and updates are manual:

```sh
sudo fwupdmgr refresh
fwupdmgr get-updates
```

### Linux laptops

Physical systemd laptops keep running with the lid closed on AC and request
suspend on battery. Dock settings and lid inhibitors take precedence.

The [panel helper](.config/mise/scripts/laptop-panel.linux.sh) saves brightness
on close, requests zero, and restores it on open. This doesn't request panel
power-off; zero can still leave a panel lit. The backlight device is
`intel_backlight` (T470). For other laptops, set `LAPTOP_BACKLIGHT_DEVICE` in
[`config.laptop.toml`](.config/mise/config.laptop.toml) to the verified internal
backlight device. The helper defers to desktop lid inhibitors; disable the
acpid panel rules if your desktop manages brightness without one.

## CLIProxyAPI

Claude Code and Codex route through the [CLIProxyAPI] service on the tailnet.
Keep Tailscale connected, run `/login` once in Claude Code for claude.ai
connectors, and don't set `ANTHROPIC_AUTH_TOKEN`.

### Host

On the machine tagged `tag:cliproxyapi`:

```sh
mise -E cliproxyapi bootstrap --yes
sudo tailscale serve --service=svc:cliproxyapi --https=443 http://127.0.0.1:8317
```

Set the dashboard password in `management.secret-key` of
`~/.cli-proxy-api/config.yaml`, then run
`systemctl --user restart dev.mise.cli-proxy-api` (it's hashed on start). Add
accounts and enable WebSockets on Codex ones at
`https://cliproxyapi.<tailnet>.ts.net/management.html`. The config links into
this public repo, so never commit `secret-key` or API keys.

Upgrade:

```sh
mise -E cliproxyapi up && systemctl --user restart dev.mise.cli-proxy-api
```

[SIP]: https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection
[CLIProxyAPI]: https://github.com/router-for-me/CLIProxyAPI
[Homebrew]: https://brew.sh/
[mise]: https://mise.jdx.dev/
[fwupd]: https://github.com/fwupd/fwupd/blob/main/src/fwupdmgr.md

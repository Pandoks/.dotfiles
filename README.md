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

Linux also installs [fwupd] to check and update supported device firmware.
Firmware checks and updates are manual; bootstrap only installs the tool.
Optionally discover available updates after bootstrap:

```sh
sudo fwupdmgr refresh
fwupdmgr get-updates
```

Device support varies. Sleep/resume reliability depends on the kernel,
drivers, and firmware.

### Linux laptops

The Linux final bootstrap hook applies `config.laptop.toml` on physical systemd
laptops. Desktops, servers, VMs, containers, and non-systemd systems skip its
packages, files, services, and privilege requests. Existing Linux setup still
applies normally. This setup works with mise 2026.8.3 and 2026.10.3.

The policy is `/etc/systemd/logind.conf.d/60-mise-laptop-power.conf`. Closing the
lid on AC keeps SSH and services running; on battery, logind requests suspend.
`HandleLidSwitchDocked` keeps the existing setting (systemd defaults to
`ignore`): docking or multiple attached displays takes precedence over the AC
and battery actions, so a docked laptop can stay awake on battery. Later
drop-ins and lid-switch inhibitors can take precedence. Bootstrap applies the
policy with HUP, without restarting logind.

Mise installs `acpid` and `brightnessctl`, writes two event rules and a service
drop-in, and enables the packaged acpid service. On a close event, the rules
save the internal panel's brightness once and request zero; on open, they
restore it. The single `Environment=LAPTOP_BACKLIGHT_DEVICE=intel_backlight`
assignment in `config.laptop.toml` selects the T470's interface. For another
laptop, verify its internal backlight interface and edit that assignment.
Exact backlight selection excludes keyboard LEDs and other devices. Firmware
may map zero to a lit panel, so verify physical darkness.

Before changing brightness, each rule queries logind's public inhibitor
properties. If a `handle-lid-switch` block or weak-block inhibitor is observed,
the rule leaves brightness to its owner and discards only its own device's
saved level. This avoids restoring an old headless brightness level after
observing a desktop power manager take over. Ownership is checked only on lid
events; changes between events or after the query can still race with an
action. A graphical power manager that does not hold a lid-switch inhibitor
needs the panel rules disabled: open the lid, replace `source` with
`state = "absent"` in both panel-rule declarations, retain
`notify = ["acpid"]`, and reapply. The logind policy can remain.

Brightness state lives under the private `/run/acpid-lid-backlight` directory
and survives acpid restarts, but not reboot. Failed save/restore writes retain
state for a later event. If the logind query fails, including failure of an
unrelated property getter, the rules leave brightness and saved state alone;
a failed open query can leave the panel dark until a later successful open
event. There is no startup reconciliation, stop-time restore, resume hook, or
retry loop. Open and close the lid once if it starts closed. Check actual lid
events, panel darkness, battery suspend/resume, and reboot on the laptop.
Other existing acpid rules also run and may need adjustment.

The event actions are compact because released acpid limits an action to 255
bytes. Preserve their literal `%%s` escape: acpid expands it to `%s` before
running the shell. The service's command-prefix and state-path variables keep
the actions within that limit.

If an earlier version of this PR was applied, bootstrap stops/disables its old
service while its restore helper still exists, then removes the old unit and
two helpers. Unrestored old state and an optional device allowlist remain
inert; they are not imported into brightnessctl's state.

To preview or reapply only this setup from the repository:

```sh
cd "$HOME/.dotfiles"
export MISE_GLOBAL_CONFIG_FILE="$PWD/.config/mise/config.toml"
mise bootstrap --yes --only final-hook --dry-run
mise bootstrap --yes --only final-hook
```

The dry run prints the hook without executing its hardware guard or nested
bootstrap. From an unrelated directory after installation, select the global
Linux config explicitly: `mise -E linux bootstrap --yes --only final-hook`.

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

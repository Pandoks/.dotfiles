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

<details>
<summary>Disable SIP</summary>

Some features need [SIP] partially disabled.

1. Shut down. Hold power (Apple Silicon) or hold Command-R during startup (Intel).
2. Apple Silicon: **Options → Continue**. Authenticate when prompted.
3. **Utilities → Terminal**, then run the command for your Mac and authenticate:

   ```sh
   # Apple Silicon, macOS 13+
   csrutil enable --without fs --without debug --without nvram

   # Apple Silicon, macOS 12
   csrutil disable --with kext --with dtrace --with basesystem

   # Intel, macOS 11+
   csrutil disable --with kext --with dtrace --with nvram --with basesystem
   ```

4. Restart into **normal macOS**. **Apple Silicon only:** open the regular
   **Terminal** app and check existing boot arguments:

   ```sh
   nvram boot-args
   ```

   **Flag already present:** if the output includes `-arm64e_preview_abi`,
   skip to step 5.

   **No existing arguments:** if the value is empty or the command reports
   `data was not found`, run:

   ```sh
   sudo nvram boot-args=-arm64e_preview_abi
   ```

   **Existing arguments, flag missing:** keep every existing argument inside
   the quotes and add `-arm64e_preview_abi`. For example, if the current value
   is exactly `debug=0x100`, run:

   ```sh
   sudo nvram boot-args="debug=0x100 -arm64e_preview_abi"
   ```

   For any other read error, stop and resolve it first.
   **Restart again after changing boot arguments.**

5. Check `csrutil status`. It may report `unknown (Custom Configuration)`;
   that is expected. Filesystem Protections and Debugging Restrictions
   should be disabled (plus NVRAM Protections on Apple Silicon), while Kext
   Signing and DTrace Restrictions stay enabled. On Apple Silicon,
   `nvram boot-args` should include `-arm64e_preview_abi`.

</details>

## Bootstrap

```sh
git clone https://github.com/Pandoks/.dotfiles.git "$HOME/.dotfiles"
cd "$HOME/.dotfiles"
sudo -v && mise bootstrap --yes
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
chmod 700 "$HOME/.ssh"
```

The source of truth is
[`.config/mise/config.toml`](.config/mise/config.toml), with OS-specific
packages in the adjacent `config.linux.toml` and `config.macos.toml` files.

## CLIProxyAPI

Claude Code, Codex, and Grok Build route through the [CLIProxyAPI] service on the tailnet.
Keep Tailscale connected, run `/login` once in Claude Code for claude.ai
connectors, and don't set `ANTHROPIC_AUTH_TOKEN`.

Grok Build discovers models from the proxy and defaults to `grok-4.7`. Run
`grok login` once after linking its config; this stores a non-secret proxy
placeholder separately from your xAI login. Its config is
[`.grok/config.toml`](.grok/config.toml).

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

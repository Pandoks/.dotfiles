# dotfiles

**Opinionated macOS and Linux workstation configuration, managed by [mise].**

[![macOS](https://img.shields.io/badge/macOS-Apple_Silicon-000000?style=flat-square&logo=apple&logoColor=white)](#supported-systems)
[![Linux](https://img.shields.io/badge/Linux-Debian_%7C_Ubuntu_%7C_Arch-FCC624?style=flat-square&logo=linux&logoColor=black)](#supported-systems)
[![mise](https://img.shields.io/badge/managed_with-mise-2F80ED?style=flat-square)](https://mise.jdx.dev/)
[![Last commit](https://img.shields.io/github/last-commit/Pandoks/.dotfiles?style=flat-square)](https://github.com/Pandoks/.dotfiles/commits/master)

Installs system packages and developer tools, clones shell plugins, selects
Zsh, and links application config.

## Supported systems

| System                          | Package manager |
| ------------------------------- | --------------- |
| macOS on Apple Silicon          | Homebrew        |
| Debian / Ubuntu                 | apt             |
| Arch Linux                      | pacman          |

Other platforms are not configured.

## Install

Install Git and [mise] first.

### Debian / Ubuntu

```sh
sudo apt update
sudo apt install -y git extrepo
sudo extrepo enable mise
sudo extrepo enable tailscale
sudo apt update
sudo apt install -y mise
```

### Arch Linux

```sh
sudo pacman -Syu --needed git mise
```

### macOS (Apple Silicon)

Install the Xcode Command Line Tools and complete its prompt:

```sh
xcode-select --install
```

Then install [Homebrew] and mise:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
brew install mise
```

<details>
<summary>Disable SIP</summary>

Some features need [SIP] partially disabled.

1. Shut down, then hold power until startup options appear.
2. **Options → Continue**. Authenticate when prompted.
3. **Utilities → Terminal**, then run the command for your Mac and authenticate:

   ```sh
   # macOS 13+
   csrutil enable --without fs --without debug --without nvram

   # macOS 12
   csrutil disable --with kext --with dtrace --with basesystem
   ```

4. Restart into **normal macOS**, open the regular **Terminal** app, and check
   existing boot arguments:

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
   that is expected. Filesystem Protections, Debugging Restrictions, and NVRAM
   Protections should be disabled, while Kext Signing and DTrace Restrictions
   stay enabled. `nvram boot-args` should include `-arm64e_preview_abi`.

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
pass-cli login
chmod 700 "$HOME/.ssh"
```

Start Tailscale and join the tailnet:

```sh
sudo systemctl enable --now tailscaled  # Linux
sudo brew services start tailscale      # macOS
sudo tailscale up
```

The source of truth is
[`.config/mise/config.toml`](.config/mise/config.toml), with OS-specific
packages in the adjacent `config.linux.toml` and `config.macos.toml` files.

## Hub

The `tag:hub` machine hosts [CLIProxyAPI] and [Beszel]:

```sh
mise -E hub bootstrap --yes
sudo tailscale serve --service=svc:cliproxyapi --https=443 http://127.0.0.1:8317
sudo tailscale serve --service=svc:cliproxyapi-ci --https=443 http://127.0.0.1:8318
sudo tailscale serve --service=svc:beszel --https=443 http://127.0.0.1:8090
```

**CLIProxyAPI:** set `management.secret-key` in `~/.cli-proxy-api/config.yaml`
(never commit it), restart `dev.mise.cli-proxy-api`, then add accounts at
`https://cliproxyapi.<tailnet>.ts.net/management.html` with **WebSockets** on
for Codex accounts. In Claude Code, run `/login` once and don't set
`ANTHROPIC_AUTH_TOKEN`.

**Beszel:** create the admin and a permanent universal token at
`https://beszel.<tailnet>.ts.net`. On each machine, save the hub key (from
**Add System**) to `~/.config/beszel/key` and the token to
`~/.config/beszel/token`, then restart the agent:

```sh
systemctl --user restart dev.mise.beszel-agent                # Linux
launchctl kickstart -k "gui/$(id -u)/dev.mise.beszel-agent"   # macOS
```

## Grok

See [grok/README.md](grok/README.md).

[SIP]: https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection
[Beszel]: https://beszel.dev/
[CLIProxyAPI]: https://github.com/router-for-me/CLIProxyAPI
[Homebrew]: https://brew.sh/
[mise]: https://mise.jdx.dev/

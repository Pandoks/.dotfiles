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

On a Linux laptop that moved from iwd to NetworkManager, reconnect to Wi-Fi:

```sh
nmcli device wifi connect SSID --ask
```

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

The `tag:hub` machine hosts five tailnet-only services via
[`.config/mise/config.hub.toml`](.config/mise/config.hub.toml) and
[`.config/mise/hub/compose.yaml`](.config/mise/hub/compose.yaml):

| Service              | Tailnet endpoint                           | Local target              |
| -------------------- | ------------------------------------------ | ------------------------- |
| [CLIProxyAPI]        | `https://cliproxyapi.<tailnet>.ts.net`     | `127.0.0.1:8317`          |
| [Beszel]             | `https://beszel.<tailnet>.ts.net`          | `127.0.0.1:8090`          |
| [ARTEX]              | `https://artex.<tailnet>.ts.net`           | `127.0.0.1:8787`          |
| [MCPHub]             | `https://mcphub.<tailnet>.ts.net`          | `127.0.0.1:3000`          |
| [Proton Mail Bridge] | `protonmail-bridge.<tailnet>.ts.net`       | `127.0.0.1:1143`, `:1025` |

```sh
sudo pacman -Syu  # Arch Linux only
mise -E hub bootstrap --yes
sudo tailscale serve --service=svc:cliproxyapi --https=443 http://127.0.0.1:8317
sudo tailscale serve --service=svc:beszel --https=443 http://127.0.0.1:8090
sudo tailscale serve --service=svc:artex --https=443 http://127.0.0.1:8787
sudo tailscale serve --service=svc:mcphub --https=443 http://127.0.0.1:3000
sudo tailscale serve --service=svc:protonmail-bridge --tcp=1143 tcp://127.0.0.1:1143
sudo tailscale serve --service=svc:protonmail-bridge --tcp=1025 tcp://127.0.0.1:1025
```

<details>
<summary><strong>CLIProxyAPI</strong> — management key &amp; accounts</summary>

1. Set `management.secret-key` in `~/.cli-proxy-api/config.yaml` (never commit it) and restart `dev.mise.cli-proxy-api`.
2. Add accounts at `https://cliproxyapi.<tailnet>.ts.net/management.html` with **WebSockets** on for Codex.
3. In Claude Code, run `/login` once and leave `ANTHROPIC_AUTH_TOKEN` unset.
4. Put Console and AI Studio keys in the `keys` lists of `api-keys.claude` and `api-keys.gemini` in the same file (never commit them); only `api/<model>` requests use them.

</details>

<details>
<summary><strong>Beszel</strong> — hub token &amp; machine agents</summary>

1. At `https://beszel.<tailnet>.ts.net` (login is off), create `hub@beszel.local` (any password) and a permanent universal token.
2. On each machine, save the hub key (**Add System**) to `~/.config/beszel/key` and the token to `~/.config/beszel/token`, then restart the agent:

```sh
systemctl --user restart dev.mise.beszel-agent                # Linux
launchctl kickstart -k "gui/$(id -u)/dev.mise.beszel-agent"   # macOS
```

</details>

<details>
<summary><strong>MCPHub</strong> — upstream OAuth &amp; client wiring</summary>

1. Grab the first-boot `admin` password from `sudo docker logs hub-mcphub-1` and sign in at `https://mcphub.<tailnet>.ts.net`.
2. Turn off **Enable Bearer Authentication** under **Settings → Bearer authentication keys** (optionally turn on **Skip Authentication** under **Settings → Routing**).
3. Add upstream MCP servers — DCR providers (Notion, Linear, Figma, Cloudflare) work in one click; manual OAuth apps (Slack, Google) use callback `https://mcphub.<tailnet>.ts.net/oauth/callback`.
4. Antigravity and Codex are pre-wired; for Claude Code, run once per machine:

```sh
claude mcp add --transport http --scope user mcphub https://mcphub.<tailnet>.ts.net/mcp
```

</details>

<details>
<summary><strong>Proton Mail Bridge</strong> — pass keychain &amp; mail clients</summary>

1. Initialize `pass` and log in while the service is stopped:

```sh
gpg --batch --pinentry-mode loopback --passphrase '' \
  --quick-gen-key bridge@hub.local default default never
pass init bridge@hub.local
systemctl --user stop dev.mise.protonmail-bridge
mise -E hub exec -- bridge --cli  # updates autoupdates disable, login, info
systemctl --user start dev.mise.protonmail-bridge
```

2. Point clients at `protonmail-bridge.<tailnet>.ts.net` (IMAP `1143`, SMTP `1025`, STARTTLS) with the `info` credentials and accept Bridge's self-signed cert.

</details>

[SIP]: https://developer.apple.com/documentation/security/disabling-and-enabling-system-integrity-protection
[ARTEX]: https://github.com/jiwoochris/artex-global
[Beszel]: https://beszel.dev/
[CLIProxyAPI]: https://github.com/router-for-me/CLIProxyAPI
[Homebrew]: https://brew.sh/
[MCPHub]: https://github.com/samanhappy/mcphub
[mise]: https://mise.jdx.dev/
[Proton Mail Bridge]: https://proton.me/mail/bridge

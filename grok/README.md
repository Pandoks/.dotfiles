# Grok

The `grok` mise profile (`.config/mise/config.grok.toml`) gives Grok agents on this Mac Proton Pass,
Proton Mail, Proton Drive, and a Helium browser they can drive with Playwright. A plain
`mise bootstrap` leaves all of it out. Do these steps once per Mac, in order.

## 1. Install

```sh
cd ~/.dotfiles
sudo -v && mise -E grok bootstrap --yes
cp ~/grok/.env.example ~/grok/.env
```

List your Proton emails in `~/grok/.env`, comma-separated. Each becomes a himalaya account named
after the part before the `@`, and the first is the default:

```sh
GROK_PROTON_EMAILS=you@proton.me,another@proton.me
```

Then write the himalaya config. Run this again whenever you change `~/grok/.env`:

```sh
mise -E grok bootstrap --yes --only dotfiles
```

## 2. Proton Mail Bridge

Open Proton Mail Bridge, sign in to each account, and turn on start at login. Bridge must be
running for mail.

Bridge's default combined address mode puts all of an account's addresses in one mailbox with one
login, so list only that account's main address in `~/grok/.env`. In split address mode each
address has its own login, so list each one.

For each email in `~/grok/.env`, copy its password from Bridge into Keychain (`-w` last so it
prompts):

```sh
security add-generic-password -U -s grok-proton-bridge -a you@proton.me -w
```

Save Bridge's certificate:

```sh
openssl s_client -connect 127.0.0.1:1143 -starttls imap < /dev/null 2> /dev/null \
  | openssl x509 -out ~/grok/config/himalaya/proton-bridge-cert.pem
```

## 3. Proton Pass

`pass-cli` keeps one signed-in account per session directory. Sign in once per account, giving
each its own directory:

```sh
PROTON_PASS_SESSION_DIR=~/grok/config/proton-pass/pandoks pass-cli login
PROTON_PASS_SESSION_DIR=~/grok/config/proton-pass/manda pass-cli login
```

A web login lasts until `pass-cli logout`. Don't use `--pat` (tokens last 2 hours) or
`pass-cli session create-lock` (it locks agents out after an idle timeout).

## 4. Helium

`grok-browser` runs Helium on its own blank profile, separate from your main one: none of your
logins, extensions, or history carry over, and Chromium refuses remote debugging on the default
profile anyway. Create it and open it:

```sh
mkdir -m 700 ~/grok/config/helium-grokbot-profile
~/grok/bin/grok-browser start
```

In that window:

- **Extensions**: install any you want agents to use. Playwright can't click toolbar popups, but
  agents can open an extension's pages directly at `chrome-extension://<id>/...`.
- **Logins**: sign in to the sites agents should stay logged in to.
- **Proton Pass**: installing it here gives agents access to your vault in this browser. Your
  call.

Logins and extensions persist across restarts.

## 5. Check

```sh
PROTON_PASS_SESSION_DIR=~/grok/config/proton-pass/pandoks pass-cli info
himalaya=~/.local/share/mise/installs/aqua-pimalaya-himalaya/latest/himalaya
$himalaya account check
$himalaya account list
$himalaya --account <name> envelope list -s 5
~/grok/bin/grok-browser status
```

## How agents use it

| Tool | Command |
| --- | --- |
| Proton Pass | `PROTON_PASS_SESSION_DIR=~/grok/config/proton-pass/<account> pass-cli ...` |
| Proton Mail | `~/.local/share/mise/installs/aqua-pimalaya-himalaya/latest/himalaya ...` |
| Proton Drive | Plain file commands in `~/Library/CloudStorage/ProtonDrive-<account>` |
| Browser | `~/grok/bin/grok-browser start \| stop \| status \| run \| open \| screenshot \| dump` |

himalaya's mise shim only resolves with `MISE_ENV=grok`, hence the full path. It reads Bridge
passwords from your login keychain, so mail fails when that's locked, such as from an SSH-only
session. DevTools listens only on `127.0.0.1:9333`, but any local process can drive the
signed-in grokbot browser.

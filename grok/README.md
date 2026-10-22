# Grok

Proton Pass, Mail, Drive, and a Helium browser for Grok agents on this Mac.

```sh
sudo -v && mise -E grok bootstrap --yes
cp ~/grok/.env.example ~/grok/.env  # list your Proton emails, first is default
mise -E grok bootstrap --yes --only dotfiles
```

Rerun the last command after editing `~/grok/.env`.

## Proton Mail Bridge

Open Bridge, sign in to each account, and turn on start at login. In combined
address mode list only each account's main address; in split mode list every
address. Then, per email:

```sh
security add-generic-password -U -s grok-proton-bridge -a you@proton.me -w
```

Save Bridge's certificate:

```sh
openssl s_client -connect 127.0.0.1:1143 -starttls imap < /dev/null \
  2> /dev/null | openssl x509 -out ~/grok/config/himalaya/proton-bridge-cert.pem
```

## Proton Pass

Sign in once per account, each in its own session directory:

```sh
PROTON_PASS_SESSION_DIR=~/grok/config/proton-pass/<account> pass-cli login
```

## Helium

```sh
mkdir -m 700 ~/grok/config/helium-grokbot-profile
~/grok/bin/grok-browser start
```

Install extensions and sign in to sites in that window; they persist.

## Usage

```sh
PROTON_PASS_SESSION_DIR=~/grok/config/proton-pass/<account> pass-cli ...
~/.local/share/mise/installs/aqua-pimalaya-himalaya/latest/himalaya ...
~/grok/bin/grok-browser start | stop | status | run | open | screenshot | dump
```

Proton Drive is plain files in `~/Library/CloudStorage/ProtonDrive-<account>`.

# Grokbot Helium profile setup

`grok-browser` never creates its Helium profile. Set it up once by hand.

## 1. Create the profile directory

```sh
mkdir -p ~/grok/config
mkdir -m 700 ~/grok/config/helium-grokbot-profile
```

## 2. First launch

```sh
~/grok/bin/grok-browser start
```

Helium opens a new window on that profile with DevTools on `127.0.0.1:9333`.

This is a blank profile, separate from your main one: none of your main
profile's logins, extensions, or history carry over. That's on purpose, and
Chromium refuses remote debugging on the default profile anyway.

## 3. Set it up in that window

- **Extensions**: install any you want agents to use. Playwright can't click
  toolbar popups, but agents can open an extension's pages directly at
  `chrome-extension://<id>/...`.
- **Logins**: sign in to the sites agents should stay logged in to. Cookies
  stay in this profile.
- **Proton Pass**: installing it here gives agents access to your vault in this
  browser. Your call.

## Stop and check status

```sh
~/grok/bin/grok-browser status
~/grok/bin/grok-browser stop
```

Logins and extensions persist across restarts.

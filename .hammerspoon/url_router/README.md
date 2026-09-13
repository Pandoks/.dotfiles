# Hammerspoon URL Router

A background macOS app receives HTTP(S) links and calls Hammerspoon's
`RouteHTTPURL` through the `hs` CLI. The Chromium adapter routes each URL to
a Helium profile and prefers opening a tab in an existing matching window.
The Swift app falls back to launching Helium directly if the CLI is missing,
cannot start, or exits unsuccessfully.

## Setup

Requires macOS, the Swift command-line tools, Hammerspoon, and Helium installed
at `/Applications/Helium.app`. Hammerspoon needs Accessibility permission to
focus windows and Automation permission to insert tabs into Helium.

1. Load this repository's Hammerspoon configuration. `init.lua` enables `hs.ipc`
   and loads `url_router` independently of application hotkeys.
2. Run `zsh ~/.hammerspoon/url_router/install.sh`. This compiles and signs
   `~/Applications/Hammerspoon URL Router.app`, registers it, and sets it as the
   default HTTP and HTTPS handler. Approve any macOS default-browser prompt.
3. Open a link from another application to check profile selection and focus.

Configure ordered Lua URL patterns in `url_router/init.lua`. The first matching
rule chooses the profile by display name. If it cannot resolve that profile,
the adapter uses Helium's last-used profile, then `Personal`. The example rules
are disabled by default. Profile/window detection uses Chromium's `Local State`
and the window-title suffix ` - Helium - <profile>`.

## Development workflow

- Source of truth: local `master` in `/Users/pandoks/.dotfiles`.
- PR branch: `hammerspoon/url-router` in `/Users/pandoks/.dotfiles-url-router`.
- Make router changes on local `master` first. Preserve all local work there.
- Copy `.hammerspoon/url_router/` and
  `.hammerspoon/lib/window_adapters/chromium.lua` to the PR worktree.
- Mirror only router-specific startup changes in `.hammerspoon/init.lua`;
  do not copy unrelated local configuration or launcher changes.
- Validate in the PR worktree, then commit and push that branch to update the
  existing PR after each requested router update. Do not push local `master`.

For a manual end-to-end check, test an existing profile window, a profile with
no open window, a matching URL rule, and the direct fallback when Hammerspoon is
unavailable. These checks open browser windows and may change the default browser;
compilation and isolated Lua checks can be run without doing so.

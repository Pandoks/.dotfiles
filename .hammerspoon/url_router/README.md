# Hammerspoon URL Router

Ordered Lua rules choose an application or Helium profile. A selective hook in
macOS `swcd` sends matching Universal Link lookups to the same background helper
used for ordinary HTTP(S) URLs. The helper accepts URL events and browsing-web
activities, then invokes Hammerspoon. Unmatched lookups call Apple's original
implementation unchanged.

The helper remains the default HTTP and HTTPS application after activation.
Unmatched links delivered to it use native Universal Link handling, then Helium
when macOS reports no eligible native app. Other schemes and file URLs use the
registered application order, excluding the helper and Hammerspoon. Missing
Helium, invalid profiles, process errors, and denied native launches fail
explicitly with a log and popup. There is no second launch attempt after an
actual dispatch failure.

The native hook uses private macOS APIs. Installation is guarded to the tested
macOS 26.6.2 (25G83) and 27.0.1 (26A434), CSR mask `0x46`, and `-arm64e_preview_abi`
boot argument. On any other build, or any hook setup failure, `swcd` runs unhooked:
links keep native behavior and Hammerspoon reports the error.
This SIP configuration relaxes filesystem, debugging, and NVRAM protections;
authenticated root, kernel integrity, restricted entitlements, and explicit
library validation remain separate constraints. The hook does not require the
restricted `SFUniversalLink` entitlement. The helper is signed with the local
application identifier `LOCALPROBE.local.pandoks.HammerspoonURLRouter`. macOS
requires the identifier's prefix to have ten characters when decoding an app link.

## Setup

Requires Hammerspoon, Helium, Swift/Clang command-line tools, Python 3, and the
tested OS/SIP configuration. The installer never changes SIP or boot arguments,
logs out, reboots, or commits files.

1. Build an isolated payload with `zsh ~/.hammerspoon/url_router/install.sh prepare /var/tmp/url-router-ready`.
   The output directory must be new. This builds and signs the helper, hook, and
   readiness probe; it does not register an application or change live settings.
2. Run `zsh ~/.hammerspoon/url_router/install.sh stage /var/tmp/url-router-ready`.
   This saves the previous helper and each scheme's default, installs the new
   files, registers the helper, and stages a per-user launch job. Existing
   defaults and the live `swcd` job are retained during this step.
3. Reload Hammerspoon. Its router publishes an atomic selector snapshot and watches
   the pending status file. A pending installation does not execute rule actions.
4. Run `zsh ~/.hammerspoon/url_router/install.sh activate --warm`.
   Protected launchd operations request administrator authentication if needed.
   After authentication, one protected helper disables respawning, observes the
   retiring process, and waits for its exit event before replacing the job. This
   operation has a ten-second deadline. The installer performs one harmless native lookup,
   waits for the hook's readiness acknowledgement without polling, and verifies
   that acknowledgement belongs to the replacement process. It starts the helper
   and verifies the running application's path. A native lookup from the helper
   refreshes LaunchServices' connection to the replacement service without opening
   a browser or replaying a user URL. Only then does it
   set the helper as the HTTP and HTTPS default. Already configured schemes skip
   redundant macOS prompts. A failed activation reverses the installation.
5. Run `zsh ~/.hammerspoon/url_router/install.sh status` and verify a configured
   profile link plus an unmatched native link. A successful status reports
   `"acknowledged": true` for the current process, generation, and selector bytes.

For activation at a clean login instead, use `activate --login`, log out/reboot
manually, then run `install.sh finish`. The current process is left running
until the session ends. The helper becomes the default only after `finish`
confirms the new job is ready. Schedule the clean login promptly: a disabled
Apple job cannot respawn if its existing process exits beforehand.

`zsh ~/.hammerspoon/url_router/install.sh uninstall` restores the previous HTTP
and HTTPS defaults, previous helper, and Apple's original launch job. It removes
the installed runtime and cloned job. Reload Hammerspoon afterward. Selector
snapshots are retained because they belong to the Hammerspoon configuration.
Restoration also refreshes the native-link client before reporting success, so
the first subsequent native link uses Apple's restored service. An interrupted
cleanup can be completed by running `uninstall` again after resolving its error.
The clone stays disabled until its plist is removed, and each resumed cleanup
reconciles the live service even if the runtime and backup are already gone.
Restoration uses the public native-link client without the hook's OS/ABI guard;
activation and completion retain their strict compatibility checks.
An altered installed helper or backup is preserved and reported instead of
being deleted. No existing installation is overwritten implicitly.
Prepared payloads and backups use `.bundle` directories to avoid registering
additional copies of the helper with LaunchServices. A running helper at the
installation path is terminated before replacement or restoration.

## Rules and reloads

Edit ordered rules in `url_router/init.lua`, then reload Hammerspoon. A `host`
selector includes subdomains; a `pattern` selector uses Lua patterns against the
complete URL. The first match invokes `open(url)`, which returns a boolean.
Actions may accept a second `report(message)` argument to supply failure details.
The router logs and displays each declined, thrown, or invalid action result once;
Chromium actions retain their own reporting when called directly.
`chromium.url({ bundleID = "net.imput.helium", profile = "Work" })` selects a
Chromium profile by its display name from `Local State`; browser tab/window
behavior remains under the browser's control.
`notion.url({ workspaces = { ["sieve-data"] = work }, default = personal, lookup = true })`
picks an action by the workspace in a Notion link. With `lookup`, links that only
carry a page ID ask Notion's undocumented `getPublicPageData` endpoint for the
workspace (3-second limit); a failed lookup is reported and opens nothing.

The published JSON contains selectors only, not Lua action functions. The hook
loads selectors into the same Lua version and acknowledges their UUID generation
and SHA-256 bytes through an atomic status file. Filesystem notifications update
both sides. The helper passes the acknowledged generation to
`RouteHTTPURL(url, generation)`; Hammerspoon blocks actions until that generation
is ready and belongs to a live `swcd`. Reload failures are explicit rather than
silently mixing old selectors with new actions.

Runtime files are under `~/Library/Application Support/HammerspoonURLRouter/`.
`state.json` records restoration paths and the status location;
`selectors/rules.json` holds the selectors. The cloned job is
`~/Library/LaunchAgents/local.pandoks.HammerspoonURLRouter.swcd.plist`.
It preserves Apple's Mach service, launch events, and execution settings, changing
only its label and hook environment. Status lives in the user's Darwin temporary
directory because the `swcd` sandbox cannot write ordinary support directories.
Both sides recreate the private status directory after a clean shutdown.
Keep Hammerspoon's launch-at-login setting enabled.
Hammerspoon failures go to `~/Library/Logs/Hammerspoon/config.log`; the helper
and installer also use the system log and popups. The helper rejects dispatch
when Hammerspoon is stopped, and bounds process exit and output completion to
fifteen seconds. A background GCD queue drains output, retains at most 4 KiB of
diagnostics, and force-terminates an unfinished CLI at the deadline, including
while another failure popup occupies the main actor.

## Coverage and limits

The preceding investigation tested selective redirection in an isolated macOS VM
with matching OS/SIP settings, including real Work/Personal profile delivery,
live selector reload, process restart, and clean reboot persistence. It also
established that suppression alone fails callers requiring a native application.
The production installer has also passed isolated VM warm activation, first-link
delivery with callers requiring a native app, real Work/Personal browser history,
live generation reload, stopped-Hammerspoon errors, and restoration of the old
helper, default handlers, and Apple launch job. A clean reboot also passed first
Work/Personal native-required links without a daemon warm-up query; browser
history confirmed their profiles and Notion received the unmatched link.

App-targeted Apple Events and links opened internally by another app do not make
an association lookup and remain outside the hook. The helper cannot recover the
originating app's click context. macOS updates may change private method signatures
or launch-job behavior; mismatches fail explicitly and require a new investigation.

Run `sh ~/.hammerspoon/tests/run.sh` for isolated rules, profiles, selector
transport, native dispatch, Swift bridging, signing, and installer checks.
Installer tests exercise real builds and filesystem rollback while stubbing
system registration/default APIs; they do not replace real session delivery,
administrator authentication, or reboot checks. A manual check should open a
configured profile link, an unmatched local web page, and a Universal Link for an
installed native app, then verify unavailable Hammerspoon is reported explicitly.

The helper's `--inspect HTTP_URL [HTTP_URL ...]` command is a separate read-only
`SFUniversalLink` signing experiment. [SIGNING.md](SIGNING.md) describes its
restricted entitlement and authorized provisioning requirements. SIP settings do
not grant that entitlement.

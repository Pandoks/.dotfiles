# Hammerspoon URL Router

Ordered Lua rules choose an application or Helium profile. A selective hook in
macOS `swcd` sends matching Universal Link lookups to the same background helper
used for ordinary HTTP(S) URLs. The helper accepts URL events and browsing-web
activities, then sends them to Hammerspoon over a Mach message port. Unmatched
lookups call Apple's original implementation unchanged while the selectors are
valid. Invalid selectors make matched and unmatched HTTP(S) Universal Links fail
closed, so a routed link such as a Notion page doesn't fall through to its native
app. Matched links also fail until the hook acknowledges their selector
generation. If the selector directory is removed or replaced while `swcd` runs,
the hook instead hands every lookup back to Apple and reports the error, so routed
links can open their native apps until `swcd` restarts.

The helper remains the default HTTP and HTTPS application after activation.
Unmatched links delivered to it use native Universal Link handling, then Helium
when macOS reports no eligible native app. Other schemes and file URLs use the
registered application order, excluding the helper and Hammerspoon. Missing
Helium, invalid profiles, process errors, and denied native launches fail
explicitly with a log and popup. There is no second launch attempt after an
actual dispatch failure.

The native hook uses private macOS APIs. Installation is guarded to the tested
macOS 26.6.2 (25G83) and 27.0.1 (26A434), CSR mask `0x46`, and `-arm64e_preview_abi`
boot argument. On any other build, or any hook setup failure, `swcd` keeps running
unhooked, so apps' own Universal Links still open natively. The helper rejects web
links with a popup until the hook is ready; Hammerspoon also reports the error
whenever the hook can write its status file.
This SIP configuration relaxes filesystem, debugging, and NVRAM protections;
authenticated root, kernel integrity, restricted entitlements, and explicit
library validation remain separate constraints. The hook does not require the
restricted `SFUniversalLink` entitlement. The helper is signed with the local
application identifier `LOCALPROBE.local.pandoks.HammerspoonURLRouter`. macOS
requires the identifier's prefix to have ten characters when decoding an app link.

## Setup

Requires Hammerspoon, Helium, the Xcode command-line tools, Python 3, and the
tested OS/SIP configuration. The protected `swcd` replacement and restoration
run under the command-line tools' root-owned Python; `activate --login` and the
final clone re-enable call `/bin/launchctl` directly. The installer never changes
SIP or boot arguments, logs out, reboots, or commits files.
`zsh ~/.hammerspoon/url_router/install.sh check` prints the macOS version, build,
and SIP mask as JSON (`"csr": 70` is `0x46`), or fails naming the first unmet
requirement: SIP mask, tested build, boot argument, or command-line tools'
Python. It changes nothing; `prepare`, `stage`, and `activate` repeat the same
checks.

To upgrade an installation staged before the status file moved to the cache
directory, uninstall it with its own copy first, because this installer rejects
its state:
`/Library/Developer/CommandLineTools/usr/bin/python3 -I ~/Library/Application\ Support/HammerspoonURLRouter/runtime/install.py uninstall`.
Then follow the steps below.

1. Build an isolated payload with `zsh ~/.hammerspoon/url_router/install.sh prepare /var/tmp/url-router-ready`.
   The output directory must be new. This downloads Lua 5.4.9 from lua.org,
   rejects it unless it matches a pinned SHA-256 checksum, then builds and signs
   the helper, hook, and readiness probe. It does not register an application or
   change live settings.
2. Run `zsh ~/.hammerspoon/url_router/install.sh stage /var/tmp/url-router-ready`.
   This saves the previous helper and each scheme's default, installs the new
   files, registers the helper, and stages a disabled per-user launch job. Existing
   defaults and the live `swcd` job are retained during this step.
3. Reload Hammerspoon. Its router publishes an atomic selector snapshot and watches
   the pending status file. A pending installation does not execute rule actions.
4. Run `zsh ~/.hammerspoon/url_router/install.sh activate --warm`.
   Protected launchd operations request administrator authentication if needed.
   After authentication, one protected helper disables respawning, observes the
   retiring process, and waits for its exit event before starting the replacement
   job. If any step fails, the same helper restores Apple's job once the retiring
   process exits. Retirement has a ten-second deadline and the restore gets ten
   more, so a failed activation can take about 20 seconds. The installer performs
   one harmless native lookup, waits for the hook's readiness acknowledgement
   without polling, and verifies that acknowledgement belongs to the replacement
   process. It starts the helper and verifies the running application's path. A
   native lookup from the helper refreshes LaunchServices' connection to the
   replacement service without opening a browser or replaying a user URL. Only
   then does it set the helper as the HTTP and HTTPS default. Already configured
   schemes skip redundant macOS prompts. A failed activation reverses the
   installation. If that rollback fails, resolve its error and run
   `install.sh uninstall`; `activate` refuses while the clone is loaded.
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
the installed runtime and cloned job. Defaults are restored first: if the saved
browser is missing or macOS's prompt is refused, the hook keeps serving links
until a rerun succeeds. Reload Hammerspoon afterward. Selector
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
selector ignores case and includes subdomains; a `pattern` selector uses Lua
patterns against the complete URL. The first match invokes `open(url)`, which
returns a boolean. Actions may accept a second `report(message)` argument to
supply failure details.
The router logs and displays each declined, thrown, or invalid action result once;
Chromium actions retain their own reporting when called directly.
`chromium.url({ bundleID = "net.imput.helium", profile = "Work" })` selects a
Chromium profile by its display name from `Local State` and launches the browser
through `open -n -b`, so a cold-launched browser never belongs to Hammerspoon or
dies on reload. A running browser takes the link and the extra instance exits;
browser tab/window behavior remains under the browser's control.
`router.by(adapter, { key = action }, default)` opens a URL with the action for the
key its adapter finds. An adapter in `lib/url_adapters/` only finds the key and
calls `done(key)` or `done(nil, error)`, now or later; an error is reported and
opens nothing. `notion.workspace({ lookup = true })` finds the workspace domain;
`lookup` asks Notion's undocumented `getPublicPageData` endpoint about links that
only carry a page ID, dashed or not (3-second limit). Reloading Hammerspoon during
that lookup stops it, so the link opens nothing and shows no popup.

The published JSON contains selectors only, not Lua action functions. The hook
loads selectors into an embedded Lua 5.4 and acknowledges their UUID generation
and SHA-256 bytes through an atomic status file. Filesystem notifications update
both sides. The helper sends message 1 with `generation\nurl` to Hammerspoon's
`local.pandoks.HammerspoonURLRouter.route` CFMessagePort, which replies `true`,
`false`, or `native`. Hammerspoon blocks actions until a hook acknowledges that
generation and its selector bytes. launchd stops an idle `swcd` and relaunches it
on the next lookup with the same selectors, so its exit, or a ready status naming
an exited or reused process ID, keeps routing ready; Hammerspoon watches the
relaunched process once its status arrives. Exits during uninstall still stop
routing.
Reload failures are explicit rather than silently mixing old selectors with new
actions. `RouteHTTPURL(url, generation)` remains for `hs -c` debugging and for
helpers built before the port existed.

Runtime files are under `~/Library/Application Support/HammerspoonURLRouter/`.
`state.json` records restoration paths and the status location;
`selectors/rules.json` holds the selectors. The cloned job is
`~/Library/LaunchAgents/local.pandoks.HammerspoonURLRouter.swcd.plist`.
It preserves Apple's Mach service, launch events, and execution settings, changing
only its label and hook environment. Status lives in the user's Darwin cache
directory because the `swcd` sandbox cannot write ordinary support directories,
and dirhelper's daily cleanup skips it. The hook recreates the private status
directory before each write; Hammerspoon creates it when it starts watching.
After the selector directory is removed or replaced, a Hammerspoon reload alone
leaves the status at `error`: reload, then restart the clone with
`launchctl kickstart -k gui/$(id -u)/local.pandoks.HammerspoonURLRouter.swcd`.
Keep Hammerspoon's launch-at-login setting enabled.
Hammerspoon failures go to `~/Library/Logs/Hammerspoon/config.log`; the helper
and installer also use the system log and popups. The helper rejects dispatch
when Hammerspoon is stopped or its port is missing. A background serial queue sends
one request at a time with a 5-second send and 10-second reply timeout, so another
failure popup on the main actor can't stall it. Links in one batch wait their turn:
if Hammerspoon stops replying, the links its port queues each wait out the
10-second reply deadline and later ones fail their 5-second send, so the tenth of
ten links reported after about 65 seconds in testing; one link waits at most 15
seconds.
Hammerspoon may still act on a request after its reply deadline.

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
history confirmed their profiles and a native app received the unmatched link.

App-targeted Apple Events and links opened internally by another app do not make
an association lookup and remain outside the hook. The helper cannot recover the
originating app's click context. macOS updates may change private method signatures
or launch-job behavior; mismatches fail explicitly and require a new investigation.

Run `sh ~/.hammerspoon/tests/run.sh` for isolated rules, profiles, selector
transport, native dispatch, Swift bridging, and installer checks.
Installer tests exercise real builds and filesystem rollback while stubbing
system registration/default APIs; they do not replace real session delivery,
administrator authentication, or reboot checks. A manual check should open a
configured profile link, an unmatched local web page, and a Universal Link for an
installed native app, then verify unavailable Hammerspoon is reported explicitly.

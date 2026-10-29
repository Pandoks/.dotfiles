# Window switcher tests

Run `sh .hammerspoon/tests/run.sh` from the dotfiles root. The tests use the Lua
runtime bundled with Hammerspoon and require the Xcode Command Line Tools.
Set `HAMMERSPOON_APP` if Hammerspoon is installed outside `/Applications`.

The observer suite rejects all timer use and checks initialization, shared
subscriptions, cached IDs after destruction, background focus, stale callbacks,
registration failures, silent accessory/nonstandard-window exclusion, logged
tracking failures with popups and no retries, and shutdown. The switcher suite
checks that explicit action failures still log and show popups.

The tiling suite loads `lib/tiling.lua` against a 1000x600 model display and
checks the frames it requests: longer-side splits for new windows, the app
allowlist, Picture-in-Picture (including a later title change) left untouched,
sibling reclaim on close, directional focus, swap, warp, edge resize that never
falls back to the opposite edge, balance, zoom, and float. The window manager suite checks
that a Space jump posts all its swipes at once and reports once on arrival, and that
a press during a jump continues from that jump's target. It also checks that loading starts
one background window search, so the first Cmd-Tab finds windows on other Spaces cached.
Neither touches the real window server; the native gesture, focus, and Accessibility calls in
`lib/window_manager/window_manager.m` were checked manually on macOS 27.0.1.

Run `sh .hammerspoon/tests/previews_test.sh` for the native preview worker pool.
It uses synthetic images and windows, without Screen Recording access or UI changes.
The tests verify four concurrent captures, progressive main-thread delivery,
real bitmap resizing, a 100-window cache below 47 MiB of pixel data, cancellation,
garbage collection, window-ID reuse, capture failures, and Lua reload with work pending.

Previews use `CGSHWCaptureWindowList` at nominal resolution on four background
workers. SkyLight ownership checks include minimized windows and reject reused IDs
before and after capture. Each worker produces a real sRGB bitmap fitting 460x260
pixels, preserving aspect ratio, before releasing the source image. Cached images
appear immediately after the existing 200 ms menu delay; fresh images replace them
progressively, with callbacks coalesced into the next render pass. The cache has no
time limit: entries stay in memory until their window is destroyed or absent from
the next eligible-window query, or Hammerspoon reloads.

Only the selected window and visible cards are captured. Minimized and hidden
windows use the cached thumbnail or app icon without requesting menu captures.
If capture fails, the last cached thumbnail stays visible, or the app icon when no
cached image exists. Preview failures never log errors or show popups.
A new selection or viewport
cancels obsolete queued work and prioritizes the remaining visible previews; already
completed thumbnails stay cached. Scrolling can populate the cache for all windows
without capturing the entire list on every invocation. Creation, resize, title,
minimize, restore, and hide events refresh affected visible cards while the menu is open.
Minimize and hide notifications also capture the affected window once while the
menu is closed or its card is offscreen, retaining the handle until completion.
These captures survive closing the menu; an open menu shares their results without
requesting the same image again. Independent requests share all four native workers.
New state events supersede older pending captures. Destruction, identity changes,
and shutdown cancel pending work and discard late results. Other idle window events
never capture, timers never poll, and failed captures are not retried within the
batch. Fresh menu captures resume after the window is restored and unhidden,
superseding any pending final snapshot. Windows already minimized or hidden when
Hammerspoon reloads show their app icon until a snapshot becomes available.
Final captures are best-effort when the notification arrives; macOS may already
have removed the image. Failures silently keep the previous cache entry.

`lib.previews.capture(windows, callback)` calls `callback(id, image, error)` for each
finished window, then `callback(nil, nil, nil)` once when the batch finishes. A nil
image with no error means the window identity disappeared or changed. Releasing or
cancelling the menu skips queued work and discards late results. Native callbacks
remain safe across Hammerspoon reloads. Keep the returned cancellation function
alive until capture completes; collecting it cancels the batch.

While Cmd-Tab is open, Accessibility creation events append new windows without
reordering existing cards or changing the selection. Only missing visible previews need
capturing. Events received during the initial window query are merged into its
reply, so a stale list cannot lose a new window or restore a closed one. Closing
windows removes their cards and preserves selection on the same surviving window.
A title change into Picture-in-Picture removes the card the same way; a change out of it
adds the card like a new window. Creation events for windows that vanish before they can
be read are ignored. App icons are cached by bundle identifier, so a reused process ID
cannot show another app's icon.

The real switcher runs in an isolated model of Hammerspoon, `lib.window_manager` replies,
`lib.window_filter` deliveries of already-admitted windows (admission itself is checked by
the observer suite),
window focus, event notifications, and timers. The suite does not launch
Hammerspoon, send input, or focus windows.

The suite covers pointer boundaries, gaps, incomplete rows, scrolling and clipping,
keyboard navigation, clicks, focus-first ordering, stale replies, timeouts,
concurrent requests, and unavailable or reused windows.

Menu layout responds to both dimensions of the usable frame of the focused Space's display,
resolved through `hs.spaces.spaceDisplay(hs.spaces.focusedSpace())` because
`hs.screen.mainScreen()` can stay on another display while a fullscreen app has focus. If
that display cannot be resolved, Cmd-Tab logs and opens no menu. Its popup, a toast, has no
display either, so it is only printed to the log.
Width adds columns, height adds visible rows, and cards adapt between 180 and 320
logical points (smaller only if a tiny display cannot fit one card). Preferred card
size follows the shorter screen dimension, so ultrawides cannot inflate previews.
The grid fits within 85% of each dimension and prefers more visible windows, then
larger cards and fewer rows. It scrolls when fitting more windows would make the
previews too small. Labels, icons, gaps, and trackpad distances stay in screen points.
The layout is reused while navigating and recomputed when the window count changes.

The suite checks centered geometry, bounded preview sizes, independent width/height
capacity, pointer selection, scrolling, and keyboard access across built-in, external,
4K, ultrawide, portrait, compact, and very short simulated display rectangles.
It runs the production renderer against synthetic windows; native offscreen
`hs.canvas:imageFromCanvas()` captures can show the same output without creating
virtual monitors or moving real windows.

The Space-focus suite also checks numbered/Ctrl-arrow shortcuts, Space arrival
before or after the `window_manager.space` reply, arrival timeouts, superseded requests,
direct Space notifications, late PiP focus, per-Space window identity, empty desktop fallback,
explicit mouse intent, superseded replies, shutdown, and idle snapshot activity.
It also checks PiP activation redirects, display boundaries, repeated presses during
a pending switch, and Mission Control key passthrough and focus suppression. Its window
model keeps untracked, minimized, hidden, layer-3, and other-display windows out of the
candidates.

Ctrl-Left/Right use `window_manager.space` outside Mission Control and stop at the current display's
first/last Space. Numbered shortcuts use global Mission Control indices. Shortcuts take
each Space's display from the same `utils.spaces()` read; only native Space changes
call `hs.spaces.spaceDisplay`. The mouse-intent tap starts once at load and stops only
with `stop()`. Keep
macOS Keyboard Shortcuts > Mission Control > Move left/right a space enabled with
Ctrl-Left/Right: inside Mission Control, Hammerspoon passes the original keys to
macOS so the overview stays open and uses the native animation.

Keep Desktop & Dock > Mission Control > "When switching to an application, switch
to a Space with open windows for the application" on, so macOS moves to the
activated app's Space. When a Dock click,
link, or other activation gives that app's PiP focus within 0.5 s, focus continues
to the app's latest real window unless the pointer is over the PiP. The rule stays
armed for those 0.5 s, so a PiP that retakes focus after the redirect is redirected
again. Later PiP focus, e.g. after closing a window, stays on the current Space. The PiP
title and bounds come from the WindowServer list (the title from the tracked window when
the list omits it without Screen Recording); an activation asks the app for its
focused window only when that list shows a PiP it owns. The target is the app's
tracked, unminimized non-PiP window with the latest switcher recency (seeded at load from
the WindowServer's front-to-back on-screen order; lowest window ID for windows on other
Spaces, minimized, or hidden at load), read from `lib.window_filter` without a window-list
query. A failed focus command logs with a popup and is not retried. Space jobs and their transitions
take priority.

`window_manager.space` posts one synthetic swipe per Space at once, so the display goes
straight to the target without showing the Spaces between, and replies once
the display shows the target, or at once when it already does. Focus can report the
new Space just after the display does, so the reply, Space notification, or app/window
focus event that first sees the target Space starts focus restoration. Failed replies
stop immediately; a Space that never arrives times out after 1.5 s. Each failure logs
once with a popup.
Space shortcuts keep one current job for the switch and focus restoration.
A new shortcut cancels the old job's timers and ignores its replies, then calls
`window_manager.space` immediately without waiting for the previous Space or focus reply;
`window_manager.space` reports the older request as superseded.
Only the current job can continue after a reply. Focus and desktop-click actions
yield to the next run-loop turn so a newer shortcut can cancel them before dispatch.
A swipe already posted or a running native call cannot be recalled.
There is no Space-command queue or retry.
Mission Control state is read from the Dock's `mc` element on each check, because macOS 27
no longer posts the Dock's overview notifications; a relaunched Dock is picked up on launch.
The switcher counts as busy from the Cmd-Tab press, before its menu shows, until the chosen
window has focus. Switcher busy checks do
not inspect screen-recording permission. Focus validation checks the current Space after the
other state checks, so a Space change during those checks cannot focus an old window.

Focus restoration reads the Space synchronously in-process: `hs.window.list()` for the
WindowServer's front-to-back on-screen windows, limited to those centered in the Space
display's `fullFrame()`, plus `hs.window.focusedWindow()` and
`lib.window_filter.windowsOf` for tracked windows. Candidates are tracked layer-0
windows; any layer 0-19 window, including a layer-3 PiP, blocks the desktop-click point.
This never waits behind a busy app; it measured about 2-3 ms. A Space whose display
cannot be found fails once with a popup.

Space information, including each Space's display UUID, comes from one native snapshot
per lookup. Cmd-Tab and Space
focus use command callbacks and application/window/Space notifications. Our helpers
perform no timed recovery queries or action retries. Deadlines only cancel, log, and
show an alert; they do not inspect state or try again.
A missing completion notification can therefore report a timeout even if macOS
has already changed focus. Window subscriptions use `lib.window_filter`, a shared
Accessibility observer per application, rather than `hs.window.filter`. Missing IDs,
observer errors, and unsupported notifications stop tracking the affected process or element and log
the operation that failed. Space notifications first detach exited apps via `isRunning()`,
even before their termination callbacks arrive, then re-scan only apps with on-screen
windows; they never list running applications.
Top-level, nonmodal `AXDialog` windows with an enabled minimize button are tracked
as normal switcher windows, including Maps while minimized. Dialogs without that
capability, system dialogs, floating panels, and child windows remain excluded.
Tracking failures recheck process liveness: an exited app is removed quietly,
including its cached windows; a running app still logs and shows a popup once, then
stops the affected observer or window registration and sends `windowDestroyed` for
windows it had already published. No Accessibility request is retried.
Failed registrations are not retried; relaunch the app or reload Hammerspoon
to try again. Accessory/menu-bar apps, background helpers, and nonstandard windows
are excluded before registration, except fullscreen `AXUnknown` windows. Borderless
fullscreen windows such as VLC are recognized by their screen bounds when
`AXFullScreen` is false. PiP and fullscreen control dialogs stay excluded.
Regular applications' background document windows
remain available, but their focus events are ignored before reading the window.
Foreground checks compare with the system's frontmost app instead of asking the app.
Standard windows and each app's main document window are seeded once, including
main windows on inactive Spaces. Later discovery uses creation, foreground focus,
or Space notifications. Activation during an app's launch waits for the launch-complete
event before accessing Accessibility, so early activation cannot permanently fail
its observer. Background launches attach at completion without waiting for focus.
An app seeded by a reload before its launch completed, and whose setup failed, is attached
once more when its launch-complete event arrives.

Command failures are logged when their callbacks return. Log output goes to the
Hammerspoon console and, through lib.logger, ~/Library/Logs/Hammerspoon/config.log.
Failed focus, resize, and app activation/unhide actions log, alert, and
stop without trying another method. Cmd-Tab requests unhide once through Accessibility
and waits for the matching application's unhidden notification before restoring or
focusing the selected window. Immediate completion proceeds directly. Request errors,
app exit, and the existing deadline stop the operation and remove its temporary watcher;
there is no polling or repeated unhide. This avoids treating Hammerspoon's immediate
hidden-state check as a failed request.
Cmd-Tab lists windows with `window_manager.windows`, taking app names, focus, and hidden state
from `hs.application` and `hs.window`. It focuses the exact window with `window_manager.focus`,
which first shows the window's Space through `window_manager.space` when another Space is on
screen. `hs.window.focusedWindow()` confirms focus on the reply or the window-focused
event, whichever comes first, without another window query.
The 200 ms menu delay only controls preview visibility; a quick Cmd-Tab release does
not wait for it.
Once Cmd is released, keys are no longer intercepted while the window list is pending, so
typing reaches the app and cannot change the chosen window. A new Cmd-Tab in that interval
starts a new cycle and drops the released one.

For a live check after reloading Hammerspoon:

1. Hold Cmd-Tab and move through the gaps and outer padding. The nearest visible
   card should highlight; moving outside the menu should preserve selection.
2. Scroll a long list. Fully clipped cards should not be selectable; arrow keys
   should still reveal the selected window.
3. Select a window on the other monitor, including its topmost window, and return.
4. Select a window on an inactive Space. Confirm the Space changes without
   animation, the exact window receives focus, and no timeout alert appears.
5. Check `require("lib.window_switcher").status()` in the Hammerspoon console.
   `busy` should be false after switching, and `active` should be true.
   Include VLC's borderless fullscreen video from another Space: it should appear,
   receive focus, and switch back without including its Fullscreen Controls panel.
6. With PiP open, use Alt-number and Ctrl-Left/Right to enter an occupied Space.
   A normal window on that Space should receive focus. Repeat with a trackpad
   swipe to exercise the watcher.
7. Enter an empty Space. Focus should go to uncovered desktop, with PiP remaining
   visible. The Space and pointer position must not change again. Clicking PiP deliberately should
   still work.
8. Check `require("lib.space_focus").status()`: `active` should be true and `busy`
   false after settling. `last` records the most recent correction result.
9. Open Mission Control and press Ctrl-Left/Right. The overview should stay open
   while Spaces change, with no Space focus error or automatic desktop click.
   Exit Mission Control; the same shortcuts should switch instantly.
10. With Spaces split across monitors, press repeatedly at each monitor's first
    and last Space. The other monitor must stay on its current Space. Repeat
    rapidly while approaching the boundary, including with PiP open.
11. From another Space, click a normal app in the Dock once; its window should
    receive focus. Repeat with an app whose PiP is open (its latest real window
    should receive focus), a second instance's Dock icon, and the PiP itself
    (PiP should keep focus).
12. Keep Cmd-Tab held while another app opens a window. Its card and preview should
    appear without changing the selection. Close a window while the menu is open;
    its card should disappear. Release Cmd before a preview finishes and confirm
    the menu stays closed.

The logger Lua regressions also run with `tests/run.sh`, as does the toast suite: placement at the
bottom right of the focused Space's display just below the Dock's level (without one, the text is
printed to the log, nothing is shown, and no error is raised), stacking, repeats, dismissal (on
release, as the window server puts back a window ordered out under a held left click, so a pressed
toast outlasts its timeout and `closeAll` until let go, and the cap passes it over; one closed under
a press Hammerspoon has yet to see is ordered out at alpha 0 after any fade, comes back unseen when
let go right after, and is still collected; clicks pass through a fading toast; and the rest of a
multi-click that closed a toast reaches nothing, each mouse-up going where its button's mouse-down
went), wrapping, themes, light and dark (each drawn in its own colors; `system`, the default,
starts as macOS is and redraws shown toasts in place when macOS switches, as installing again does
in its theme; an unknown appearance fails the load), and every `hs.alert` call routed through
`lib/toast.lua` with its screen, seconds, and id. It also checks that the glass theme gives each
toast its own glass, in the toast's appearance, hidden with the toast's fade, under shadowed text
that goes with the theme, and that a failed build of `lib/toast/toast.m` (stubbed) fails the load.
Its look was checked with real `hs.canvas` renders, in light and dark.
The glass window was checked live on macOS 27.0.1: it refracts what is behind it, another app's
window too (lensing at the edges, a rim highlight), though its panel is never key; it moves with its
toast, clicks still reach the toast, a glass collected during its fade stays until the fade ends,
and no window is left after a toast times out or its glass is collected. Multi-clicks posted with
their click states set by hand (double, triple with clicks 0.35 s apart, and right-button double)
were checked live on macOS 27.0.1 in all four themes: each closed only its toast, and its later
clicks reached none of the toast moving into its place, one shown between the clicks, or the window
beneath. A click and a double-click elsewhere afterwards reached the window there, mouse-ups
included, and with each down and up 0.09 s apart, a toast clicked as a double-click's second click,
or with the right button while the left was held, left no button reported as held. Neither did a
double-click with button 4 while the middle button was held and let go. With clicks posted at the
HID level, no closed toast's window was left visible. A press Hammerspoon saw, 20 to 456 ms before a
toast's timeout, `closeAll`, `closeSpecific` or the cap, closed the toast on release. Under one it
had yet to see, from 35 ms before them to 13 ms after while the window was still there, held 1.2 s
or 3 s, the toast came back at alpha 0 after its 0.25 s or 2 s fade if it had one, let clicks
through, and stayed until garbage collection; so did one let go 0 to 164 ms after its faded window
was ordered out. A fade held up while Hammerspoon was busy still ended at alpha 0. A switch of
macOS's appearance was simulated live on macOS 27.0.1, leaving the real one alone: with
`hs.host.interfaceStyle` stubbed and the notification posted under a private name, shown metal and
glass toasts were redrawn in place (same windows, order, positions, timers and glass), each glass
panel turned light or dark, and a click still closed a toast on release; in metal, a double-click
closed only its toast. A toast held through the switch was redrawn and closed on release, one
switched 40 ms into its fade-in ended opaque in the new colors, one fading out kept its colors and
ended at alpha 0, and toasts after a repeat kept their places and timers.

Audit checks (substitute the installed executable paths if needed):

```sh
lua-language-server --check="$PWD" --checklevel=Hint --logpath=/var/tmp/hammerspoon-luals
stylua --check .
shellcheck tests/*.sh
```

For preview checks after reloading:

1. With Cmd-Tab closed, minimize a window or hide its app, then open Cmd-Tab.
   A successful state-event capture should already be cached. Repeat with the menu
   open and with a card outside its viewport; closing the menu must not cancel the
   final capture. Failed captures should silently keep the cached image, or the
   app icon when uncached. Check normal, hidden, and minimized windows; none should
   show a preview alert.
2. Scroll or move the selection while captures are pending. Newly visible cards
   should take priority; completed images should stay visible and selection should
   not move as previews arrive.
3. Hidden and minimized previews should stay full size at 20% opacity, with a bright
   icon centered over the preview: a closed eye for hidden windows, or the Lucide
   minimize icon for minimized windows. The minimize icon takes priority when both
   states apply.
   Dimmed thumbnails fade toward black, including dark content on selected cards. Resize,
   hide, unhide, or minimize a window while the menu is open and confirm its preview
   and state indicator update.
   Close the menu while work is pending; late callbacks must not
   reopen it or seed a reused window ID.
4. Open the same window list on the built-in and external displays. The menu should
   occupy the same proportion of their widths, with matching proportions for text,
   icons, and spacing. Hover, click, and scroll near the edges to confirm selection
   follows the visible cards.

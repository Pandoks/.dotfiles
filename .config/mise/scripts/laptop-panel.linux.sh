#!/bin/sh

# Dims the internal panel while the lid is closed: laptop-panel close|open.
# acpid's laptop-panel drop-in sets LAPTOP_BACKLIGHT_DEVICE and the private
# XDG_RUNTIME_DIR where brightnessctl saves the level to restore.

set -u

backlight() {
  /usr/bin/brightnessctl -qc backlight -d "$device" "$@"
}

# Prints logind's lid-switch block and weak-block inhibitor lists
lid_inhibitors() {
  manager_properties="$(/usr/bin/busctl --timeout=2s call \
    org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.DBus.Properties GetAll s org.freedesktop.login1.Manager)" \
    || return
  printf '%s' "$manager_properties" \
    | grep -oE '"Block(Weak)?Inhibited" s "[^"]*"'
}

# Exits without touching brightness if the panel isn't ours to change. A
# failed logind query exits nonzero and keeps the saved level; an observed
# lid-switch inhibitor (a desktop power manager) owns the panel, so this
# helper's saved level is stale and is dropped.
exit_unless_panel_is_ours() {
  inhibitors="$(lid_inhibitors)" || exit
  case "$inhibitors" in
    *[:\"]handle-lid-switch[:\"]*)
      rm -f "$saved_level"
      exit
      ;;
  esac
}

# Saves only the first level so a repeated close never saves zero
panel_close() {
  exit_unless_panel_is_ours
  [ -s "$saved_level" ] || backlight -s > /dev/null
  [ -s "$saved_level" ] && backlight set 0
}

# -r loads the saved level and set +0 writes it, reporting write failures;
# the saved level is kept for a later open unless the write succeeds
panel_open() {
  exit_unless_panel_is_ours
  [ -s "$saved_level" ] || return 0
  backlight -rn0 set +0 && rm -f "$saved_level"
}

case "${1-}:$#" in
  close:1 | open:1) ;;
  *)
    echo "usage: laptop-panel close|open" >&2
    exit 2
    ;;
esac

device="${LAPTOP_BACKLIGHT_DEVICE:?LAPTOP_BACKLIGHT_DEVICE is not set}"
saved_level="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/brightnessctl/backlight/$device"

case "$1" in
  close) panel_close ;;
  open) panel_open ;;
esac

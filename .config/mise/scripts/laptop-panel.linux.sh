#!/bin/sh

set -u

backlight() {
  /usr/bin/brightnessctl -qc backlight -d "$device" "$@"
}

lid_inhibitors() {
  manager_properties="$(/usr/bin/busctl --timeout=2s call \
    org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.DBus.Properties GetAll s org.freedesktop.login1.Manager)" \
    || return
  printf '%s' "$manager_properties" \
    | grep -oE '"Block(Weak)?Inhibited" s "[^"]*"'
}

# A lid inhibitor makes our saved brightness stale.
exit_unless_panel_is_ours() {
  inhibitors="$(lid_inhibitors)" || exit
  case "$inhibitors" in
    *[:\"]handle-lid-switch[:\"]*)
      rm -f "$saved_level"
      exit
      ;;
  esac
}

panel_close() {
  exit_unless_panel_is_ours
  [ -s "$saved_level" ] || backlight -s > /dev/null
  [ -s "$saved_level" ] && backlight set 0
}

# +0 forces the restore write to report failures.
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

#!/bin/sh

set -u

lid_inhibitors() {
  manager_properties="$(/usr/bin/busctl --timeout=2s call \
    org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.DBus.Properties GetAll s org.freedesktop.login1.Manager)" \
    || return
  printf '%s' "$manager_properties" \
    | grep -oE '"Block(Weak)?Inhibited" s "[^"]*"'
}

# Query failures count as graphical.
graphical_seat() {
  active="$(/usr/bin/busctl --timeout=2s get-property org.freedesktop.login1 \
    /org/freedesktop/login1/seat/seat0 org.freedesktop.login1.Seat ActiveSession)" \
    || return 0
  session="${active##* \"}"
  session="${session%\"}"
  [ "$session" != / ] || return 1
  type="$(/usr/bin/busctl --timeout=2s get-property org.freedesktop.login1 \
    "$session" org.freedesktop.login1.Session Type)" || return 0
  [ "$type" != 's "tty"' ]
}

exit_unless_panel_is_ours() {
  inhibitors="$(lid_inhibitors)" || exit
  case "$inhibitors" in
    *[:\"]handle-lid-switch[:\"]*) exit 0 ;;
  esac
  ! graphical_seat || exit 0
}

fail() {
  echo "laptop-panel: $*" >&2
  exit 1
}

# DRM can ignore a blank write, so keep the target until DPMS reports On.
restore() {
  read -r target device connector < "$saved" || exit
  current="$(readlink -e "/sys/class/graphics/$target/device")" \
    || fail "$target is unavailable"
  if [ "$current" != "$device" ]; then
    rm -f "$saved"
    fail "$target changed; not restoring it"
  fi
  echo 0 > "/sys/class/graphics/$target/blank" || exit
  [ "$(cat "$device/drm/${connector%%-*}/$connector/dpms")" = On ] \
    || fail "$connector is not back on"
  rm -f "$saved"
}

panel_close() {
  exit_unless_panel_is_ours

  for fb in /sys/class/graphics/fb[0-9]*; do
    panel='' external='' unsure=''
    for connector in "$fb"/device/drm/card[0-9]*/card[0-9]*-*; do
      case "${connector##*/}:$(cat "$connector/status" 2> /dev/null)" in
        *:disconnected) ;;
        *-eDP-*:connected | *-LVDS-*:connected | *-DSI-*:connected) panel="$connector" ;;
        *:connected) external=1 ;;
        *) unsure="${connector##*/}" ;;
      esac
    done
    [ -z "$panel" ] || break
  done
  [ -n "$panel" ] || fail "no framebuffer console drives the internal panel"
  # Blanking the framebuffer powers down every output on its GPU.
  [ -z "$external" ] || exit 0
  [ -z "$unsure" ] || fail "cannot tell whether $unsure is in use"

  echo "${fb##*/} $(readlink -f "$fb/device") ${panel##*/}" > "$saved.new" \
    && mv "$saved.new" "$saved" || exit
  echo 4 > "$fb/blank" || exit
  [ "$(cat "$panel/dpms")" = Off ] && exit
  echo "laptop-panel: the kernel kept ${panel##*/} powered on" >&2
  restore
  exit 1
}

panel_open() {
  exit_unless_panel_is_ours
  [ ! -s "$saved" ] || restore
}

case "${1-}:$#" in
  close:1 | open:1) ;;
  *)
    echo "usage: laptop-panel close|open" >&2
    exit 2
    ;;
esac

saved="${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is not set}/laptop-panel"
exec 9>> "$saved.lock" && /usr/bin/flock 9 || exit

case "$1" in
  close) panel_close ;;
  open) panel_open ;;
esac

#!/bin/sh

set -u

lid_inhibitors() {
  manager_properties="$(busctl --timeout=2s call \
    org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.DBus.Properties GetAll s org.freedesktop.login1.Manager)" \
    || return
  printf '%s' "$manager_properties" \
    | grep -oE '"Block(Weak)?Inhibited" s "[^"]*"'
}

# Query failures count as graphical.
graphical_seat() {
  active="$(busctl --timeout=2s get-property org.freedesktop.login1 \
    /org/freedesktop/login1/seat/seat0 org.freedesktop.login1.Seat ActiveSession)" \
    || return 0
  session="${active##* \"}"
  session="${session%\"}"
  [ "$session" != / ] || return 1
  type="$(busctl --timeout=2s get-property org.freedesktop.login1 \
    "$session" org.freedesktop.login1.Session Type)" || return 0
  [ "$type" != 's "tty"' ]
}

exit_unless_panel_is_ours() {
  inhibitors="$(lid_inhibitors)" || exit
  case "$inhibitors" in
    *[:\"]handle-lid-switch[:\"]*) exit 0 ;;
  esac
  ! graphical_seat || exit 0
  # A display manager starting at boot couldn't take a display that we hold
  if [ -e /etc/systemd/system/display-manager.service ] \
    && [ "$(systemctl get-default)" = graphical.target ]; then
    exit 0
  fi
}

# fbcon takes over the console at its first output, and while we hold the
# display it couldn't set its colors, so make that happen first
fbcon_takeover() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep -qs 'frame buffer device' /sys/class/vtconsole/vtcon*/name && return
    printf '.\b \b' > /dev/tty0
    sleep 0.2
  done
  echo "fbcon has not taken over the console" >&2
}

fail() {
  echo "$*" >&2
  exit 1
}

# DRM can ignore a blank write, so keep the target until DPMS reports On.
restore() {
  read -r target device connector < "$saved" || exit
  systemctl stop laptop-panel-hold.service 2> /dev/null
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

  panel='' external='' unsure=''
  for connector in /sys/class/graphics/fb[0-9]*/device/drm/card[0-9]*/card[0-9]*-*; do
    case "${connector##*/}:$(cat "$connector/status" 2> /dev/null)" in
      *-Writeback-*:* | *:disconnected) ;;
      *-eDP-*:connected | *-LVDS-*:connected | *-DSI-*:connected) panel="$connector" ;;
      *:connected) external=1 ;;
      *) unsure="${connector##*/}" ;;
    esac
  done
  [ -n "$panel" ] || fail "no framebuffer console drives the internal panel"
  # Blanking and holding the display power down every output on the GPU.
  [ -z "$external" ] || exit 0
  [ -z "$unsure" ] || fail "cannot tell whether $unsure is in use"
  fb="${panel%/device/drm/*}"
  card="${panel%/*}"

  echo "${fb##*/} $(readlink -f "$fb/device") ${panel##*/}" > "$saved.new" \
    && mv "$saved.new" "$saved" || exit
  # Keep a hold that works, and replace one that didn't keep the panel off
  if systemctl --quiet is-active laptop-panel-hold.service; then
    [ "$(cat "$panel/dpms")" = On ] || exit 0
    systemctl stop laptop-panel-hold.service
  fi
  fbcon_takeover
  # Hold the display open like a compositor, so console redraws, hotplug, and
  # the last GPU client exiting can't light the panel again. Something can
  # still light it before the hold opens, so check and retry once.
  for _ in 1 2; do
    echo 4 > "$fb/blank" || exit
    if [ "$(cat "$panel/dpms")" = On ]; then
      echo "the kernel kept ${panel##*/} powered on" >&2
      restore
      exit 1
    fi
    systemd-run --quiet --collect --unit=laptop-panel-hold \
      --property=Type=exec --property="StandardInput=file:/dev/dri/${card##*/}" \
      sleep infinity || fail "cannot hold ${card##*/}"
    [ "$(cat "$panel/dpms")" = On ] || exit 0
    systemctl stop laptop-panel-hold.service
  done
  fail "${panel##*/} keeps powering back on"
}

panel_open() {
  [ ! -s "$saved" ] || restore
}

# acpid only reports lid changes, so match the panel to the lid when it starts
panel_sync() {
  lid="$(busctl --timeout=2s get-property org.freedesktop.login1 \
    /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed)" || exit
  if [ "$lid" = 'b true' ]; then
    panel_close
  else
    panel_open
  fi
}

case "${1-}:$#" in
  close:1 | open:1 | sync:1) ;;
  *)
    echo "usage: laptop-panel close|open|sync" >&2
    exit 2
    ;;
esac

saved=/run/laptop-panel/state
exec 9>> "$saved.lock" && flock 9 || exit

case "$1" in
  close) panel_close ;;
  open) panel_open ;;
  sync) panel_sync ;;
esac

#!/bin/sh

set -u

fail() {
  echo "$*" >&2
  exit 1
}

# Make fbcon take over the console now, since it can't while the display is held
fbcon_takeover() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    grep -qs 'frame buffer device' /sys/class/vtconsole/vtcon*/name && return
    printf '.\b \b' > /dev/tty0
    sleep 0.2
  done
  echo "fbcon has not taken over the console" >&2
}

panel_close() {
  # Leave desktops with a display manager alone
  [ -e /etc/systemd/system/display-manager.service ] && exit 0
  systemctl --quiet is-active laptop-panel-hold.service && exit 0

  panel=''
  for connector in /sys/class/graphics/fb[0-9]*/device/drm/card[0-9]*/card[0-9]*-*; do
    case "${connector##*/}:$(cat "$connector/status" 2> /dev/null)" in
      *-Writeback-*:* | *:disconnected) ;;
      *-eDP-*:connected | *-LVDS-*:connected | *-DSI-*:connected) panel="$connector" ;;
      # Blanking would also turn off any other display
      *) exit 0 ;;
    esac
  done
  [ -n "$panel" ] || fail "no framebuffer console drives the internal panel"
  fb="${panel%/device/drm/*}"
  card="${panel%/*}"

  fbcon_takeover
  # Holding DRM master stops relights; retry once if one slips in before the hold
  for _ in 1 2; do
    echo 4 > "$fb/blank" || exit
    systemd-run --quiet --collect --unit=laptop-panel-hold \
      --property=Type=exec --property="StandardInput=file:/dev/dri/${card##*/}" \
      sleep infinity || fail "cannot hold ${card##*/}"
    [ "$(cat "$panel/dpms")" = On ] || exit 0
    systemctl stop laptop-panel-hold.service
  done
  fail "${panel##*/} keeps powering back on"
}

panel_open() {
  systemctl stop laptop-panel-hold.service 2> /dev/null
  for blank in /sys/class/graphics/fb[0-9]*/blank; do
    echo 0 > "$blank"
  done
}

# Match the panel to the lid when acpid starts
panel_sync() {
  lid="$(busctl --timeout=2s get-property org.freedesktop.login1 \
    /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed)" || exit
  if [ "$lid" = 'b true' ]; then
    panel_close
  else
    panel_open
  fi
}

exec 9> /run/laptop-panel.lock && flock 9 || exit

case "${1-}" in
  close) panel_close ;;
  open) panel_open ;;
  sync) panel_sync ;;
  *)
    echo "usage: laptop-panel close|open|sync" >&2
    exit 2
    ;;
esac

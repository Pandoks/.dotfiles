#!/bin/sh

set -eu

script_directory="$(CDPATH= cd "$(dirname "$0")" && pwd)"
. "$script_directory/lib/system.sh"

skip() {
  echo "Skipping laptop power setup: $*."
  exit 0
}

[ "$(uname -s)" = Linux ] || skip "not Linux"
[ -d /run/systemd/system ] || skip "systemd is not running"
command -v systemctl >/dev/null 2>&1 || skip "systemctl is unavailable"
command -v systemd-detect-virt >/dev/null 2>&1 || skip "cannot check virtualization"

virtualization="$(systemd-detect-virt 2>/dev/null || true)"
[ "$virtualization" = none ] || skip "virtualized or unknown environment"

laptop=false
chassis="$(hostnamectl chassis 2>/dev/null || true)"
case "$chassis" in
  laptop|convertible) laptop=true ;;
  desktop|server|vm|container|tablet|handset|watch|embedded)
    skip "chassis is $chassis"
    ;;
esac

if [ "$laptop" = false ]; then
  chassis_type="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || true)"
  case "$chassis_type" in
    8|9|10|14|31|32) laptop=true ;;
    ''|0|1|2) ;;
    *) skip "DMI chassis is not a laptop" ;;
  esac
fi

# When firmware cannot identify the chassis, require both a lid and a system
# battery. A desktop UPS or a wireless peripheral battery is not sufficient.
if [ "$laptop" = false ]; then
  lid_present=false
  for lid_state in /proc/acpi/button/lid/*/state; do
    [ -r "$lid_state" ] || continue
    lid_present=true
    break
  done
  # SW_LID is bit zero in the kernel input switch capability bitmap.
  for switch_capabilities in /sys/class/input/input*/capabilities/sw; do
    capabilities="$(cat "$switch_capabilities" 2>/dev/null || true)"
    case "$capabilities" in
      *[13579bBdDfF]) lid_present=true; break ;;
    esac
  done
  if [ "$lid_present" = true ]; then
    for battery in /sys/class/power_supply/*; do
      [ "$(cat "$battery/type" 2>/dev/null || true)" = Battery ] || continue
      [ "$(cat "$battery/scope" 2>/dev/null || true)" != Device ] || continue
      laptop=true
      break
    done
  fi
fi

[ "$laptop" = true ] || skip "no laptop chassis or lid and battery detected"
systemctl is-active --quiet systemd-logind.service || skip "systemd-logind is not running"

files_directory="$script_directory/../files/laptop"

# Check as root: an existing managed file may not be readable by this user.
# A separate changed flag keeps an installation error from meaning "unchanged".
install_managed_file() {
  file_changed=false
  if run_as_root cmp -s "$1" "$2" && \
      [ "$(run_as_root stat -c '%u:%g:%a' "$2")" = "0:0:${3#0}" ]; then
    return 0
  fi
  run_as_root install -o 0 -g 0 -m 0755 -d "$(dirname "$2")" || exit "$?"
  run_as_root install -o 0 -g 0 -m "$3" "$1" "$2" || exit "$?"
  file_changed=true
}

install_managed_file "$files_directory/logind.conf" \
  /etc/systemd/logind.conf.d/60-mise-laptop-power.conf 0644

# SIGHUP is supported on older Debian/Ubuntu releases as well as current Arch.
# Reload even on repeat runs so a previously failed reload can be retried.
run_as_root systemctl kill --kill-who=main --signal=HUP systemd-logind.service
echo "Configured laptop lid power policy (existing dock policy preserved)."

backlight_present=false
for backlight in /sys/class/backlight/*; do
  [ -d "$backlight" ] || continue
  backlight_present=true
  break
done
[ "$backlight_present" = true ] || exit 0

for command in busctl loginctl flock; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Laptop backlight setup requires $command." >&2
    exit 1
  }
done

display_changed=false
for helper in mise-lid-backlight mise-lid-backlight-watch; do
  install_managed_file "$files_directory/$helper" "/usr/local/libexec/$helper" 0755
  [ "$file_changed" = false ] || display_changed=true
done
install_managed_file "$files_directory/mise-lid-backlight.service" \
  /etc/systemd/system/mise-lid-backlight.service 0644
[ "$file_changed" = false ] || display_changed=true

if [ "$display_changed" = true ]; then
  run_as_root systemctl daemon-reload
fi
run_as_root systemctl enable mise-lid-backlight.service
if [ "$display_changed" = true ]; then
  run_as_root systemctl restart mise-lid-backlight.service
else
  run_as_root systemctl start mise-lid-backlight.service
fi
echo "Configured headless laptop lid backlight service."

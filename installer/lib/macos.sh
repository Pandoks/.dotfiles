# shellcheck shell=sh

MACOS_CONFIG="${REPO_ROOT}/config/macos-defaults.yaml"
readonly MACOS_CONFIG

usage_macos() {
  printf "%bUsage:%b macos [command]\n\n" "${BOLD}" "${NORMAL}" >&2
  printf "Manage macOS system settings.\n\n" >&2
  printf "%bCommands:%b\n" "${BOLD}" "${NORMAL}" >&2
  printf "  %bapply%b     Apply settings from config to system (default)\n" "${GREEN}" "${NORMAL}" >&2
  printf "  %bexport%b    Export current system settings to config\n" "${GREEN}" "${NORMAL}" >&2
  printf "  %bdiff%b      Show differences between config and system\n\n" "${GREEN}" "${NORMAL}" >&2
  return "${1:-0}"
}


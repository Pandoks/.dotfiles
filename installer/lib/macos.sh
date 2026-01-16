# shellcheck shell=sh

MACOS_CONFIG="${REPO_ROOT}/macos-defaults.yaml"
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

check_config() {
  if [ ! -f "${MACOS_CONFIG}" ]; then
    printf "%bError:%b Config file not found: %s\n" "${RED}" "${NORMAL}" "${MACOS_CONFIG}" >&2
    return 1
  fi
}
cmd_apply() {
}

cmd_export() {
}

cmd_diff() {
}

macos_configs() {
  macos_configs_cmd="${1:-apply}"
  shift 2> /dev/null || true

  case "${macos_configs_cmd}" in
    apply) cmd_apply "$@" ;;
    export) cmd_export "$@" ;;
    diff) cmd_diff "$@" ;;
    help | --help | -h) usage_macos ;;
    *)
      printf "%bError:%b Unknown command '%s'\n" "${RED}" "${NORMAL}" "${macos_configs_cmd}" >&2
      usage_macos 1
      ;;
  esac
}

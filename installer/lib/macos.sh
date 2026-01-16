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

# Args: $1 = yaml tag, $2 = value
# Output: prints type to stdout (bool, int, float, string, array)
get_value_type() {
  if [ "$1" = "!!seq" ]; then
    printf "array"
    return
  fi

  case "$2" in
    true | false) printf "bool" ;;
    *)
      if printf "%s" "$2" | grep -qE '^-?[0-9]+$'; then
        printf "int"
      elif printf "%s" "$2" | grep -qE '^-?[0-9]*\.[0-9]+$'; then
        printf "float"
      else
        printf "string"
      fi
      ;;
  esac
}

# Args: $1 = value
# Output: prints escaped/quoted string for yaml
format_yaml_string() {
  if printf "%s" "$1" | grep -qE '^[a-zA-Z0-9_./-]+$'; then
    printf "%s" "$1"
  else
    printf '"%s"' "$(printf "%s" "$1" | sed 's/"/\\"/g')"
  fi
}

# Args: $1 = category, $2 = domain, $3 = key
# Output: prints yq path
yq_path() {
  printf '.[\"%s\"][\"%s\"][\"%s\"]' "$1" "$2" "$3"
}

cmd_apply() {
  printf "Applying macOS defaults from config...\n\n"
  check_config || return 1

  yq -r 'keys | .[]' "${MACOS_CONFIG}" | while IFS= read -r cmd_apply_category; do
    printf "  [%s]\n" "${cmd_apply_category}"

    yq -r ".[\"${cmd_apply_category}\"] | keys | .[]" "${MACOS_CONFIG}" | while IFS= read -r cmd_apply_domain; do
      yq -r ".[\"${cmd_apply_category}\"][\"${cmd_apply_domain}\"] | keys | .[]" "${MACOS_CONFIG}" | while IFS= read -r cmd_apply_key; do
        cmd_apply_yq_path=$(yq_path "${cmd_apply_category}" "${cmd_apply_domain}" "${cmd_apply_key}")
        cmd_apply_tag=$(yq "${cmd_apply_yq_path} | tag" "${MACOS_CONFIG}")
        cmd_apply_value_type=$(get_value_type "${cmd_apply_tag}" "")

        if [ "${cmd_apply_value_type}" = "array" ]; then
          cmd_apply_value=$(yq -r "${cmd_apply_yq_path} | .[]" "${MACOS_CONFIG}" | tr '\n' ' ')
        else
          cmd_apply_value=$(yq -r "${cmd_apply_yq_path}" "${MACOS_CONFIG}")
          cmd_apply_value_type=$(get_value_type "" "${cmd_apply_value}")
        fi

        cmd_apply_value=$(eval printf "%s" "\"${cmd_apply_value}\"")

        case "${cmd_apply_value_type}" in
          bool) defaults write "${cmd_apply_domain}" "${cmd_apply_key}" -bool "${cmd_apply_value}" ;;
          int) defaults write "${cmd_apply_domain}" "${cmd_apply_key}" -int "${cmd_apply_value}" ;;
          float) defaults write "${cmd_apply_domain}" "${cmd_apply_key}" -float "${cmd_apply_value}" ;;
          array)
            defaults delete "${cmd_apply_domain}" "${cmd_apply_key}" 2> /dev/null || true
            # shellcheck disable=SC2086
            defaults write "${cmd_apply_domain}" "${cmd_apply_key}" -array ${cmd_apply_value}
            ;;
          *) defaults write "${cmd_apply_domain}" "${cmd_apply_key}" -string "${cmd_apply_value}" ;;
        esac

        printf "    %s = %s\n" "${cmd_apply_key}" "${cmd_apply_value}"
      done
    done
  done

  printf "\nRestarting affected applications...\n"
  killall Dock 2> /dev/null || true
  killall Finder 2> /dev/null || true
  killall SystemUIServer 2> /dev/null || true
  killall ControlCenter 2> /dev/null || true

  printf "%b✓ Done!%b Some changes may require logout/restart.\n" "${GREEN}" "${NORMAL}"
}

cmd_export() {
  cmd_export_output_file="${1:-${MACOS_CONFIG}}"
  printf "Exporting current macOS defaults...\n"
  check_config || return 1

  cmd_export_temp_file=$(mktemp)

  yq -r 'keys | .[]' "${MACOS_CONFIG}" | while IFS= read -r cmd_export_category; do
    printf "%s:\n" "${cmd_export_category}" >> "${cmd_export_temp_file}"

    yq -r ".[\"${cmd_export_category}\"] | keys | .[]" "${MACOS_CONFIG}" | while IFS= read -r cmd_export_domain; do
      printf "  %s:\n" "${cmd_export_domain}" >> "${cmd_export_temp_file}"

      yq -r ".[\"${cmd_export_category}\"][\"${cmd_export_domain}\"] | keys | .[]" "${MACOS_CONFIG}" | while IFS= read -r cmd_export_key; do
        cmd_export_yq_path=$(yq_path "${cmd_export_category}" "${cmd_export_domain}" "${cmd_export_key}")
        cmd_export_tag=$(yq "${cmd_export_yq_path} | tag" "${MACOS_CONFIG}")
        cmd_export_yaml_value=$(yq -r "${cmd_export_yq_path}" "${MACOS_CONFIG}")
        cmd_export_value_type=$(get_value_type "${cmd_export_tag}" "${cmd_export_yaml_value}")
        cmd_export_system_value=$(defaults read "${cmd_export_domain}" "${cmd_export_key}" 2> /dev/null) || cmd_export_system_value=""

        if printf "%s" "${cmd_export_key}" | grep -q ' '; then
          cmd_export_key_out="\"${cmd_export_key}\""
        else
          cmd_export_key_out="${cmd_export_key}"
        fi

        cmd_export_value="${cmd_export_system_value:-${cmd_export_yaml_value}}"

        case "${cmd_export_value_type}" in
          bool)
            if [ "${cmd_export_value}" = "1" ] || [ "${cmd_export_value}" = "true" ]; then
              printf "    %s: true\n" "${cmd_export_key_out}"
            else
              printf "    %s: false\n" "${cmd_export_key_out}"
            fi
            ;;
          int)
            if [ "${cmd_export_value}" = "true" ]; then
              printf "    %s: 1\n" "${cmd_export_key_out}"
            elif [ "${cmd_export_value}" = "false" ]; then
              printf "    %s: 0\n" "${cmd_export_key_out}"
            else
              printf "    %s: %s\n" "${cmd_export_key_out}" "${cmd_export_value}"
            fi
            ;;
          float)
            printf "    %s: %s\n" "${cmd_export_key_out}" "${cmd_export_value}"
            ;;
          array)
            printf "    %s:\n" "${cmd_export_key_out}"
            if [ -n "${cmd_export_system_value}" ]; then
              printf "%s" "${cmd_export_system_value}" | grep -oE '"[^"]*"' | while IFS= read -r cmd_export_item; do
                cmd_export_item=$(printf "%s" "${cmd_export_item}" | sed 's/^"//;s/"$//')
                [ -n "${cmd_export_item}" ] && printf "      - %s\n" "${cmd_export_item}"
              done
            else
              yq -r "${cmd_export_yq_path} | .[]" "${MACOS_CONFIG}" | while IFS= read -r cmd_export_item; do
                printf "      - %s\n" "${cmd_export_item}"
              done
            fi
            ;;
          *)
            printf "    %s: %s\n" "${cmd_export_key_out}" "$(format_yaml_string "${cmd_export_value}")"
            ;;
        esac >> "${cmd_export_temp_file}"
      done
    done

    printf "\n" >> "${cmd_export_temp_file}"
  done

  printf '%s' "$(cat "${cmd_export_temp_file}")" > "${cmd_export_temp_file}"
  mv "${cmd_export_temp_file}" "${cmd_export_output_file}"
  printf "%b✓ Exported to:%b %s\n" "${GREEN}" "${NORMAL}" "${cmd_export_output_file}"
}

cmd_diff() {
  printf "Comparing config with current system settings...\n\n"

  cmd_diff_temp=$(mktemp)
  cmd_export "${cmd_diff_temp}" > /dev/null 2>&1

  if [ -f "${MACOS_CONFIG}" ]; then
    git diff --no-index "${MACOS_CONFIG}" "${cmd_diff_temp}" || true

    if git diff --no-index --quiet "${MACOS_CONFIG}" "${cmd_diff_temp}" 2> /dev/null; then
      printf "%b✓ No differences found.%b Config matches system.\n" "${GREEN}" "${NORMAL}"
    fi
  else
    printf "%bNote:%b No existing config file. Here are your current settings:\n\n" "${YELLOW}" "${NORMAL}"
    cat "${cmd_diff_temp}"
  fi

  rm -f "${cmd_diff_temp}"
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

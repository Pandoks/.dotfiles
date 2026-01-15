# shellcheck shell=sh

create_symlink() {
  create_symlink_source_path="$1"
  create_symlink_dest_path="$2"

  if [ -z "${create_symlink_source_path}" ] || [ -z "${create_symlink_dest_path}" ]; then
    printf "%bError:%b Both source and destination paths are required\n" "${RED}" "${NORMAL}" >&2
    return 1
  fi

  if [ ! -e "${create_symlink_source_path}" ]; then
    printf "%bError:%b Source path does not exist: %s\n" "${RED}" "${NORMAL}" "${create_symlink_source_path}" >&2
    return 1
  fi

  if [ -e "${create_symlink_dest_path}" ] || [ -L "${create_symlink_dest_path}" ]; then
    printf "%bFile already exists at %s.%b Overwrite? [y/n] " "${YELLOW}" "${create_symlink_dest_path}" "${NORMAL}"
    read -r create_symlink_response

    case "${create_symlink_response}" in
      y | Y | yes | Yes | YES)
        printf "Removing existing file: %s\n" "${create_symlink_dest_path}"
        if ! rm -rf "${create_symlink_dest_path}"; then
          printf "%bError:%b Failed to remove %s\n" "${RED}" "${NORMAL}" "${create_symlink_dest_path}" >&2
          return 1
        fi
        ;;
      *)
        printf "Skipping: %s\n" "${create_symlink_dest_path}"
        return 0
        ;;
    esac
  fi

  create_symlink_dest_dir="$(dirname "${create_symlink_dest_path}")"
  if [ ! -d "${create_symlink_dest_dir}" ]; then
    if ! mkdir -p "${create_symlink_dest_dir}"; then
      printf "%bError:%b Failed to create directory %s\n" "${RED}" "${NORMAL}" "${create_symlink_dest_dir}" >&2
      return 1
    fi
  fi

  if ! ln -s "${create_symlink_source_path}" "${create_symlink_dest_path}"; then
    printf "%bError:%b Failed to create symlink from %s to %s\n" "${RED}" "${NORMAL}" "${create_symlink_source_path}" "${create_symlink_dest_path}" >&2
    return 1
  fi

  printf "%b✓%b %s -> %s\n" "${GREEN}" "${NORMAL}" "${create_symlink_dest_path}" "${create_symlink_source_path}"
  return 0
}

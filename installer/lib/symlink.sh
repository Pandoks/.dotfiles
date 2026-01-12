# shellcheck shell=sh

create_symlink() {
  create_symlink_source_path="$1"
  create_symlink_dest_path="$2"

  if [ -z "${create_symlink_source_path}" ] || [ -z "${create_symlink_dest_path}" ]; then
    echo "Error: Both source and destination paths are required" >&2
    return 1
  fi

  if [ ! -e "${create_symlink_source_path}" ]; then
    echo "Error: Source path does not exist: ${create_symlink_source_path}" >&2
    return 1
  fi

  if [ -e "${create_symlink_dest_path}" ] || [ -L "${create_symlink_dest_path}" ]; then
    printf "File already exists at %s. Overwrite? (y/n): " "${create_symlink_dest_path}"
    read -r create_symlink_response

    case "${create_symlink_response}" in
    y | Y | yes | Yes | YES)
      echo "Removing existing file: ${create_symlink_dest_path}"
      if ! rm -rf "${create_symlink_dest_path}"; then
        echo "Error: Failed to remove ${create_symlink_dest_path}" >&2
        return 1
      fi
      ;;
    *)
      echo "Skipping: ${create_symlink_dest_path}"
      return 0
      ;;
    esac
  fi

  create_symlink_dest_dir="$(dirname "${create_symlink_dest_path}")"
  if [ ! -d "${create_symlink_dest_dir}" ]; then
    if ! mkdir -p "${create_symlink_dest_dir}"; then
      echo "Error: Failed to create directory ${create_symlink_dest_dir}" >&2
      return 1
    fi
  fi

  if ! ln -s "${create_symlink_source_path}" "${create_symlink_dest_path}"; then
    echo "Error: Failed to create symlink from ${create_symlink_source_path} to ${create_symlink_dest_path}" >&2
    return 1
  fi

  echo "Created symlink: ${create_symlink_dest_path} -> ${create_symlink_source_path}"
  return 0
}

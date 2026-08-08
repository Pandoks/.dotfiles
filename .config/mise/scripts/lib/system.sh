#!/bin/sh

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo "$@"
  fi
}

install_file_if_changed() (
  install_file_source="$1"
  install_file_destination="$2"
  install_file_mode="$3"

  if run_as_root cmp -s "$install_file_source" "$install_file_destination"; then
    return 1
  fi

  run_as_root install \
    -m "$install_file_mode" \
    "$install_file_source" \
    "$install_file_destination"
)

apt_is_available() {
  command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1
}

configure_apt_repository() (
  repository_name="$1"
  signing_key_url="$2"
  repository_url="$3"
  repository_suite="$4"
  repository_components="$5"
  repository_architecture="$6"

  repository_keyring="/etc/apt/keyrings/${repository_name}.asc"
  repository_source="/etc/apt/sources.list.d/${repository_name}.sources"
  temporary_directory="$(mktemp -d)"
  trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

  curl -fsSL "$signing_key_url" \
    -o "$temporary_directory/${repository_name}.asc"

  cat >"$temporary_directory/${repository_name}.sources" <<EOF
Types: deb
URIs: $repository_url
Suites: $repository_suite
Components: $repository_components
Architectures: $repository_architecture
Signed-By: $repository_keyring
EOF

  repository_changed=false
  run_as_root install -m 0755 -d /etc/apt/keyrings

  if install_file_if_changed \
    "$temporary_directory/${repository_name}.asc" \
    "$repository_keyring" \
    0644; then
    repository_changed=true
  fi

  if install_file_if_changed \
    "$temporary_directory/${repository_name}.sources" \
    "$repository_source" \
    0644; then
    repository_changed=true
  fi

  if [ "$repository_changed" = true ]; then
    run_as_root apt-get update
  fi
)

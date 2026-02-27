#!/bin/sh
# Environment Variables:
# HOST_SERVICES_HOME - root directory for host-services config (defaults to ~/.config/host-services)
# DOCKER_TIMEOUT - timeout for docker daemon to be ready
# Expected layout under HOST_SERVICES_HOME:
# - local-service.d/*.sh
# - compose.d/*.yaml|*.yml (compose entrypoint is generated automatically)

set -eu

PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

HOST_SERVICES_HOME="${HOST_SERVICES_HOME:-$HOME/.config/host-services}"
service_dir="$HOST_SERVICES_HOME/local-service.d"
compose_modules_dir="$HOST_SERVICES_HOME/compose.d"
DOCKER_TIMEOUT="${DOCKER_TIMEOUT:-90}"

echo "[startup] Host services home: $HOST_SERVICES_HOME"
echo "[startup] Services directory: $service_dir"

if [ ! -d "$service_dir" ]; then
  echo "[startup] No services directory found; skipping local service scripts"
else
  for service_script in "$service_dir"/*; do
    [ -f "$service_script" ] || continue
    if [ ! -x "$service_script" ]; then
      echo "[startup] Skipping non-executable: $service_script"
      continue
    fi

    echo "[startup] Running: $service_script"
    if "$service_script"; then
      echo "[startup] Completed: $service_script"
    else
      echo "[startup] ERROR: $service_script failed"
      exit 1
    fi
  done

  echo "[startup] Service scripts completed"
fi

if [ ! -d "$compose_modules_dir" ]; then
  echo "[startup] No compose.d directory found at $compose_modules_dir; skipping docker compose startup"
  exit 0
fi

compose_module_paths="$(find "$compose_modules_dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) | sort)"
if [ -z "$compose_module_paths" ]; then
  echo "[startup] No compose module files found in $compose_modules_dir; skipping docker compose startup"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "[startup] docker is not installed or not in PATH"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  if command -v open >/dev/null 2>&1; then
    echo "[startup] Docker daemon is not ready; opening Docker Desktop"
    open -a Docker >/dev/null 2>&1 || true
  fi

  wait_for_docker_time_elapsed=0
  while ! docker info >/dev/null 2>&1; do
    if [ "$wait_for_docker_time_elapsed" -ge "$DOCKER_TIMEOUT" ]; then
      echo "[startup] Docker daemon did not become ready after ${DOCKER_TIMEOUT}s"
      exit 1
    fi
    sleep 2
    wait_for_docker_time_elapsed=$((wait_for_docker_time_elapsed + 2))
  done
fi

generated_compose_file=""
cleanup_generated_files() {
  if [ -n "$generated_compose_file" ] && [ -f "$generated_compose_file" ]; then
    rm -f "$generated_compose_file"
  fi
}
trap cleanup_generated_files EXIT INT TERM

generated_compose_file="$(mktemp "${TMPDIR:-/tmp}/host-services-compose.XXXXXX.yaml")"
{
  echo "name: host-services"
  echo "include:"
  printf '%s\n' "$compose_module_paths" |
    while IFS= read -r module_path; do
      [ -n "$module_path" ] || continue
      escaped_module_path="$(printf '%s' "$module_path" | sed 's/\\/\\\\/g; s/"/\\"/g')"
      printf '  - "%s"\n' "$escaped_module_path"
    done
} >"$generated_compose_file"

echo "[startup] Generated compose entrypoint from $compose_modules_dir"

echo "[startup] Starting docker compose stack: $generated_compose_file"
(
  cd "$(dirname "$generated_compose_file")"
  docker compose -f "$generated_compose_file" up -d
)
echo "[startup] Docker compose stack started"

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEBUG_LOG_DIR="${NDS_DEBUG_LOG_DIR:-${WORKSPACE_ROOT}/.debug-logs}"

find_gdb() {
  local candidates=()
  local in_container=0
  if [[ -f /.dockerenv ]] || [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${NDS_HOST_WORKSPACE_FOLDER:-}" ]]; then
    in_container=1
  fi

  if [[ -n "${NDS_GDB_BIN:-}" ]]; then
    candidates+=("${NDS_GDB_BIN}")
  fi

  if [[ "${in_container}" == "1" ]]; then
    # Prefer the target-aware ARM GDB shipped with embedded toolchains in container.
    # gdb-multiarch is kept as fallback only.
    candidates+=(
      "/opt/gdb-17/bin/arm-none-eabi-gdb"
      "/opt/wonderful/toolchain/gcc-arm-none-eabi/bin/arm-none-eabi-gdb"
      "/opt/devkitpro/devkitARM/bin/arm-none-eabi-gdb"
      "/opt/blocksds/core/tools/bin/arm-none-eabi-gdb"
      "/opt/blocksds/core/tools/arm-none-eabi/bin/arm-none-eabi-gdb"
      "/opt/blocksds/toolchain/bin/arm-none-eabi-gdb"
    )
  fi

  candidates+=(
    "arm-none-eabi-gdb"
    "/opt/homebrew/bin/arm-none-eabi-gdb"
    "/usr/local/bin/arm-none-eabi-gdb"
    "gdb-multiarch"
  )

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ "${candidate}" == /* ]]; then
      if [[ -x "${candidate}" ]]; then
        printf '%s\n' "${candidate}"
        return 0
      fi
    else
      if command -v "${candidate}" >/dev/null 2>&1; then
        command -v "${candidate}"
        return 0
      fi
    fi
  done

  return 1
}

is_in_container() {
  [[ -f /.dockerenv ]] || [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${NDS_HOST_WORKSPACE_FOLDER:-}" ]]
}

enable_mi_log_capture() {
  local log_file="$1"
  shift

  mkdir -p "$(dirname "${log_file}")"

  if [[ "${NDS_GDB_MI_LOG_APPEND:-1}" != "1" ]]; then
    : > "${log_file}"
  fi

  {
    printf '[%s] gdb-wrapper start\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf 'cwd=%s\n' "${PWD}"
    printf 'gdb_bin=%s\n' "${GDB_BIN}"
    printf 'in_container=%s\n' "${IN_CONTAINER}"
    printf 'args='
    printf '%q ' "$@"
    printf '\n'
    printf -- '---\n'
  } >> "${log_file}"

  exec > >(tee -a "${log_file}") 2> >(tee -a "${log_file}" >&2)
}

GDB_BIN="$(find_gdb || true)"
if [[ -z "${GDB_BIN}" ]]; then
  cat <<'EOF' >&2
[nds-debug] Could not find an ARM GDB binary.
[nds-debug] Install one of:
  - macOS (Homebrew): brew install arm-none-eabi-gdb
  - Debian/Ubuntu:    apt install gdb-multiarch
[nds-debug] Or set NDS_GDB_BIN to an explicit executable path.
EOF
  exit 127
fi

if is_in_container && [[ "${NDS_ALLOW_GDB_MULTIARCH:-0}" != "1" ]]; then
  case "$(basename "${GDB_BIN}")" in
    gdb-multiarch)
      cat <<'EOF' >&2
[nds-debug] Selected debugger is gdb-multiarch, which is unreliable with melonDS ARM9 GDB packets.
[nds-debug] Rebuild the devcontainer so /opt/gdb-17/bin/arm-none-eabi-gdb is available.
[nds-debug] Temporary override (not recommended): set NDS_ALLOW_GDB_MULTIARCH=1.
EOF
      exit 127
      ;;
  esac
fi

IN_CONTAINER=0
if is_in_container; then
  IN_CONTAINER=1
fi

GDB_EXTRA_ARGS=()

# Make debugger startup deterministic regardless of user-local ~/.gdbinit contents.
if [[ "${NDS_GDB_NO_INIT:-1}" != "0" ]]; then
  GDB_EXTRA_ARGS+=("-nx")
fi

# melonDS doesn't provide tracepoint status packets expected by newer GDB builds.
# Disable this probe to avoid "Bogus trace status reply" attach failures.
if [[ "${NDS_GDB_DISABLE_TRACE_STATUS_PACKET:-1}" == "1" ]]; then
  GDB_EXTRA_ARGS+=("-iex" "set remote trace-status-packet off")
fi

if [[ "$#" -gt 0 ]] && [[ "$1" == "--interpreter=mi" ]] && [[ "${NDS_GDB_MI_LOG_ENABLE:-1}" == "1" ]]; then
  MI_LOG_FILE="${NDS_GDB_MI_LOG_FILE:-${DEBUG_LOG_DIR}/gdb-mi.log}"
  enable_mi_log_capture "${MI_LOG_FILE}" "${GDB_EXTRA_ARGS[@]}" "$@"
fi

exec "${GDB_BIN}" "${GDB_EXTRA_ARGS[@]}" "$@"

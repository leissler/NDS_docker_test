#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEBUG_LOG_DIR="${NDS_DEBUG_LOG_DIR:-${WORKSPACE_ROOT}/.debug-logs}"
PROXY_SCRIPT="${SCRIPT_DIR}/gdb-tcp-proxy.py"

mkdir -p "${DEBUG_LOG_DIR}"

PORT="${NDS_GDB_PORT:-3333}"
PID_FILE="${NDS_GDB_PROXY_PID_FILE:-${DEBUG_LOG_DIR}/nds-gdb-proxy-${PORT}.pid}"
LOG_FILE="${NDS_GDB_PROXY_LOG_FILE:-${DEBUG_LOG_DIR}/nds-gdb-proxy-${PORT}.log}"
CONNECT_RETRIES="${NDS_GDB_CONNECT_RETRIES:-300}"
CONNECT_INTERVAL="${NDS_GDB_CONNECT_INTERVAL:-0.1}"
BRIDGE_PORT="${NDS_BRIDGE_PORT:-17778}"
BRIDGE_STATE_FILE="${NDS_BRIDGE_STATE_FILE:-${DEBUG_LOG_DIR}/nds-bridge-state.json}"

in_container=0
if [[ -f /.dockerenv ]] || [[ -n "${REMOTE_CONTAINERS:-}" ]] || [[ -n "${NDS_HOST_WORKSPACE_FOLDER:-}" ]]; then
  in_container=1
fi

is_local_listener_present() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1
    return $?
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -an 2>/dev/null | grep -E "[\\.:]${port}[[:space:]].*LISTEN" >/dev/null 2>&1
    return $?
  fi

  return 1
}

wait_for_local_listener() {
  local retries="$1"
  local i
  for ((i = 0; i < retries; i += 1)); do
    if is_local_listener_present "${PORT}"; then
      return 0
    fi
    sleep "${CONNECT_INTERVAL}"
  done
  return 1
}

bridge_health_ok() {
  local host="$1"
  local port="$2"
  local url_host="${host}"
  if [[ "${host}" == *:* ]] && [[ "${host}" != \[*\] ]]; then
    url_host="[${host}]"
  fi
  curl -fsS --max-time 1 "http://${url_host}:${port}/health" >/dev/null 2>&1
}

resolve_bridge_state() {
  if [[ ! -r "${BRIDGE_STATE_FILE}" ]]; then
    return 1
  fi

  python3 - "${BRIDGE_STATE_FILE}" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

bridge_host = str(data.get("bridgeHost") or "").strip()
gdb_host = str(data.get("gdbHost") or "").strip()
bridge_port = data.get("bridgePort")
gdb_port = data.get("gdbPort")

def parse_port(raw):
    try:
        value = int(raw)
    except Exception:
        return ""
    if 1 <= value <= 65535:
        return str(value)
    return ""

print(
    "\t".join(
        [
            bridge_host,
            parse_port(bridge_port),
            gdb_host,
            parse_port(gdb_port),
        ]
    )
)
PY
}

resolve_ipv4_target() {
  local host="$1"
  python3 - "${host}" <<'PY'
import ipaddress
import socket
import sys

host = sys.argv[1]
try:
    ipaddress.ip_address(host)
    print(host)
    raise SystemExit(0)
except ValueError:
    pass

try:
    infos = socket.getaddrinfo(host, None, socket.AF_INET, socket.SOCK_STREAM)
except OSError:
    print(host)
    raise SystemExit(0)

seen = set()
for family, _, _, _, sockaddr in infos:
    if family != socket.AF_INET:
        continue
    ip = sockaddr[0]
    if ip in seen:
        continue
    seen.add(ip)
    print(ip)
    raise SystemExit(0)

print(host)
PY
}

kill_existing_proxy_listener() {
  local port="$1"

  if [[ -f "${PID_FILE}" ]]; then
    local old_pid
    old_pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" >/dev/null 2>&1; then
      kill "${old_pid}" >/dev/null 2>&1 || true
    fi
    rm -f "${PID_FILE}"
  fi

  if command -v lsof >/dev/null 2>&1; then
    local listener_pids
    listener_pids="$(lsof -t -iTCP:${port} -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -n "${listener_pids}" ]]; then
      local pid
      while IFS= read -r pid; do
        if [[ -z "${pid}" ]]; then
          continue
        fi
        local command_line
        command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
        if [[ "${command_line}" == *gdb-tcp-proxy.py* ]]; then
          kill "${pid}" >/dev/null 2>&1 || true
        fi
      done <<< "${listener_pids}"
    fi
  fi

  if command -v pkill >/dev/null 2>&1; then
    pkill -f "gdb-tcp-proxy.py.*--listen-port[[:space:]]+${port}" >/dev/null 2>&1 || true
  fi
}

if [[ "${in_container}" != "1" ]]; then
  if wait_for_local_listener "${CONNECT_RETRIES}"; then
    exit 0
  fi

  echo "[nds-debug] No local GDB endpoint on 127.0.0.1:${PORT}." >&2
  echo "[nds-debug] Host melonDS did not open ARM9 GDB stub." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "[nds-debug] python3 is required to start the local GDB proxy." >&2
  exit 1
fi
if [[ ! -f "${PROXY_SCRIPT}" ]]; then
  echo "[nds-debug] Missing proxy script: ${PROXY_SCRIPT}" >&2
  exit 1
fi

STATE_BRIDGE_HOST=""
STATE_BRIDGE_PORT=""
STATE_GDB_HOST=""
STATE_GDB_PORT=""
if state_line="$(resolve_bridge_state 2>/dev/null || true)"; then
  if [[ -n "${state_line}" ]]; then
    IFS=$'\t' read -r STATE_BRIDGE_HOST STATE_BRIDGE_PORT STATE_GDB_HOST STATE_GDB_PORT <<< "${state_line}"
  fi
fi

if [[ -n "${STATE_BRIDGE_PORT}" ]]; then
  BRIDGE_PORT="${STATE_BRIDGE_PORT}"
fi

REMOTE_HOST_OVERRIDE="${NDS_GDB_HOST:-${NDS_BRIDGE_HOST:-}}"
REMOTE_GDB_PORT="${NDS_REMOTE_GDB_PORT:-${STATE_GDB_PORT:-${PORT}}}"
if ! [[ "${REMOTE_GDB_PORT}" =~ ^[0-9]+$ ]] || [[ "${REMOTE_GDB_PORT}" -lt 1 ]] || [[ "${REMOTE_GDB_PORT}" -gt 65535 ]]; then
  echo "[nds-debug] Invalid remote GDB port: ${REMOTE_GDB_PORT}" >&2
  exit 1
fi

declare -a BRIDGE_HOST_CANDIDATES=()
if [[ -n "${REMOTE_HOST_OVERRIDE}" ]]; then
  BRIDGE_HOST_CANDIDATES+=("${REMOTE_HOST_OVERRIDE}")
fi
if [[ -n "${STATE_BRIDGE_HOST}" ]]; then
  BRIDGE_HOST_CANDIDATES+=("${STATE_BRIDGE_HOST}")
fi
BRIDGE_HOST_CANDIDATES+=(
  host.docker.internal
  gateway.docker.internal
  host.containers.internal
  docker.for.mac.host.internal
)

REMOTE_HOST=""
for candidate in "${BRIDGE_HOST_CANDIDATES[@]}"; do
  if bridge_health_ok "${candidate}" "${BRIDGE_PORT}"; then
    REMOTE_HOST="${candidate}"
    break
  fi
done

if [[ -z "${REMOTE_HOST}" ]]; then
  echo "[nds-debug] Could not reach host bridge on port ${BRIDGE_PORT}." >&2
  echo "[nds-debug] Checked hosts: ${BRIDGE_HOST_CANDIDATES[*]}" >&2
  exit 1
fi

REMOTE_CONNECT_HOST="${STATE_GDB_HOST:-${REMOTE_HOST}}"
if [[ -z "${REMOTE_CONNECT_HOST}" ]]; then
  REMOTE_CONNECT_HOST="${REMOTE_HOST}"
fi
REMOTE_CONNECT_HOST="$(resolve_ipv4_target "${REMOTE_CONNECT_HOST}")"

echo "[nds-debug] Forwarding 127.0.0.1:${PORT} -> ${REMOTE_CONNECT_HOST}:${REMOTE_GDB_PORT}" >&2

kill_existing_proxy_listener "${PORT}"
: > "${LOG_FILE}"

if command -v setsid >/dev/null 2>&1; then
  setsid python3 "${PROXY_SCRIPT}" \
    --listen-host 127.0.0.1 \
    --listen-port "${PORT}" \
    --remote-host "${REMOTE_CONNECT_HOST}" \
    --remote-port "${REMOTE_GDB_PORT}" \
    --log-file "${LOG_FILE}" \
    >"${LOG_FILE}" 2>&1 < /dev/null &
elif command -v nohup >/dev/null 2>&1; then
  nohup python3 "${PROXY_SCRIPT}" \
    --listen-host 127.0.0.1 \
    --listen-port "${PORT}" \
    --remote-host "${REMOTE_CONNECT_HOST}" \
    --remote-port "${REMOTE_GDB_PORT}" \
    --log-file "${LOG_FILE}" \
    >"${LOG_FILE}" 2>&1 < /dev/null &
else
  python3 "${PROXY_SCRIPT}" \
    --listen-host 127.0.0.1 \
    --listen-port "${PORT}" \
    --remote-host "${REMOTE_CONNECT_HOST}" \
    --remote-port "${REMOTE_GDB_PORT}" \
    --log-file "${LOG_FILE}" \
    >"${LOG_FILE}" 2>&1 < /dev/null &
fi

PROXY_PID="$!"
echo "${PROXY_PID}" >"${PID_FILE}"
sleep 0.2

if ! kill -0 "${PROXY_PID}" >/dev/null 2>&1; then
  echo "[nds-debug] Failed to start local GDB proxy for 127.0.0.1:${PORT} -> ${REMOTE_CONNECT_HOST}:${REMOTE_GDB_PORT}" >&2
  echo "[nds-debug] See ${LOG_FILE}" >&2
  rm -f "${PID_FILE}"
  exit 1
fi

if ! wait_for_local_listener 50; then
  echo "[nds-debug] Failed to establish local proxy 127.0.0.1:${PORT} -> ${REMOTE_CONNECT_HOST}:${REMOTE_GDB_PORT}" >&2
  echo "[nds-debug] See ${LOG_FILE}" >&2
  kill "${PROXY_PID}" >/dev/null 2>&1 || true
  rm -f "${PID_FILE}"
  exit 1
fi

exit 0

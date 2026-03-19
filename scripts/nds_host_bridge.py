#!/usr/bin/env python3
"""Host-side HTTP bridge to launch melonDS from host or devcontainer."""

from __future__ import annotations

import argparse
import json
import os
import platform
import re
import signal
import shutil
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional


EMULATOR_ALIASES = {
    "melonds": "melonds",
}

LOG_LOCK = threading.Lock()


def log(message: str) -> None:
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    with LOG_LOCK:
        print(f"[{timestamp}] {message}", flush=True)


def normalize_emulator(raw: Optional[str]) -> str:
    name = (raw or "melonds").strip()
    key = name.lower()
    normalized = EMULATOR_ALIASES.get(key)
    if normalized:
        return normalized
    raise ValueError(f"Unsupported emulator '{name}'. Supported value: melonds")


def _append_if_exists(candidates: list[str], value: Optional[str]) -> None:
    if not value:
        return
    path = Path(value).expanduser()
    if path.is_file():
        candidates.append(str(path))


def _is_wsl() -> bool:
    release = platform.release().lower()
    if "microsoft" in release:
        return True
    try:
        return "microsoft" in Path("/proc/version").read_text(encoding="utf-8").lower()
    except OSError:
        return False


def _candidate_paths() -> tuple[list[str], list[str]]:
    candidates: list[str] = []

    _append_if_exists(candidates, os.environ.get("NDS_EMULATOR_BIN"))
    _append_if_exists(candidates, os.environ.get("MELONDS_BIN"))

    if platform.system() == "Darwin":
        _append_if_exists(candidates, "/Applications/melonDS.app/Contents/MacOS/melonDS")
        _append_if_exists(candidates, "/Applications/melonDS.app/Contents/MacOS/melonDS-arm64")
        _append_if_exists(candidates, "/Applications/melonDS.app/Contents/MacOS/melonDS-x86_64")
    elif platform.system() == "Windows":
        _append_if_exists(
            candidates,
            str(Path(os.environ.get("ProgramFiles", "")) / "melonDS" / "melonDS.exe"),
        )
        _append_if_exists(
            candidates,
            str(Path(os.environ.get("ProgramFiles(x86)", "")) / "melonDS" / "melonDS.exe"),
        )
        _append_if_exists(
            candidates,
            str(Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "melonDS" / "melonDS.exe"),
        )
    else:
        _append_if_exists(candidates, "/usr/bin/melonds")
        _append_if_exists(candidates, "/usr/local/bin/melonds")
        _append_if_exists(candidates, "/usr/bin/melonDS")
        _append_if_exists(candidates, "/usr/local/bin/melonDS")
        if _is_wsl():
            _append_if_exists(candidates, "/mnt/c/Program Files/melonDS/melonDS.exe")
            _append_if_exists(candidates, "/mnt/c/Program Files (x86)/melonDS/melonDS.exe")

    return candidates, ["melonds", "melonDS"]


def resolve_emulator_bin(explicit: Optional[str]) -> str:
    if explicit:
        explicit_path = Path(explicit).expanduser()
        if explicit_path.is_file():
            return str(explicit_path)
        raise FileNotFoundError(f"Emulator binary not found at: {explicit}")

    candidates, path_bins = _candidate_paths()

    for candidate in candidates:
        if Path(candidate).is_file():
            return candidate

    for bin_name in path_bins:
        in_path = shutil.which(bin_name)
        if in_path:
            return in_path

    raise FileNotFoundError(
        "Could not find emulator binary for 'melonds'. "
        "Set NDS_EMULATOR_BIN (or MELONDS_BIN) to your melonDS executable path."
    )


def build_launch_command(emulator_bin: str, rom_path: Path) -> list[str]:
    return [emulator_bin, str(rom_path)]


def can_connect_tcp(host: str, port: int, timeout_seconds: float = 0.25) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout_seconds):
            return True
    except OSError:
        return False


def is_tcp_listener_local(port: int) -> bool:
    lsof_bin = shutil.which("lsof")
    if lsof_bin:
        result = subprocess.run(
            [lsof_bin, "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        return result.returncode == 0

    # Fallback where lsof is unavailable.
    return can_connect_tcp("127.0.0.1", port)


def wait_for_tcp(host: str, port: int, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if can_connect_tcp(host, port):
            return True
        time.sleep(0.1)
    return False


def wait_for_listener_port(port: int, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        if is_tcp_listener_local(port):
            return True
        time.sleep(0.1)
    return False


def list_listener_processes(port: int) -> list[tuple[int, str]]:
    lsof_bin = shutil.which("lsof")
    if not lsof_bin:
        return []

    try:
        result = subprocess.run(
            [lsof_bin, "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-Fpc"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return []

    if result.returncode != 0:
        return []

    listeners: list[tuple[int, str]] = []
    current_pid: Optional[int] = None
    for raw_line in result.stdout.splitlines():
        if not raw_line:
            continue
        tag = raw_line[0]
        value = raw_line[1:]
        if tag == "p":
            try:
                current_pid = int(value)
            except ValueError:
                current_pid = None
        elif tag == "c" and current_pid is not None:
            listeners.append((current_pid, value))
            current_pid = None

    deduped: list[tuple[int, str]] = []
    seen: set[tuple[int, str]] = set()
    for item in listeners:
        if item in seen:
            continue
        seen.add(item)
        deduped.append(item)
    return deduped


def _wait_for_pid_exit(pid: int, timeout_seconds: float) -> bool:
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            return False
        time.sleep(0.1)
    return False


def terminate_pid(pid: int) -> None:
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    except PermissionError:
        return

    if _wait_for_pid_exit(pid, timeout_seconds=2.0):
        return

    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    except PermissionError:
        return
    _wait_for_pid_exit(pid, timeout_seconds=1.0)


def parse_bool(value: object, default: bool = True) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in ("1", "true", "yes", "on"):
            return True
        if normalized in ("0", "false", "no", "off"):
            return False
    return default


def parse_port(value: object, default: int) -> int:
    if value is None:
        return default
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise ValueError(f"Invalid gdb_port: {value}") from exc
    if parsed <= 0 or parsed > 65535:
        raise ValueError(f"Invalid gdb_port: {value}")
    return parsed


def resolve_melonds_config_path() -> Path:
    override = os.environ.get("NDS_MELONDS_CONFIG", "").strip()
    if override:
        return Path(override).expanduser()

    system = platform.system()
    candidates: list[Path] = []

    if system == "Darwin":
        candidates.extend(
            [
                Path.home() / "Library" / "Preferences" / "melonDS" / "melonDS.toml",
                Path.home() / "Library" / "Application Support" / "melonDS" / "melonDS.toml",
            ]
        )
    elif system == "Windows":
        app_data = os.environ.get("APPDATA", "")
        local_app_data = os.environ.get("LOCALAPPDATA", "")
        if app_data:
            candidates.append(Path(app_data) / "melonDS" / "melonDS.toml")
        if local_app_data:
            candidates.append(Path(local_app_data) / "melonDS" / "melonDS.toml")
    else:
        candidates.extend(
            [
                Path.home() / ".config" / "melonDS" / "melonDS.toml",
                Path.home() / ".local" / "share" / "melonDS" / "melonDS.toml",
            ]
        )

    if not candidates:
        return Path.home() / ".config" / "melonDS" / "melonDS.toml"

    for candidate in candidates:
        if candidate.is_file():
            return candidate

    return candidates[0]


def upsert_toml_key(text: str, section: str, key: str, value_literal: str) -> str:
    if text and not text.endswith("\n"):
        text += "\n"

    lines = text.splitlines(keepends=True)
    section_header = f"[{section}]"
    section_start_index: Optional[int] = None

    for index, line in enumerate(lines):
        stripped = line.strip()
        if stripped == section_header:
            section_start_index = index
            break

        if line.startswith(section_header):
            trailing = line[len(section_header) :].strip()
            lines[index] = f"{section_header}\n"
            if trailing:
                lines.insert(index + 1, f"{trailing}\n")
            section_start_index = index
            break

    if section_start_index is None:
        if lines and lines[-1].strip():
            lines.append("\n")
        lines.append(f"{section_header}\n")
        section_start_index = len(lines) - 1

    section_end_index = len(lines)
    for index in range(section_start_index + 1, len(lines)):
        if re.match(r"^\s*\[[^\]]+\]\s*$", lines[index].strip()):
            section_end_index = index
            break

    key_re = re.compile(rf"^\s*{re.escape(key)}\s*=")
    for index in range(section_start_index + 1, section_end_index):
        if key_re.match(lines[index]):
            lines[index] = f"{key} = {value_literal}\n"
            return "".join(lines)

    lines.insert(section_end_index, f"{key} = {value_literal}\n")
    return "".join(lines)


def sanitize_section(text: str, section: str) -> str:
    lines = text.splitlines(keepends=True)
    header = f"[{section}]"
    section_starts: list[int] = []

    index = 0
    while index < len(lines):
        line = lines[index]
        if line.startswith(header):
            trailing = line[len(header) :].strip()
            lines[index] = f"{header}\n"
            if trailing:
                lines.insert(index + 1, f"{trailing}\n")
                index += 1
            section_starts.append(index)
        index += 1

    if len(section_starts) <= 1:
        return "".join(lines)

    ranges_to_remove: list[tuple[int, int]] = []
    for start in section_starts[1:]:
        end = len(lines)
        for index in range(start + 1, len(lines)):
            if re.match(r"^\s*\[[^\]]+\]\s*$", lines[index].strip()):
                end = index
                break
        ranges_to_remove.append((start, end))

    for start, end in reversed(ranges_to_remove):
        del lines[start:end]

    return "".join(lines)


def configure_melonds_debug(debug: bool, gdb_port: int) -> Optional[Path]:
    config_path = resolve_melonds_config_path()
    if not debug and not config_path.exists():
        return None

    text = ""
    if config_path.exists():
        text = config_path.read_text(encoding="utf-8")

    text = sanitize_section(text, "Instance0.Gdb")
    text = sanitize_section(text, "Instance0.Gdb.ARM9")
    text = sanitize_section(text, "Instance0.Gdb.ARM7")
    text = sanitize_section(text, "JIT")

    if debug:
        text = upsert_toml_key(text, "Instance0.Gdb", "Enabled", "true")
        text = upsert_toml_key(text, "Instance0.Gdb.ARM9", "Port", str(gdb_port))
        # Keep startup running by default. VSCode controls stopping via breakpoints.
        text = upsert_toml_key(text, "Instance0.Gdb.ARM9", "BreakOnStartup", "false")
        text = upsert_toml_key(text, "Instance0.Gdb.ARM7", "Port", str(gdb_port + 1))
        text = upsert_toml_key(text, "Instance0.Gdb.ARM7", "BreakOnStartup", "false")
        # melonDS upstream states GDB stub and JIT cannot run together.
        text = upsert_toml_key(text, "JIT", "Enable", "false")
    else:
        text = upsert_toml_key(text, "Instance0.Gdb", "Enabled", "false")
        text = upsert_toml_key(text, "Instance0.Gdb.ARM9", "Port", str(gdb_port))
        text = upsert_toml_key(text, "Instance0.Gdb.ARM9", "BreakOnStartup", "false")
        text = upsert_toml_key(text, "Instance0.Gdb.ARM7", "Port", str(gdb_port + 1))
        text = upsert_toml_key(text, "Instance0.Gdb.ARM7", "BreakOnStartup", "false")

    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(text, encoding="utf-8")
    return config_path


class BridgeState:
    def __init__(
        self,
        emulator: str,
        emulator_bin: Optional[str],
        workspace_root: Path,
        gdb_port: int,
        gdb_bridge_port: int,
    ):
        self.default_emulator = normalize_emulator(emulator)
        self.default_emulator_bin = emulator_bin
        self.workspace_root = workspace_root
        self.default_gdb_port = gdb_port
        self.gdb_bridge_port = gdb_bridge_port
        self.active_gdb_port = gdb_port
        self.process: Optional[subprocess.Popen] = None
        self.lock = threading.Lock()

    def get_active_gdb_port(self) -> int:
        with self.lock:
            return self.active_gdb_port

    @staticmethod
    def _monitor_emulator_process(process: subprocess.Popen) -> None:
        rc = process.wait()
        log(f"Emulator pid={process.pid} exited with code {rc}")

    def launch(
        self,
        rom: str,
        debug: bool = False,
        emulator: Optional[str] = None,
        emulator_bin: Optional[str] = None,
        gdb_port: Optional[int] = None,
    ) -> dict:
        with self.lock:
            rom_path = Path(rom)
            if not rom_path.is_absolute():
                rom_path = (self.workspace_root / rom_path).resolve()
            if not rom_path.is_file():
                raise FileNotFoundError(f"ROM not found: {rom}")

            selected_emulator = normalize_emulator(emulator or self.default_emulator)
            if selected_emulator != "melonds":
                raise ValueError("Only melonDS is supported in this setup.")

            selected_emulator_bin = resolve_emulator_bin(emulator_bin or self.default_emulator_bin)
            selected_gdb_port = gdb_port or self.default_gdb_port
            self.active_gdb_port = selected_gdb_port

            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)

            stale_listeners = [
                (pid, command)
                for pid, command in list_listener_processes(selected_gdb_port)
                if "melonds" in command.lower()
            ]
            for pid, command in stale_listeners:
                log(
                    "Terminating stale melonDS listener on "
                    f"port {selected_gdb_port}: pid={pid} ({command})"
                )
                terminate_pid(pid)

            config_path = configure_melonds_debug(debug=debug, gdb_port=selected_gdb_port)
            log(
                "Launch request: "
                f"emulator={selected_emulator}, debug={debug}, "
                f"rom={rom_path}, gdb_port={selected_gdb_port}, "
                f"config={config_path}"
            )

            cmd = build_launch_command(selected_emulator_bin, rom_path)
            self.process = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            log(f"Started emulator pid={self.process.pid}")
            threading.Thread(
                target=self._monitor_emulator_process,
                args=(self.process,),
                daemon=True,
            ).start()

            if debug and not wait_for_listener_port(selected_gdb_port, timeout_seconds=20.0):
                self.process.terminate()
                try:
                    self.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=2)

                config_note = ""
                if config_path:
                    config_note = f" Checked config: {config_path}."

                raise RuntimeError(
                    "melonDS did not expose ARM9 GDB on 127.0.0.1:"
                    f"{selected_gdb_port}.{config_note} "
                    "Ensure melonDS supports GDB stub and restart it after config changes."
                )

            return {
                "ok": True,
                "pid": self.process.pid,
                "cmd": cmd,
                "emulator": selected_emulator,
                "debug": debug,
                "gdb_port": selected_gdb_port,
                "gdb_bridge_port": self.gdb_bridge_port,
                "config_path": str(config_path) if config_path else "",
            }

    def health_payload(self) -> dict:
        return {
            "ok": True,
            "emulator": self.default_emulator,
            "debug_attach_supported": self.gdb_bridge_port > 0,
            "gdb_port": self.default_gdb_port,
            "gdb_bridge_port": self.gdb_bridge_port,
            "debug_emulator": "melonds",
        }


class GdbTcpForwarder:
    def __init__(self, bind_host: str, bind_port: int, state: BridgeState):
        self.bind_host = bind_host
        self.bind_port = bind_port
        self.state = state
        self.server: Optional[socket.socket] = None
        self.accept_thread: Optional[threading.Thread] = None
        self.stop_event = threading.Event()
        self._connection_id = 0
        self._connection_lock = threading.Lock()

    def _next_connection_id(self) -> int:
        with self._connection_lock:
            self._connection_id += 1
            return self._connection_id

    def start(self) -> None:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.bind_host, self.bind_port))
        server.listen(32)
        server.settimeout(1.0)
        self.server = server
        self.accept_thread = threading.Thread(target=self._accept_loop, daemon=True)
        self.accept_thread.start()
        log(
            "GDB bridge forwarder listening on "
            f"{self.bind_host}:{self.bind_port} -> 127.0.0.1:<active>"
        )

    def close(self) -> None:
        self.stop_event.set()
        if self.server is not None:
            try:
                self.server.close()
            except OSError:
                pass
            self.server = None
        if self.accept_thread is not None:
            self.accept_thread.join(timeout=1.0)
            self.accept_thread = None

    def _accept_loop(self) -> None:
        if self.server is None:
            return

        while not self.stop_event.is_set():
            try:
                client, _ = self.server.accept()
            except socket.timeout:
                continue
            except OSError:
                break

            threading.Thread(target=self._handle_client, args=(client,), daemon=True).start()

    def _handle_client(self, client: socket.socket) -> None:
        upstream: Optional[socket.socket] = None
        connection_id = self._next_connection_id()
        target_port = self.state.get_active_gdb_port()
        log(
            "GDB bridge forwarder: accepted client "
            f"#{connection_id}, target 127.0.0.1:{target_port}"
        )
        try:
            upstream = self._connect_upstream_with_retry()
            if upstream is None:
                log(
                    "GDB bridge forwarder: upstream unavailable for client "
                    f"#{connection_id} (dropped)"
                )
                return

            log(
                "GDB bridge forwarder: upstream connected for client "
                f"#{connection_id}"
            )
            t = threading.Thread(target=self._pipe_stream, args=(client, upstream), daemon=True)
            t.start()
            self._pipe_stream(upstream, client)
            t.join(timeout=1.0)
        except OSError as exc:
            log(f"GDB bridge forwarder socket error on client #{connection_id}: {exc}")
            return
        finally:
            try:
                client.close()
            except OSError:
                pass
            if upstream is not None:
                try:
                    upstream.close()
                except OSError:
                    pass
            log(f"GDB bridge forwarder: client #{connection_id} closed")

    def _connect_upstream_with_retry(self) -> Optional[socket.socket]:
        target_port = self.state.get_active_gdb_port()
        deadline = time.monotonic() + 3.0
        while time.monotonic() < deadline:
            try:
                upstream = socket.create_connection(("127.0.0.1", target_port), timeout=0.5)
                # Use connect timeout only for dialing; keep stream in blocking mode
                # for long-lived GDB sessions.
                upstream.settimeout(None)
                return upstream
            except OSError:
                time.sleep(0.1)
        return None

    @staticmethod
    def _pipe_stream(source: socket.socket, target: socket.socket) -> None:
        try:
            while True:
                try:
                    data = source.recv(4096)
                except socket.timeout:
                    # Non-fatal for stream bridges; continue waiting for payload.
                    continue
                if not data:
                    break
                target.sendall(data)
        except OSError:
            pass
        finally:
            try:
                target.shutdown(socket.SHUT_WR)
            except OSError:
                pass


def make_handler(state: BridgeState):
    class Handler(BaseHTTPRequestHandler):
        def _send_json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/health":
                self._send_json(200, state.health_payload())
            else:
                self._send_json(404, {"ok": False, "error": "Not found"})

        def do_POST(self) -> None:
            if self.path == "/shutdown":
                self._send_json(200, {"ok": True, "message": "Shutting down"})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
                return

            if self.path != "/launch":
                self._send_json(404, {"ok": False, "error": "Not found"})
                return

            try:
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length)
                data = json.loads(raw.decode("utf-8")) if raw else {}
                rom = data.get("rom", "")
                if not rom:
                    raise ValueError("Missing 'rom' in request body")

                debug = parse_bool(data.get("debug"), default=False)
                emulator = data.get("emulator")
                emulator_bin = data.get("emulator_bin")
                gdb_port = parse_port(data.get("gdb_port"), state.default_gdb_port)

                result = state.launch(
                    rom=rom,
                    debug=debug,
                    emulator=emulator,
                    emulator_bin=emulator_bin,
                    gdb_port=gdb_port,
                )
                self._send_json(200, result)
            except FileNotFoundError as exc:
                self._send_json(400, {"ok": False, "error": str(exc)})
            except ValueError as exc:
                self._send_json(400, {"ok": False, "error": str(exc)})
            except Exception as exc:  # noqa: BLE001
                self._send_json(500, {"ok": False, "error": str(exc)})

        def log_message(self, format: str, *args) -> None:  # noqa: A003
            return

    return Handler


def main() -> int:
    parser = argparse.ArgumentParser(description="Host bridge for launching melonDS")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument(
        "--port",
        type=int,
        default=int(os.environ.get("NDS_BRIDGE_PORT", "17778")),
    )
    parser.add_argument("--emulator", default=os.environ.get("NDS_EMULATOR", "melonds"))
    parser.add_argument(
        "--emulator-bin",
        default=os.environ.get("NDS_EMULATOR_BIN"),
    )
    parser.add_argument(
        "--workspace-root",
        default=str(Path(__file__).resolve().parent.parent),
        help="Repository root used to resolve relative ROM paths",
    )
    parser.add_argument(
        "--gdb-port",
        type=int,
        default=int(os.environ.get("NDS_GDB_PORT", "3333")),
        help="ARM9 GDB stub port used for debug sessions",
    )
    parser.add_argument(
        "--gdb-bridge-port",
        type=int,
        default=int(os.environ.get("NDS_BRIDGE_GDB_PORT", "3335")),
        help="Host bridge TCP forward port for container-to-host GDB attach",
    )
    args = parser.parse_args()

    try:
        default_emulator = normalize_emulator(args.emulator)
    except ValueError as exc:
        print(f"Warning: {exc}. Falling back to 'melonds'.")
        default_emulator = "melonds"

    try:
        resolved = resolve_emulator_bin(args.emulator_bin)
    except FileNotFoundError as exc:
        print(f"Warning: {exc}")
        resolved = args.emulator_bin

    workspace_root = Path(args.workspace_root).resolve()
    state = BridgeState(
        default_emulator,
        resolved,
        workspace_root,
        args.gdb_port,
        args.gdb_bridge_port,
    )
    gdb_forwarder: Optional[GdbTcpForwarder] = None
    try:
        gdb_forwarder = GdbTcpForwarder(args.host, args.gdb_bridge_port, state)
        gdb_forwarder.start()
    except OSError as exc:
        state.gdb_bridge_port = 0
        log(
            "Warning: could not start GDB bridge forwarder on "
            f"{args.host}:{args.gdb_bridge_port}: {exc}"
        )

    server = ThreadingHTTPServer((args.host, args.port), make_handler(state))

    log(
        "Host emulator bridge listening on "
        f"http://{args.host}:{args.port} "
        f"(default emulator: {default_emulator}, binary: {resolved or 'auto-detect'}, "
        f"gdb-local: {args.gdb_port}, gdb-bridge: {state.gdb_bridge_port or 'disabled'})"
    )

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        if gdb_forwarder is not None:
            gdb_forwarder.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

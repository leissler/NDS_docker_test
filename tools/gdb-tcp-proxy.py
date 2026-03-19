#!/usr/bin/env python3
"""TCP proxy for GDB remote sessions with a melonDS compatibility shim."""

from __future__ import annotations

import argparse
import socket
import threading
import time
from pathlib import Path
from typing import Optional


V_MUST_REPLY_EMPTY_PACKET = b"$vMustReplyEmpty#3a"
V_MUST_REPLY_EMPTY_RESPONSE = b"+$#00"


class Logger:
    def __init__(self, log_path: Path):
        self.log_path = log_path
        self.lock = threading.Lock()
        self.log_path.parent.mkdir(parents=True, exist_ok=True)

    def write(self, message: str) -> None:
        timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{timestamp}] {message}\n"
        with self.lock:
            self.log_path.open("a", encoding="utf-8").write(line)


class ProxyServer:
    def __init__(
        self,
        listen_host: str,
        listen_port: int,
        remote_host: str,
        remote_port: int,
        logger: Logger,
    ):
        self.listen_host = listen_host
        self.listen_port = listen_port
        self.remote_host = remote_host
        self.remote_port = remote_port
        self.logger = logger
        self.server: Optional[socket.socket] = None
        self.stop_event = threading.Event()
        self.connection_counter = 0
        self.connection_lock = threading.Lock()

    def _next_connection_id(self) -> int:
        with self.connection_lock:
            self.connection_counter += 1
            return self.connection_counter

    def run(self) -> int:
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((self.listen_host, self.listen_port))
        server.listen(16)
        server.settimeout(1.0)
        self.server = server
        self.logger.write(
            f"proxy listening on {self.listen_host}:{self.listen_port} -> {self.remote_host}:{self.remote_port}"
        )

        try:
            while not self.stop_event.is_set():
                try:
                    client, addr = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break

                connection_id = self._next_connection_id()
                self.logger.write(f"accepted client #{connection_id} from {addr[0]}:{addr[1]}")
                threading.Thread(
                    target=self._handle_client,
                    args=(connection_id, client),
                    daemon=True,
                ).start()
        finally:
            try:
                server.close()
            except OSError:
                pass
            self.server = None
        return 0

    def _handle_client(self, connection_id: int, client: socket.socket) -> None:
        remote: Optional[socket.socket] = None
        try:
            client.settimeout(1.0)
            try:
                first_chunk = client.recv(4096)
            except socket.timeout:
                self.logger.write(f"client #{connection_id}: idle probe (no payload), closing")
                return

            if not first_chunk:
                self.logger.write(f"client #{connection_id}: disconnected before payload")
                return

            client.settimeout(None)
            remote = socket.create_connection((self.remote_host, self.remote_port), timeout=3.0)
            remote.settimeout(None)
            self.logger.write(
                f"client #{connection_id}: connected upstream {self.remote_host}:{self.remote_port}"
            )

            t = threading.Thread(
                target=self._remote_to_client,
                args=(connection_id, remote, client),
                daemon=True,
            )
            t.start()

            self._client_to_remote_with_shim(connection_id, client, remote, first_chunk)
            t.join(timeout=1.0)
        except OSError as exc:
            self.logger.write(f"client #{connection_id}: socket error: {exc}")
        finally:
            try:
                client.close()
            except OSError:
                pass
            if remote is not None:
                try:
                    remote.close()
                except OSError:
                    pass
            self.logger.write(f"client #{connection_id}: closed")

    def _remote_to_client(self, connection_id: int, remote: socket.socket, client: socket.socket) -> None:
        try:
            while True:
                data = remote.recv(4096)
                if not data:
                    break
                client.sendall(data)
        except OSError:
            pass
        finally:
            try:
                client.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            self.logger.write(f"client #{connection_id}: upstream EOF")

    def _client_to_remote_with_shim(
        self,
        connection_id: int,
        client: socket.socket,
        remote: socket.socket,
        initial_data: bytes,
    ) -> None:
        buffer = initial_data

        try:
            while True:
                if not buffer:
                    chunk = client.recv(4096)
                    if not chunk:
                        break
                    buffer += chunk

                while True:
                    marker_index = buffer.find(V_MUST_REPLY_EMPTY_PACKET)
                    if marker_index < 0:
                        # Flush immediately unless the trailing bytes are a
                        # potential prefix of the marker packet.
                        keep_from = -1
                        dollar_index = buffer.rfind(b"$")
                        if dollar_index >= 0 and V_MUST_REPLY_EMPTY_PACKET.startswith(buffer[dollar_index:]):
                            keep_from = dollar_index

                        if keep_from < 0:
                            send_data = buffer
                            buffer = b""
                        elif keep_from == 0:
                            send_data = b""
                        else:
                            send_data = buffer[:keep_from]
                            buffer = buffer[keep_from:]

                        if send_data:
                            remote.sendall(send_data)
                        break

                    if marker_index > 0:
                        remote.sendall(buffer[:marker_index])

                    buffer = buffer[marker_index + len(V_MUST_REPLY_EMPTY_PACKET) :]
                    client.sendall(V_MUST_REPLY_EMPTY_RESPONSE)
                    self.logger.write(f"client #{connection_id}: handled vMustReplyEmpty locally")
        except OSError:
            pass
        finally:
            if buffer:
                try:
                    remote.sendall(buffer)
                except OSError:
                    pass
            try:
                remote.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            self.logger.write(f"client #{connection_id}: client EOF")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="TCP proxy for GDB sessions")
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--remote-host", required=True)
    parser.add_argument("--remote-port", type=int, required=True)
    parser.add_argument("--log-file", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logger = Logger(Path(args.log_file))
    server = ProxyServer(
        listen_host=args.listen_host,
        listen_port=args.listen_port,
        remote_host=args.remote_host,
        remote_port=args.remote_port,
        logger=logger,
    )
    return server.run()


if __name__ == "__main__":
    raise SystemExit(main())

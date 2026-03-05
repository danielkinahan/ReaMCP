"""
bridge_client.py
Thin JSON-RPC-over-TCP client that talks to reaper_mcp_bridge.lua running
inside REAPER.  Uses only the Python stdlib – no third-party packages.
"""
from __future__ import annotations

import json
import socket
import threading
from typing import Any

_DEFAULT_HOST = "127.0.0.1"
_DEFAULT_PORT = 9001
_RECV_BUF = 65536


class BridgeError(RuntimeError):
    """Raised when the Lua bridge returns an error payload."""


class BridgeClient:
    """
    Persistent TCP connection to the REAPER Lua bridge.

    Thread-safe: a lock serialises request/response pairs so that multiple
    MCP tool calls queued rapidly don't interleave on the socket.
    """

    def __init__(self, host: str = _DEFAULT_HOST, port: int = _DEFAULT_PORT) -> None:
        self._host = host
        self._port = port
        self._sock: socket.socket | None = None
        self._file: Any = None  # socket.makefile wrapper for line reads
        self._lock = threading.Lock()
        self._id = 0

    # ------------------------------------------------------------------
    # Connection management
    # ------------------------------------------------------------------

    def _connect(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5.0)
        try:
            sock.connect((self._host, self._port))
        except OSError as exc:
            sock.close()
            raise BridgeError(
                f"Cannot connect to REAPER bridge at {self._host}:{self._port}. "
                "Make sure REAPER is running and reaper_mcp_bridge.lua is active. "
                f"Details: {exc}"
            ) from exc
        sock.settimeout(10.0)  # per-call timeout after connection
        self._sock = sock
        self._file = sock.makefile("r", encoding="utf-8")

    def _ensure_connected(self) -> None:
        if self._sock is None:
            self._connect()

    def _reset(self) -> None:
        """Drop the current connection so the next call reconnects."""
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass
        self._sock = None
        self._file = None

    # ------------------------------------------------------------------
    # RPC
    # ------------------------------------------------------------------

    def call(self, method: str, **params: Any) -> Any:
        """
        Send a JSON-RPC request and return the `result` field.
        Raises BridgeError on transport problems or when the bridge
        returns an `error` field.
        """
        with self._lock:
            self._id += 1
            req_id = self._id
            payload = json.dumps({"id": req_id, "method": method, "params": params})

            # Retry once if the socket was dead (e.g. REAPER restarted)
            for attempt in range(2):
                try:
                    self._ensure_connected()
                    assert self._sock is not None
                    self._sock.sendall((payload + "\n").encode("utf-8"))
                    line = self._file.readline()  # type: ignore[union-attr]
                    if not line:
                        raise OSError("Connection closed by REAPER bridge")
                    response: dict[str, Any] = json.loads(line)
                    break
                except (OSError, json.JSONDecodeError, AssertionError) as exc:
                    self._reset()
                    if attempt == 1:
                        raise BridgeError(f"Bridge communication error: {exc}") from exc

            if "error" in response:
                raise BridgeError(response["error"])

            return response.get("result")

    def close(self) -> None:
        with self._lock:
            self._reset()

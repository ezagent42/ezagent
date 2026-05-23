# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
ezagent_python — small Python-side library for Domain.Python plugins.

Per SPEC docs/superpowers/specs/2026-05-23-domain-python.md §6.

Plugins import this module, register handlers with @method, and call
run() to enter the event loop. The library has NO non-stdlib
dependencies so plugins do not inherit any.

Plugins find this module by importing through the directory ezagent
sets in the EZAGENT_PYTHON_LIB_DIR env var when launching the
subprocess:

    import os, sys
    sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])
    from ezagent_python import method, run, log, progress, RpcError

The wire is LSP-framed JSON-RPC 2.0 (Content-Length: N\\r\\n\\r\\n<body>),
binary-clean for embedded newlines and base64 attachments.

V1 supports:
  * BEAM -> Python requests + notifications.
  * Python -> BEAM `log` and `progress` notifications.
  * Built-in `python.ping` request + `python.shutdown` notification
    (handled internally; plugins never see them).

V1 does NOT support Python -> BEAM requests (deliberate; SPEC §2.3
explains the rationale).
"""

from __future__ import annotations

import json
import sys
import threading
import traceback
from typing import Any, Callable, Optional

_HANDLERS: dict[str, Callable[[dict], Any]] = {}
_stdout_lock = threading.Lock()


class RpcError(Exception):
    """Raised inside a handler to send a structured JSON-RPC error response.

    The lib catches this and serializes {code, message, data?} into the
    `error` field of the response. Application error codes >= -32000
    per the JSON-RPC 2.0 spec; standard codes (-32700, -32600, -32601,
    -32602, -32603) are reserved for protocol-level errors but plugin
    handlers may use -32602 for "invalid params" type rejections.
    """

    def __init__(self, code: int, message: str, data: Any = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


def method(name: str):
    """Decorator: register a JSON-RPC method handler.

    Handler signature: ``def handler(params: dict) -> Any``. The return
    value is serialized as the JSON-RPC `result` field. Raise RpcError
    for structured errors; any other exception is caught and reported
    as -32603 internal error with the traceback in the `data` field.
    """

    def wrap(fn):
        _HANDLERS[name] = fn
        return fn

    return wrap


def log(level: str, message: str, **meta) -> None:
    """Send a `log` notification to BEAM.

    `level` is one of: "debug", "info", "warn"/"warning", "error".
    `meta` is an arbitrary JSON-serializable dict relayed to the
    Elixir Logger metadata.
    """
    _send_frame(
        {
            "jsonrpc": "2.0",
            "method": "log",
            "params": {"level": level, "message": message, "meta": meta or {}},
        }
    )


def progress(call_id: str, fraction: float, message: str = "") -> None:
    """Send a `progress` notification to BEAM.

    Used by long-running handlers to keep the caller informed. BEAM
    emits telemetry [:ezagent, :python, :progress] for each one;
    `call_id` lets the caller correlate progress with their call.
    """
    _send_frame(
        {
            "jsonrpc": "2.0",
            "method": "progress",
            "params": {"id": call_id, "fraction": fraction, "message": message},
        }
    )


# --- internals -------------------------------------------------------------


def _read_frame() -> Optional[dict]:
    """Read one LSP-framed JSON-RPC frame from stdin.

    Returns the decoded JSON object, or None on EOF / partial body.
    Raises ValueError if the headers are malformed (missing
    Content-Length, non-numeric value).
    """
    headers: dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        decoded = line.decode("ascii", errors="strict").rstrip("\r\n")
        if decoded == "":
            break
        if ":" not in decoded:
            raise ValueError(f"malformed header line: {decoded!r}")
        k, _, v = decoded.partition(":")
        headers[k.strip().lower()] = v.strip()

    if "content-length" not in headers:
        raise ValueError(f"missing Content-Length header in {headers!r}")

    n = int(headers["content-length"])
    body = sys.stdin.buffer.read(n)
    if len(body) < n:
        return None
    return json.loads(body)


def _send_frame(obj: dict) -> None:
    body = json.dumps(obj).encode("utf-8")
    header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
    with _stdout_lock:
        sys.stdout.buffer.write(header)
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()


def _handle_request(msg: dict) -> None:
    req_id = msg.get("id")
    name = msg.get("method", "")
    params = msg.get("params", {}) or {}

    # Built-in: python.ping (readiness gate).
    if name == "python.ping":
        _send_frame({"jsonrpc": "2.0", "id": req_id, "result": {"pong": True}})
        return

    handler = _HANDLERS.get(name)
    if handler is None:
        _send_frame(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32601,
                    "message": f"method not found: {name}",
                },
            }
        )
        return

    try:
        result = handler(params)
        _send_frame({"jsonrpc": "2.0", "id": req_id, "result": result})
    except RpcError as e:
        err: dict[str, Any] = {"code": e.code, "message": e.message}
        if e.data is not None:
            err["data"] = e.data
        _send_frame({"jsonrpc": "2.0", "id": req_id, "error": err})
    except Exception as e:  # noqa: BLE001
        _send_frame(
            {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {
                    "code": -32603,
                    "message": f"{type(e).__name__}: {e}",
                    "data": {"traceback": traceback.format_exc()},
                },
            }
        )


def _handle_notification(msg: dict) -> None:
    name = msg.get("method", "")
    if name == "python.shutdown":
        # Built-in: graceful exit. BEAM still force-stops via
        # `:exec.stop/1` if we don't return in shutdown_grace_ms.
        sys.exit(0)

    handler = _HANDLERS.get(name)
    if handler is not None:
        try:
            handler(msg.get("params", {}) or {})
        except Exception:  # noqa: BLE001
            log(
                "error",
                f"notification handler {name} raised",
                traceback=traceback.format_exc(),
            )


def run() -> None:
    """Event loop: read frames, dispatch, write responses, until stdin EOF.

    Single-threaded by design (SPEC §6.2 — V1 has no asyncio variant).
    A blocking handler stops all other RPC servicing for this
    subprocess; BEAM treats this as `:subprocess_unhealthy` after the
    caller's timeout and tears it down. Plugin authors with
    long-running work should pass a generous `timeout` from the
    Elixir-side `call/4`.
    """
    while True:
        try:
            msg = _read_frame()
        except ValueError as e:
            log("error", f"frame read error: {e}")
            return

        if msg is None:
            return

        if "id" in msg and "method" in msg:
            _handle_request(msg)
        elif "method" in msg:
            _handle_notification(msg)
        # Result / error envelopes (BEAM -> Python -> BEAM) are not
        # supported in V1 — BEAM does not send requests through the
        # Python subprocess except as the initiating caller.

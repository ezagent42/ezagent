#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=13"]
# ///
"""
Minimal Codex app-server thread bootstrap repro.

This bypasses ezagent and the AgentBridge sidecar. It starts a real
`codex app-server`, connects to the unix socket with WebSocket-over-UDS,
runs initialize + initialized + thread/start, and prints the returned
thread id.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any

import websockets


def wait_for_socket(socket_path: Path, proc: subprocess.Popen[bytes], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if socket_path.exists():
            return
        if proc.poll() is not None:
            raise RuntimeError(f"codex app-server exited early with status {proc.returncode}")
        time.sleep(0.1)
    raise TimeoutError(f"codex app-server did not create {socket_path}")


async def rpc_call(ws, req_id: int, method: str, params: dict[str, Any]) -> dict[str, Any]:
    frame = {"id": req_id, "method": method, "params": params}
    print(f"> id={req_id} method={method}")
    await ws.send(json.dumps(frame, separators=(",", ":")))
    while True:
        raw = await asyncio.wait_for(ws.recv(), timeout=30)
        print(f"< {raw[:300]}")
        msg = json.loads(raw)
        if msg.get("id") != req_id:
            continue
        if "error" in msg:
            raise RuntimeError(msg["error"])
        return msg.get("result") or {}


async def run(codex_bin: str, timeout: float) -> str:
    tmp = Path(tempfile.mkdtemp(prefix="codex-thread-repro-"))
    workspace = tmp / "workspace"
    workspace.mkdir()
    socket_path = tmp / "app-server.sock"

    app_server = subprocess.Popen(
        [codex_bin, "app-server", "--listen", f"unix://{socket_path}"],
        cwd=workspace,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    try:
        wait_for_socket(socket_path, app_server, timeout)
        async with websockets.unix_connect(
            str(socket_path),
            uri="ws://localhost/",
            compression=None,
            max_size=None,
        ) as ws:
            await rpc_call(
                ws,
                1,
                "initialize",
                {
                    "clientInfo": {
                        "name": "ezagent-codex-repro",
                        "title": "Ezagent Codex Repro",
                        "version": "0.1.0",
                    },
                    "capabilities": {"experimentalApi": True},
                },
            )
            await ws.send(json.dumps({"method": "initialized"}, separators=(",", ":")))
            result = await rpc_call(
                ws,
                2,
                "thread/start",
                {"cwd": str(workspace), "sessionStartSource": "startup", "ephemeral": False},
            )
            thread = result.get("thread") or {}
            thread_id = thread.get("id")
            if not thread_id:
                raise RuntimeError(f"thread/start did not return thread.id: {result!r}")
            return thread_id
    finally:
        if app_server.poll() is None:
            app_server.terminate()
            try:
                app_server.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                app_server.kill()
                app_server.communicate()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-bin", default=shutil.which("codex") or "codex")
    parser.add_argument("--timeout", type=float, default=10.0)
    args = parser.parse_args()
    thread_id = asyncio.run(run(args.codex_bin, args.timeout))
    print(f"ok: thread/start returned thread id {thread_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

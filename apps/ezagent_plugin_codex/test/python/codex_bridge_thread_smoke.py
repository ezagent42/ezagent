#!/usr/bin/env python3
"""
Smoke-test the codex bridge thread bootstrap path without running mix.

This launches a real `codex app-server`, then launches the Python
AgentBridge sidecar with a deliberately unreachable Phoenix socket. The
sidecar must create or resume a Codex thread and persist
EZAGENT_CODEX_THREAD_ID_FILE before it attempts any useful WS work.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def bridge_script() -> Path:
    return repo_root() / "apps/ezagent_plugin_codex/priv/python/ezagent_codex_bridge.py"


def runner_for_bridge() -> list[str]:
    uv = shutil.which("uv")
    if uv:
        return [uv, "run", "--script", str(bridge_script())]
    return [sys.executable, str(bridge_script())]


def terminate(proc: subprocess.Popen[bytes] | None) -> bytes:
    if proc is None:
        return b""
    if proc.poll() is None:
        proc.terminate()
        try:
            return proc.communicate(timeout=5)[0] or b""
        except subprocess.TimeoutExpired:
            proc.kill()
    try:
        out, _ = proc.communicate(timeout=1)
        return out or b""
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
        return out or b""


def wait_for_socket(socket_path: Path, proc: subprocess.Popen[bytes], timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if socket_path.exists():
            return
        if proc.poll() is not None:
            raise RuntimeError(f"codex app-server exited early with status {proc.returncode}")
        time.sleep(0.1)
    raise TimeoutError(f"codex app-server did not create {socket_path}")


def wait_for_thread_file(thread_file: Path, bridge: subprocess.Popen[bytes], timeout: float) -> str:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if thread_file.exists():
            thread_id = thread_file.read_text(encoding="utf-8").strip()
            if thread_id:
                return thread_id
        if bridge.poll() is not None:
            raise RuntimeError(f"codex bridge exited early with status {bridge.returncode}")
        time.sleep(0.1)
    raise TimeoutError(f"codex bridge did not write {thread_file}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--codex-bin", default=shutil.which("codex") or "codex")
    parser.add_argument("--timeout", type=float, default=45.0)
    args = parser.parse_args()

    tmp = Path(tempfile.mkdtemp(prefix="ezagent-codex-bridge-smoke-"))
    workspace = tmp / "workspace"
    workspace.mkdir()
    socket_path = tmp / "app-server.sock"
    thread_file = tmp / "bridge-thread-id"

    app_server: subprocess.Popen[bytes] | None = None
    bridge: subprocess.Popen[bytes] | None = None

    try:
        app_server = subprocess.Popen(
            [args.codex_bin, "app-server", "--listen", f"unix://{socket_path}"],
            cwd=workspace,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        wait_for_socket(socket_path, app_server, 10)

        env = os.environ.copy()
        env.update(
            {
                "EZAGENT_AGENT_URI": "entity://system/agent/codex_smoke",
                "EZAGENT_AGENT_TOKEN": "smoke",
                "EZAGENT_BRIDGE_WS_URL": "ws://127.0.0.1:9/agent_bridge/websocket",
                "EZAGENT_CODEX_APP_SERVER_SOCK": str(socket_path),
                "EZAGENT_CODEX_THREAD_ID_FILE": str(thread_file),
                "EZAGENT_CODEX_CWD": str(workspace),
                "EZAGENT_CODEX_BIN": args.codex_bin,
                "EZAGENT_CODEX_RPC_TIMEOUT": "20",
                "EZAGENT_HOME": str(tmp / "ezagent-home"),
                "EZAGENT_PROFILE": "smoke",
            }
        )

        bridge = subprocess.Popen(
            runner_for_bridge(),
            cwd=workspace,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            env=env,
        )

        thread_id = wait_for_thread_file(thread_file, bridge, args.timeout)
        print(f"ok: bridge wrote codex thread id {thread_id} to {thread_file}")
        return 0
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        bridge_output = terminate(bridge).decode("utf-8", errors="replace")
        app_output = terminate(app_server).decode("utf-8", errors="replace")
        if bridge_output:
            print("--- bridge output ---", file=sys.stderr)
            print(bridge_output, file=sys.stderr)
        if app_output:
            print("--- app-server output ---", file=sys.stderr)
            print(app_output, file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())

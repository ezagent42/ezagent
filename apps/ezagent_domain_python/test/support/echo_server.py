# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Echo / test-method fixture for the Domain.Python integration suite.

Imports the Python lib via the EZAGENT_PYTHON_LIB_DIR env var so the
documented plugin-author pattern (SPEC §6.3, codex round-1 MEDIUM-3)
is exercised end-to-end.
"""

from __future__ import annotations

import os
import sys
import time

# Required by SPEC §6.3: Domain.Python sets EZAGENT_PYTHON_LIB_DIR
# pointing at apps/ezagent_domain_python/priv/python/.
sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])

from ezagent_python import method, run, log, RpcError  # noqa: E402


@method("echo")
def echo(params):
    """Echo back exactly what was sent (used by integration test)."""
    return params


@method("throws")
def throws(_params):
    """Always raises — exercises the -32603 internal-error path."""
    raise RuntimeError("intentional exception from echo_server.throws")


@method("rpc_error")
def rpc_error(_params):
    """Raise a structured RpcError — exercises the application-error path."""
    raise RpcError(-32099, "structured error from fixture", data={"hint": "expected"})


@method("log_something")
def log_something(_params):
    """Notification handler that just logs."""
    log("info", "hello from echo_server", source="log_something")
    return {"logged": True}


@method("block_forever")
def block_forever(_params):
    """Hang past any caller-side timeout — exercises §3.3.1 tear-down."""
    while True:
        time.sleep(60)


@method("sleep_ms")
def sleep_ms(params):
    """Sleep for `ms` then return — used by late-result-race test."""
    ms = int(params.get("ms", 0))
    time.sleep(ms / 1000.0)
    return {"slept_ms": ms}


@method("stderr_flood")
def stderr_flood(params):
    """Write `bytes_total` bytes to stderr in `chunk` increments.

    Used by the bounded-stderr invariant test.
    """
    bytes_total = int(params.get("bytes_total", 1024))
    chunk = int(params.get("chunk", 4096))
    written = 0
    payload = ("x" * chunk + "\n").encode("ascii")
    while written < bytes_total:
        sys.stderr.buffer.write(payload)
        sys.stderr.buffer.flush()
        written += len(payload)
    return {"written": written}


if __name__ == "__main__":
    run()

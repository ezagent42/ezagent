#!/usr/bin/env python3
"""
fake_claude.py — a deterministic stand-in for the real `claude` TUI used
by the cc-agent admin->reply e2e (Test A).

## What it simulates

The cc.agent Template Class builds an argv list:

    [claude_path, "--permission-mode", "bypassPermissions",
     "--dangerously-load-development-channels", "server:esr-bridge",
     "--settings", <operator?>, "--settings", <mandatory>,
     "--mcp-config", <esr-bridge>, "--mcp-config", <operator?>]

…and hands it to erlexec/PTY. The real `claude` would:
  1. spawn each `--mcp-config` MCP server as a subprocess (stdio MCP),
  2. send `initialize` + `notifications/initialized` + `tools/list`,
  3. on receiving a `notifications/claude/channel` from a server,
     present it to the LLM, which eventually calls `tools/call` on the
     server's `reply` tool.

This fake reproduces the parts the e2e cares about — the round-trip
through `ezagent_mcp_bridge.py` — WITHOUT requiring Anthropic API
credentials or the claude binary:

  * parses its own argv to find every `--mcp-config <path>`,
  * for each, loads the JSON and looks up the `esr-bridge` MCP server,
  * spawns it as a subprocess with the configured command/args/env,
  * sends `initialize` + `notifications/initialized` + `tools/list`,
  * listens on the subprocess stdout for one `notifications/claude/channel`,
  * extracts `meta.session` from the notification, then sends a single
    `tools/call name=reply args={text: "<FAKE_REPLY_PREFIX><inbound>",
     session_uris: [<that session>], ref: <inbound message_id>}`,
  * waits a short grace window for the WS frame to flush and exits 0.

Also writes a small status file (`<FAKE_CLAUDE_STATUS_FILE>`) recording
the parsed argv + bridge command, so the e2e can assert the fake actually
saw the mandatory `--settings` last-wins flag (proving the safety
invariant is non-bypassable end-to-end).

## Env vars consumed

  * FAKE_CLAUDE_STATUS_FILE — path to write the JSON status doc to
  * FAKE_REPLY_PREFIX — text prefix the reply will use (default "echo: ")
  * FAKE_CLAUDE_GRACE_MS — extra ms to keep the bridge alive after sending
    the reply, so the WS frame definitely lands (default 1500)
  * FAKE_CLAUDE_TIMEOUT_S — outer wall-clock cap (default 30)

## Failure modes (all exit non-zero, with diagnostics on stderr)

  * No --mcp-config in argv → exit 10
  * mcp.json missing esr-bridge server → exit 11
  * bridge subprocess fails to start → exit 12
  * No notifications/claude/channel arrives within timeout → exit 13
"""
import json
import os
import subprocess
import sys
import threading
import time
from pathlib import Path


def log(msg):
    sys.stderr.write(f"[fake-claude] {msg}\n")
    sys.stderr.flush()


def parse_argv(argv):
    """Pull every --mcp-config <path> and every --settings <path> out of argv.

    Order matters for --settings — claude is last-wins, so the LAST
    --settings is the mandatory plugin safety file (rev-1 hardening).
    The fake records the full sequence so the e2e can assert it.
    """
    settings = []
    mcp_configs = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--settings" and i + 1 < len(argv):
            settings.append(argv[i + 1])
            i += 2
        elif a == "--mcp-config" and i + 1 < len(argv):
            mcp_configs.append(argv[i + 1])
            i += 2
        else:
            i += 1
    return settings, mcp_configs


def write_status(status_path, doc):
    """Atomic status-file write — the e2e reads this after the fake exits."""
    if not status_path:
        return
    tmp = status_path + f".tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(doc, f, indent=2)
    os.replace(tmp, status_path)


def find_esr_bridge_server(mcp_configs):
    """Find the esr-bridge entry across the operator + plugin mcp configs.

    The plugin always emits the trusted esr-bridge config first; an
    operator one is additive. The first config that defines an
    `esr-bridge` server wins (the plugin's).
    """
    for path in mcp_configs:
        try:
            with open(path, "r", encoding="utf-8") as f:
                config = json.load(f)
        except Exception as e:
            log(f"cannot read {path}: {e}")
            continue
        servers = (config.get("mcpServers") or {})
        if "esr-bridge" in servers:
            return path, servers["esr-bridge"]
    return None, None


def spawn_bridge(server_spec):
    cmd = [server_spec["command"]] + list(server_spec.get("args", []))
    env = dict(os.environ)
    for k, v in (server_spec.get("env") or {}).items():
        env[k] = str(v)
    log(f"spawning bridge: {cmd}")
    log(f"  env keys: {sorted((server_spec.get('env') or {}).keys())}")
    p = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        bufsize=0,
    )
    return p


def send_jsonrpc(p, doc):
    line = (json.dumps(doc) + "\n").encode("utf-8")
    p.stdin.write(line)
    p.stdin.flush()


def reader_loop(p, queue, stop):
    """Read bridge stdout line-by-line into queue. Daemon thread."""
    try:
        for raw in iter(p.stdout.readline, b""):
            if stop.is_set():
                return
            try:
                line = raw.decode("utf-8", errors="replace").rstrip("\n")
            except Exception:
                continue
            if not line.strip():
                continue
            try:
                doc = json.loads(line)
            except Exception:
                log(f"non-JSON from bridge: {line[:200]}")
                continue
            queue.append(doc)
    finally:
        stop.set()


def main():
    status_path = os.environ.get("FAKE_CLAUDE_STATUS_FILE", "")
    reply_prefix = os.environ.get("FAKE_REPLY_PREFIX", "echo: ")
    grace_ms = int(os.environ.get("FAKE_CLAUDE_GRACE_MS", "1500"))
    timeout_s = float(os.environ.get("FAKE_CLAUDE_TIMEOUT_S", "30"))

    settings, mcp_configs = parse_argv(sys.argv[1:])
    status = {
        "argv": sys.argv,
        "cwd": os.getcwd(),
        "env": {
            k: os.environ.get(k, "")
            for k in ("CLAUDE_CONFIG_DIR", "EZAGENT_AGENT_URI", "EZAGENT_AGENT_TOKEN")
        },
        "settings_chain": settings,
        "mcp_config_chain": mcp_configs,
        "phase": "argv_parsed",
    }
    write_status(status_path, status)

    if not mcp_configs:
        log("no --mcp-config in argv")
        status["phase"] = "no_mcp_config"
        write_status(status_path, status)
        sys.exit(10)

    config_path, server_spec = find_esr_bridge_server(mcp_configs)
    if not server_spec:
        log(f"no esr-bridge in any of: {mcp_configs}")
        status["phase"] = "no_esr_bridge_server"
        write_status(status_path, status)
        sys.exit(11)

    status["bridge_config_used"] = config_path
    status["bridge_command"] = [server_spec["command"]] + list(server_spec.get("args", []))
    status["phase"] = "bridge_resolved"
    write_status(status_path, status)

    try:
        p = spawn_bridge(server_spec)
    except Exception as e:
        log(f"bridge spawn failed: {e}")
        status["phase"] = "bridge_spawn_failed"
        status["error"] = str(e)
        write_status(status_path, status)
        sys.exit(12)

    inbox = []
    stop = threading.Event()
    t = threading.Thread(target=reader_loop, args=(p, inbox, stop), daemon=True)
    t.start()

    try:
        # MCP handshake
        send_jsonrpc(p, {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                         "params": {"protocolVersion": "2024-11-05"}})
        send_jsonrpc(p, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        send_jsonrpc(p, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})

        status["phase"] = "mcp_initialized"
        write_status(status_path, status)

        # Wait for the first notifications/claude/channel
        deadline = time.time() + timeout_s
        inbound = None
        last_seen_idx = 0
        while time.time() < deadline:
            if stop.is_set():
                log("bridge stopped before we saw a channel notification")
                break
            while last_seen_idx < len(inbox):
                doc = inbox[last_seen_idx]
                last_seen_idx += 1
                method = doc.get("method")
                if method == "notifications/claude/channel":
                    inbound = doc
                    break
            if inbound is not None:
                break
            time.sleep(0.05)

        if inbound is None:
            log("no notifications/claude/channel arrived in time")
            status["phase"] = "no_inbound_notification"
            status["bridge_alive"] = (p.poll() is None)
            write_status(status_path, status)
            sys.exit(13)

        params = inbound.get("params") or {}
        content = params.get("content", "")
        meta = params.get("meta") or {}
        session_uri = meta.get("session", "")
        message_id = meta.get("message_id", "")

        status["phase"] = "inbound_received"
        status["inbound_content"] = content
        status["inbound_meta"] = meta
        write_status(status_path, status)

        if not session_uri:
            log(f"inbound notification has no session in meta: {meta}")
            status["phase"] = "no_session_in_meta"
            write_status(status_path, status)
            sys.exit(14)

        reply_text = reply_prefix + content
        send_jsonrpc(p, {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "reply",
                "arguments": {
                    "text": reply_text,
                    "session_uris": [session_uri],
                    "ref": message_id,
                },
            },
        })
        status["phase"] = "reply_sent"
        status["reply_text"] = reply_text
        write_status(status_path, status)

        # Wait for the bridge to ack the tools/call and flush the WS frame.
        # The bridge's enqueue_outbound -> WS send is async; give it the
        # grace window before tearing the subprocess down.
        time.sleep(grace_ms / 1000.0)

        status["phase"] = "done"
        write_status(status_path, status)
        sys.exit(0)

    finally:
        stop.set()
        try:
            p.stdin.close()
        except Exception:
            pass
        try:
            p.terminate()
            p.wait(timeout=3)
        except Exception:
            try:
                p.kill()
            except Exception:
                pass


if __name__ == "__main__":
    main()

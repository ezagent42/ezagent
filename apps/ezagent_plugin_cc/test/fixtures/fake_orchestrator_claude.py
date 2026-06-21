#!/usr/bin/env python3
"""Deterministic Claude stand-in for orchestrator MCP CLI E2E.

It starts every MCP server in the supplied --mcp-config files, performs the
minimal MCP handshake, optionally executes FAKE_ORCH_TOOL_CALLS, then stays
alive long enough for session-create readiness gates to observe the
orchestrator bridge join.
"""

import json
import os
import subprocess
import sys
import threading
import time


def log(message):
    sys.stderr.write(f"[fake-orch-claude] {message}\n")
    sys.stderr.flush()


def parse_mcp_configs(argv):
    configs = []
    i = 0
    while i < len(argv):
        if argv[i] == "--mcp-config" and i + 1 < len(argv):
            configs.append(argv[i + 1])
            i += 2
        else:
            i += 1
    return configs


def load_servers(config_paths):
    servers = []
    for config_path in config_paths:
        try:
            with open(config_path, "r", encoding="utf-8") as fh:
                config = json.load(fh)
        except Exception as exc:
            log(f"cannot read {config_path}: {exc}")
            continue

        for name, spec in (config.get("mcpServers") or {}).items():
            servers.append((name, config_path, spec))
    return servers


def spawn_server(name, spec):
    command = [spec["command"]] + list(spec.get("args", []))
    env = dict(os.environ)
    for key, value in (spec.get("env") or {}).items():
        env[key] = str(value)

    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=env,
        bufsize=0,
    )

    inbox = []
    stop = threading.Event()

    def reader():
        try:
            for raw in iter(process.stdout.readline, b""):
                if stop.is_set():
                    return
                line = raw.decode("utf-8", errors="replace").strip()
                if not line:
                    continue
                try:
                    inbox.append(json.loads(line))
                except Exception:
                    log(f"{name}: non-json: {line[:240]}")
        finally:
            stop.set()

    threading.Thread(target=reader, daemon=True).start()
    return {"name": name, "process": process, "inbox": inbox, "stop": stop, "next_id": 1}


def send(server, method, params=None):
    req_id = server["next_id"]
    server["next_id"] += 1
    doc = {"jsonrpc": "2.0", "id": req_id, "method": method}
    if params is not None:
        doc["params"] = params
    line = json.dumps(doc) + "\n"
    server["process"].stdin.write(line.encode("utf-8"))
    server["process"].stdin.flush()
    return req_id


def notify(server, method):
    line = json.dumps({"jsonrpc": "2.0", "method": method}) + "\n"
    server["process"].stdin.write(line.encode("utf-8"))
    server["process"].stdin.flush()


def wait_reply(server, req_id, timeout=45.0):
    deadline = time.time() + timeout
    seen = 0
    while time.time() < deadline:
        while seen < len(server["inbox"]):
            doc = server["inbox"][seen]
            seen += 1
            if doc.get("id") == req_id:
                return doc
        if server["stop"].is_set():
            break
        time.sleep(0.05)
    return None


def initialize(server):
    req_id = send(
        server,
        "initialize",
        {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "fake-orch"}},
    )
    wait_reply(server, req_id, timeout=15.0)
    notify(server, "notifications/initialized")
    req_id = send(server, "tools/list", {})
    wait_reply(server, req_id, timeout=15.0)


def call_tool(server, name, arguments):
    req_id = send(server, "tools/call", {"name": name, "arguments": arguments})
    return wait_reply(server, req_id, timeout=60.0)


def write_status(path, doc):
    if not path:
        return
    tmp = f"{path}.tmp-{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=2)
    os.replace(tmp, path)


def main():
    status_path = os.environ.get("FAKE_ORCH_STATUS_FILE", "")
    calls_json = os.environ.get("FAKE_ORCH_TOOL_CALLS", "[]")
    delay_ms = int(os.environ.get("FAKE_ORCH_CALL_DELAY_MS", "2000"))
    hold_ms = int(os.environ.get("FAKE_ORCH_HOLD_MS", "180000"))

    configs = parse_mcp_configs(sys.argv[1:])
    servers = load_servers(configs)
    status = {
        "configs": configs,
        "servers": [
            {
                "name": name,
                "config_path": path,
                "command": [spec.get("command")] + list(spec.get("args", [])),
                "env": spec.get("env", {}) or {},
            }
            for name, path, spec in servers
        ],
        "calls": [],
    }
    write_status(status_path, status)

    if not servers:
        log("no MCP servers found")
        status["phase"] = "no_servers"
        write_status(status_path, status)
        sys.exit(10)

    running = []
    try:
        for name, _config_path, spec in servers:
            server = spawn_server(name, spec)
            running.append(server)
            initialize(server)

        status["phase"] = "initialized"
        write_status(status_path, status)

        try:
            planned_calls = json.loads(calls_json)
        except Exception as exc:
            log(f"bad FAKE_ORCH_TOOL_CALLS: {exc}")
            planned_calls = []

        if planned_calls:
            time.sleep(delay_ms / 1000.0)

        orchestrator = next((s for s in running if s["name"] == "esr-orchestrator"), None)
        for call in planned_calls:
            if orchestrator is None:
                result = {"error": "esr-orchestrator server not configured"}
            else:
                result = call_tool(
                    orchestrator,
                    call.get("name", ""),
                    call.get("arguments", {}) or {},
                )
            status["calls"].append({"call": call, "result": result})
            write_status(status_path, status)

        status["phase"] = "holding"
        write_status(status_path, status)
        time.sleep(hold_ms / 1000.0)
        status["phase"] = "done"
        write_status(status_path, status)
        sys.exit(0)
    finally:
        for server in running:
            server["stop"].set()
            try:
                server["process"].stdin.close()
            except Exception:
                pass
            try:
                server["process"].terminate()
                server["process"].wait(timeout=3)
            except Exception:
                try:
                    server["process"].kill()
                except Exception:
                    pass


if __name__ == "__main__":
    main()

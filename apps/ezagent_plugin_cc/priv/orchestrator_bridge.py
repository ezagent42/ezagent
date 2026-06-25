#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=13"]
# ///
"""
orchestrator_bridge — the orchestrator MCP transport bridge
(ezagent Phase 7 completion, SPEC §2 "PR-5").

## Why this exists

`Ezagent.Orchestrator.McpServer` is an Ezagent-side Elixir module — the 7
privileged orchestration tools (`add_agent_slot`, `write_matcher`,
`update_template`, ...). A live `claude` orchestrator cannot talk to an
Elixir module: it talks to MCP servers listed in its `--mcp-config`.

This script IS that MCP server. It speaks the MCP protocol to `claude`
over stdio and forwards the calls it cannot answer locally onto the
BEAM over a WebSocket Phoenix Channel — the SAME house transport the
cc channel bridge (``ezagent_mcp_bridge.py``) uses for the ``reply``
tool. The two bridges are deliberately structurally identical:

* MCP stdio front end (``initialize`` / ``tools/list`` / ``tools/call``);
* a WebSocket Phoenix Channel back end keyed by the agent URI;
* token auth at connect (the connect token minted for the agent);
* a daemon stdin thread + an asyncio WS loop.

## tools/list — served locally from a shipped schema file

The 7 tool JSON schemas live in `Ezagent.Orchestrator.McpServer.tool_schemas/0`
(Elixir). The Ezagent seed (`Ezagent.Orchestrator.CcOrchestratorSeed`)
exports them to a JSON file next to this script and points
``EZAGENT_ORCHESTRATOR_TOOLS_PATH`` at it. `tools/list` is answered
from that file — so the configured `uv run --script` command starts a
working MCP server that lists all 7 tools WITHOUT needing the BEAM up.
(The Channel also serves `mcp_tools_list` as a redundancy path.)

## tools/call — forwarded to the BEAM over the WS Channel

Each `tools/call` is forwarded as a Phoenix Channel
``mcp_tools_call`` push on topic ``orch:bridge:<orchestrator_uri>``.
The Channel routes it to the per-orchestrator
`Ezagent.Orchestrator.McpServer` and replies with a structured MCP
result. The orchestrator's caller / caps / session context is bound
SERVER-SIDE from the token-authenticated agent URI — this bridge
carries NO identity beyond the URI its token authenticates, so neither
the bridge nor the `claude` process can spoof another orchestrator.

## Env (written by the Ezagent seed / cc Template Class into the mcp.json)

* ``EZAGENT_BRIDGE_WS_URL`` — base WS URL. Default
  ``ws://127.0.0.1:10042/orchestrator_socket/websocket``.
* ``EZAGENT_AGENT_URI`` — the orchestrator agent URI this bridge
  serves (``entity://agent/<ws>/cc_orchestrator-<name>``).
* ``EZAGENT_AGENT_TOKEN`` — the per-instance connect token (minted by
  ``EzagentPluginCc.TokenStore`` — the orchestrator is a cc-flavored
  agent, so it already has one).
* ``EZAGENT_ORCHESTRATOR_TOOLS_PATH`` — path to the exported 7-tool
  schema JSON file. Default: ``orchestrator_tools.json`` next to this
  script.
* ``EZAGENT_HOME`` / ``EZAGENT_PROFILE`` — log directory anchor.

A `claude` started via ``claude --mcp-config <orchestrator.mcp.json>``
inherits all of these from the mcp.json ``env`` block.
"""

import asyncio
import json
import logging
import os
import sys
import threading
from typing import Any
from urllib.parse import parse_qsl, urlencode, urlparse, urlunparse

import websockets

LOG = logging.getLogger("orchestrator_bridge")

WS_URL = os.environ.get(
    "EZAGENT_BRIDGE_WS_URL",
    "ws://127.0.0.1:10042/orchestrator_socket/websocket",
)
AGENT_URI = os.environ.get("EZAGENT_AGENT_URI", "")
AGENT_TOKEN = os.environ.get("EZAGENT_AGENT_TOKEN", "")
TOOLS_PATH = os.environ.get(
    "EZAGENT_ORCHESTRATOR_TOOLS_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "orchestrator_tools.json"),
)

# Phoenix Channel topic this bridge joins. The Channel asserts this
# equals the token-authenticated agent URI.
TOPIC = f"orch:bridge:{AGENT_URI}"

_stdout_lock = threading.Lock()
_ws_loop: asyncio.AbstractEventLoop | None = None
# ref -> asyncio.Future, resolved when the matching phx_reply arrives.
_pending: dict[str, "asyncio.Future"] = {}
_ref_counter = [0]
_join_ref = "1"
# Set once the Channel join succeeds; tools/call waits on it.
_joined = threading.Event()
_ws_send = None  # async callable installed once the WS is connected
# Set by the stdin EOF handler — `main()` awaits it and returns so the
# process exits cleanly when `claude` closes the bridge's stdin.
_shutdown: asyncio.Event | None = None


def setup_logging() -> None:
    """Log to ``$EZAGENT_HOME/<profile>/logs/orchestrator-bridge-<slug>.log``.

    Claude swallows MCP-server stderr — without a file sink the bridge
    runs invisibly. Mirrors ``ezagent_mcp_bridge.py``'s layout.
    """
    home = os.path.expanduser(os.environ.get("EZAGENT_HOME", "~/.ezagent"))
    profile = os.environ.get("EZAGENT_PROFILE", "default")
    log_dir = os.path.join(home, profile, "logs")
    try:
        os.makedirs(log_dir, exist_ok=True)
        slug = AGENT_URI.replace("://", "-").replace("/", "_") or "anon"
        log_path = os.path.join(log_dir, f"orchestrator-bridge-{slug}.log")
        handler: logging.Handler = logging.FileHandler(
            log_path, mode="a", encoding="utf-8"
        )
    except OSError:
        # Log dir unwritable (e.g. the offline tools/list test) — fall
        # back to stderr so the bridge still starts.
        handler = logging.StreamHandler(sys.stderr)
    handler.setFormatter(
        logging.Formatter("[orchestrator_bridge] %(asctime)s %(levelname)s %(message)s")
    )
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.handlers = [handler]


def write_frame(obj: dict) -> None:
    """One JSON line to stdout. Locked because the WS task also writes."""
    with _stdout_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def respond(req_id: Any, result: dict) -> None:
    write_frame({"jsonrpc": "2.0", "id": req_id, "result": result})


def respond_error(req_id: Any, code: int, message: str) -> None:
    write_frame(
        {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}
    )


# --- the 7 tool schemas ----------------------------------------------------


def load_tool_schemas() -> list[dict]:
    """Read the 7 orchestrator tool JSON schemas from the exported file.

    The file is written by the Ezagent seed
    (`Ezagent.Orchestrator.CcOrchestratorSeed`) from
    `Ezagent.Orchestrator.McpServer.tool_schemas/0` — the single
    source of truth. Returns ``[]`` if the file is absent (the bridge
    still starts; `tools/list` is then empty + logged).
    """
    try:
        with open(TOOLS_PATH, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict) and isinstance(data.get("tools"), list):
            return data["tools"]
        if isinstance(data, list):
            return data
        LOG.error("tool schema file %s has unexpected shape", TOOLS_PATH)
        return []
    except FileNotFoundError:
        LOG.error("tool schema file not found: %s", TOOLS_PATH)
        return []
    except (OSError, json.JSONDecodeError) as e:
        LOG.error("failed to read tool schemas from %s: %s", TOOLS_PATH, e)
        return []


# --- WebSocket plumbing ----------------------------------------------------


def ws_url_with_params() -> str:
    """Append token + agent_uri query params, mirroring McpSocket.connect/3.

    The returned URL carries the per-agent connect token in its query
    string — it MUST NOT be logged. Use ``redact_ws_url`` before
    putting any WebSocket URL into a log line, stdout, or stderr.
    """
    if not AGENT_URI or not AGENT_TOKEN:
        raise SystemExit(
            "orchestrator_bridge: EZAGENT_AGENT_URI + EZAGENT_AGENT_TOKEN "
            "required for tools/call; got AGENT_URI=%r TOKEN=%r"
            % (AGENT_URI, bool(AGENT_TOKEN))
        )
    parsed = urlparse(WS_URL)
    query = urlencode({"token": AGENT_TOKEN, "agent_uri": AGENT_URI, "vsn": "2.0.0"})
    return urlunparse(parsed._replace(query=query))


def redact_ws_url(url: str) -> str:
    """Return ``url`` with the ``token`` query parameter masked.

    The connect token authenticates as the orchestrator until rotated,
    so a WebSocket URL that carries it must never reach a log file,
    stdout, or stderr. This redacts only ``token`` and leaves
    ``agent_uri`` / ``vsn`` intact so the log line is still useful.
    """
    parsed = urlparse(url)
    if not parsed.query:
        return url
    pairs = parse_qsl(parsed.query, keep_blank_values=True)
    redacted = [(k, "***REDACTED***" if k == "token" else v) for k, v in pairs]
    return urlunparse(parsed._replace(query=urlencode(redacted)))


def redact_text(text: str) -> str:
    """Mask any occurrence of the connect token in an arbitrary string.

    Belt-and-braces for log paths that don't take a URL — e.g.
    ``websockets`` handshake exceptions can embed the full request URI
    (token and all) in ``str(exc)``. Replacing the literal token
    substring guarantees it never lands in a log line regardless of
    how the exception formats itself.
    """
    if not AGENT_TOKEN:
        return text
    return text.replace(AGENT_TOKEN, "***REDACTED***")


async def call_beam(event: str, payload: dict, timeout: float = 30.0) -> dict:
    """Push a Phoenix Channel event and await its phx_reply.

    Returns the reply's ``response`` map. Raises on timeout or a
    non-ok status.
    """
    if _ws_send is None:
        raise RuntimeError("WS not connected")

    _ref_counter[0] += 1
    ref = str(_ref_counter[0])
    fut: "asyncio.Future" = asyncio.get_running_loop().create_future()
    _pending[ref] = fut

    frame = [_join_ref, ref, TOPIC, event, payload]
    await _ws_send(json.dumps(frame))

    try:
        reply = await asyncio.wait_for(fut, timeout=timeout)
    finally:
        _pending.pop(ref, None)

    status = (reply or {}).get("status")
    response = (reply or {}).get("response", {})
    if status != "ok":
        raise RuntimeError(f"BEAM replied status={status!r}: {response!r}")
    return response


async def heartbeat_loop(ws) -> None:
    """Phoenix expects a heartbeat on topic 'phoenix' every 30s."""
    while True:
        await asyncio.sleep(30)
        _ref_counter[0] += 1
        frame = [None, str(_ref_counter[0]), "phoenix", "heartbeat", {}]
        await ws.send(json.dumps(frame))


async def inbound_loop(ws) -> None:
    """Resolve pending call futures as phx_reply frames arrive."""
    async for raw in ws:
        try:
            frame = json.loads(raw)
        except json.JSONDecodeError:
            LOG.warning("non-JSON WS frame: %r", raw[:120])
            continue

        if not isinstance(frame, list) or len(frame) < 5:
            continue

        _jr, ref, _topic, event, payload = frame[:5]
        if event == "phx_reply" and ref in _pending:
            fut = _pending.get(ref)
            if fut is not None and not fut.done():
                fut.set_result(payload or {})


async def connect_loop() -> None:
    """Connect → join → run inbound + heartbeat → reconnect on drop."""
    global _ws_send

    url = ws_url_with_params()
    # Pre-redacted form for logging — `url` itself carries the connect
    # token and must never reach a log line / stdout / stderr.
    safe_url = redact_ws_url(url)
    backoff = 2

    while True:
        try:
            LOG.info("connecting %s", safe_url)
            async with websockets.connect(url, max_size=None, proxy=None) as ws:
                _ws_send = ws.send
                LOG.info("ws connected; joining %s", TOPIC)

                join_frame = [_join_ref, "1", TOPIC, "phx_join", {}]
                _ref_counter[0] = 1
                await ws.send(json.dumps(join_frame))

                reply_raw = await asyncio.wait_for(ws.recv(), timeout=10)
                reply = json.loads(reply_raw)
                if not (
                    isinstance(reply, list)
                    and len(reply) >= 5
                    and reply[3] == "phx_reply"
                ):
                    LOG.error("unexpected join reply: %r", reply)
                    await asyncio.sleep(backoff)
                    continue
                status = (reply[4] or {}).get("status")
                if status != "ok":
                    LOG.error("join rejected: %r", reply[4])
                    await asyncio.sleep(backoff)
                    continue

                LOG.info("join ok; orchestrator MCP transport ready")
                _joined.set()
                backoff = 2

                await asyncio.gather(inbound_loop(ws), heartbeat_loop(ws))
        except (OSError, websockets.exceptions.WebSocketException) as e:
            _joined.clear()
            _ws_send = None
            # `websockets` handshake errors can embed the full request
            # URI (token included) in str(e) — redact before logging.
            LOG.warning("ws error: %s; retry in %ds", redact_text(str(e)), backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)
        except asyncio.TimeoutError:
            _joined.clear()
            _ws_send = None
            LOG.warning("ws join timeout; retry in %ds", backoff)
            await asyncio.sleep(backoff)


# --- MCP stdio handler -----------------------------------------------------


def handle_tools_call(req_id: Any, params: dict) -> None:
    """Forward a tools/call to the BEAM and respond with the MCP result."""
    tool = params.get("name", "")
    arguments = params.get("arguments", {}) or {}

    if _ws_loop is None:
        respond(
            req_id,
            {
                "isError": True,
                "content": [
                    {"type": "text", "text": "orchestrator bridge not connected to Ezagent"}
                ],
                "error": {
                    "code": "transport_unavailable",
                    "message": "orchestrator bridge not connected to Ezagent",
                },
            },
        )
        return

    async def _do() -> dict:
        # Wait briefly for the Channel join so the first tool call after
        # startup doesn't race the WS handshake.
        if not _joined.is_set():
            for _ in range(50):  # up to ~5s
                if _joined.is_set():
                    break
                await asyncio.sleep(0.1)
        return await call_beam(
            "mcp_tools_call", {"tool": tool, "arguments": arguments}
        )

    fut = asyncio.run_coroutine_threadsafe(_do(), _ws_loop)
    try:
        # The MCP result map produced by McpServer.handle_tool_call/3
        # (success or structured tool error) — pass it through verbatim.
        result = fut.result(timeout=45)
        respond(req_id, result)
    except Exception as e:  # noqa: BLE001 — surface any failure as an MCP error
        LOG.error("tools/call %s failed: %s", tool, e)
        respond(
            req_id,
            {
                "isError": True,
                "content": [{"type": "text", "text": f"tool call failed: {e}"}],
                "error": {"code": "transport_error", "message": str(e)},
            },
        )


def handle_mcp(msg: dict) -> None:
    method = msg.get("method", "")
    req_id = msg.get("id")
    params = msg.get("params", {}) or {}

    LOG.info("claude -> bridge: method=%s id=%s", method, req_id)

    if method == "initialize":
        respond(
            req_id,
            {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "esr-orchestrator", "version": "1.0.0"},
                "instructions": (
                    "The esr-orchestrator MCP server exposes the 7 Ezagent "
                    "session-orchestration tools. Call them to compose and "
                    "route a team of worker agents within your session."
                ),
            },
        )

    elif method == "notifications/initialized":
        pass

    elif method == "tools/list":
        respond(req_id, {"tools": load_tool_schemas()})

    elif method == "tools/call":
        handle_tools_call(req_id, params)

    elif req_id is not None:
        respond_error(req_id, -32601, f"Method not found: {method}")


def stdin_loop() -> None:
    """Read JSON-RPC frames from claude on stdin in a worker thread."""
    try:
        for raw in sys.stdin:
            line = raw.strip()
            if not line:
                continue
            try:
                handle_mcp(json.loads(line))
            except json.JSONDecodeError as e:
                LOG.error("bad JSON from claude: %s", e)
    finally:
        LOG.info("stdin EOF; orchestrator bridge shutting down")
        # Signal `main()` to return so the process exits cleanly when
        # `claude` closes the bridge's stdin.
        if _ws_loop is not None and _shutdown is not None:
            _ws_loop.call_soon_threadsafe(_shutdown.set)


async def main() -> None:
    global _shutdown, _ws_loop
    setup_logging()
    LOG.info(
        "orchestrator bridge starting; ws=%s agent=%s tools=%s",
        WS_URL,
        AGENT_URI or "(unset)",
        TOOLS_PATH,
    )

    _ws_loop = asyncio.get_running_loop()
    _shutdown = asyncio.Event()

    # stdio is blocking — drive it from a daemon thread so the asyncio
    # loop owns the WS connection. The same shape as ezagent_mcp_bridge.py.
    threading.Thread(target=stdin_loop, daemon=True).start()

    # If no agent token is configured, tools/call cannot reach the BEAM,
    # but tools/list (served locally from the schema file) still works.
    # This is the offline mode the integration test exercises to prove
    # the configured command starts a working MCP server.
    if not AGENT_URI or not AGENT_TOKEN:
        LOG.warning(
            "EZAGENT_AGENT_URI / EZAGENT_AGENT_TOKEN unset — running in "
            "offline mode: tools/list works, tools/call returns a "
            "transport-unavailable MCP error."
        )
        # Park until stdin EOF — claude keeps the stdio server alive
        # meanwhile and may call tools/list.
        await _shutdown.wait()
    else:
        # Run the WS connect loop, but stop as soon as stdin closes.
        conn = asyncio.ensure_future(connect_loop())
        stop = asyncio.ensure_future(_shutdown.wait())
        await asyncio.wait({conn, stop}, return_when=asyncio.FIRST_COMPLETED)
        conn.cancel()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except (KeyboardInterrupt, RuntimeError):
        # RuntimeError: loop already closed during shutdown teardown.
        pass

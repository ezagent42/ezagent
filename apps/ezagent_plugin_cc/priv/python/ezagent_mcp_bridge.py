#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=13"]
# ///
"""
esr_mcp_bridge — v2 bidirectional CC channel bridge (Phase 7 PR 32a).

Replaces ``esr_mcp_bridge_v1_prototype.py`` (HTTP/SSE wire) with a
single WebSocket Phoenix Channel client. Surface to Claude is
identical (MCP stdio with ``capabilities.experimental['claude/channel']``
+ ``reply`` tool with attachments support), so claude-side behavior is
preserved across the cutover.

## Env

* ``EZAGENT_BRIDGE_WS_URL`` — WebSocket endpoint URL.
  Default ``ws://127.0.0.1:10042/agent_bridge/websocket``.
* ``EZAGENT_AGENT_URI`` — agent the bridge represents (``agent://cc-demo``).
* ``EZAGENT_AGENT_TOKEN`` — token minted by ``EzagentPluginCc.TokenStore``;
  the Socket auth handler rejects connections without a matching token.
* ``EZAGENT_HOME`` / ``EZAGENT_PROFILE`` — log directory anchor; same
  per-bridge file scheme as v1.

All three env vars are written by ``EzagentPluginCc.McpConfigWriter``
(``mcp.json`` env block) so a Claude process started via ``claude
--mcp-config <path>`` inherits them.

## Wire (Phoenix Channel)

Frame envelope: ``[join_ref, ref, topic, event, payload]``.

* Join topic ``agent_bridge:cc:<agent_uri>`` with empty payload. If
  ``EZAGENT_BRIDGE_WS_URL`` points at the legacy ``/cc_socket`` mount,
  the bridge joins legacy topic ``cc:bridge:<agent_uri>`` instead.
* Inbound event ``"to_claude"`` payload ``{content, meta}`` →
  ``notifications/claude/channel`` JSON-RPC notification on stdout.
* Outbound event ``"reply"`` payload ``{text, session_uris, ref?,
  attachments?}`` when Claude calls the ``reply`` tool.
* Heartbeat ``[null, ref, "phoenix", "heartbeat", {}]`` every 30s.

## Reconnect

WebSocket disconnect → 2-second backoff loop. Token + agent_uri are
re-sent on each connect; the BridgeRegistry is idempotent on re-bind.
"""

import asyncio
import json
import logging
import os
import sys
import threading
from typing import Any

import websockets
from urllib.parse import urlencode, urlparse, urlunparse

LOG = logging.getLogger("esr_mcp_bridge")

WS_URL = os.environ.get("EZAGENT_BRIDGE_WS_URL", "ws://127.0.0.1:10042/agent_bridge/websocket")
AGENT_URI = os.environ.get("EZAGENT_AGENT_URI", "")
AGENT_TOKEN = os.environ.get("EZAGENT_AGENT_TOKEN", "")

_stdout_lock = threading.Lock()
_outbound_queue: asyncio.Queue | None = None
_outbound_loop: asyncio.AbstractEventLoop | None = None


def setup_logging() -> None:
    """Log to ``$EZAGENT_HOME/<profile>/logs/cc-bridge-<agent_uri_slug>.log``.

    Claude swallows MCP-server stderr — without a file sink the bridge
    runs invisibly. Mirrors the v1 layout so existing tail commands
    keep working.
    """
    home = os.path.expanduser(os.environ.get("EZAGENT_HOME", "~/.ezagent"))
    profile = os.environ.get("EZAGENT_PROFILE", "default")
    log_dir = os.path.join(home, profile, "logs")
    os.makedirs(log_dir, exist_ok=True)

    slug = AGENT_URI.replace("://", "-").replace("/", "_") or "anon"
    log_path = os.path.join(log_dir, f"cc-bridge-{slug}.log")

    handler = logging.FileHandler(log_path, mode="a", encoding="utf-8")
    handler.setFormatter(
        logging.Formatter(
            f"[esr_mcp_bridge {slug}] %(asctime)s %(levelname)s %(message)s"
        )
    )

    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.handlers = [handler]

    LOG.info("v2 bridge log: %s", log_path)


def write_frame(obj: dict) -> None:
    """One JSON line to stdout. Locked because the WS task also writes."""
    with _stdout_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def respond(req_id: Any, result: dict) -> None:
    write_frame({"jsonrpc": "2.0", "id": req_id, "result": result})


def push_notification_to_claude(content: str, meta: dict) -> None:
    write_frame(
        {
            "jsonrpc": "2.0",
            "method": "notifications/claude/channel",
            "params": {"content": content, "meta": meta},
        }
    )


# --- WebSocket plumbing ----------------------------------------------------


def ws_url_with_params() -> str:
    """Append token + agent_uri query params per Socket.connect/3."""
    if not AGENT_URI or not AGENT_TOKEN:
        raise SystemExit(
            "esr_mcp_bridge: EZAGENT_AGENT_URI + EZAGENT_AGENT_TOKEN required; "
            "got AGENT_URI=%r TOKEN=%r" % (AGENT_URI, bool(AGENT_TOKEN))
        )
    parsed = urlparse(WS_URL)
    query = urlencode({"token": AGENT_TOKEN, "agent_uri": AGENT_URI, "vsn": "2.0.0"})
    return urlunparse(parsed._replace(query=query))


def bridge_topic() -> str:
    """Return the Phoenix topic matching the selected bridge mount."""
    explicit = os.environ.get("EZAGENT_BRIDGE_TOPIC", "")
    if explicit:
        return explicit

    path = urlparse(WS_URL).path
    if "/cc_socket" in path:
        return f"cc:bridge:{AGENT_URI}"

    return f"agent_bridge:cc:{AGENT_URI}"


async def heartbeat_loop(ws, ref_counter) -> None:
    """Phoenix expects a heartbeat on topic 'phoenix' every 30s."""
    while True:
        await asyncio.sleep(30)
        ref_counter[0] += 1
        frame = [None, str(ref_counter[0]), "phoenix", "heartbeat", {}]
        await ws.send(json.dumps(frame))


async def outbound_loop(ws, join_ref, ref_counter) -> None:
    """Drain ``_outbound_queue`` (filled by Claude tool calls) onto WS."""
    while True:
        payload = await _outbound_queue.get()
        ref_counter[0] += 1
        frame = [
            join_ref,
            str(ref_counter[0]),
            bridge_topic(),
            "reply",
            payload,
        ]
        await ws.send(json.dumps(frame))


async def inbound_loop(ws) -> None:
    """Phoenix → claude. Forward ``to_claude`` frames as channel notifications."""
    async for raw in ws:
        try:
            frame = json.loads(raw)
        except json.JSONDecodeError:
            LOG.warning("non-JSON WS frame: %r", raw[:120])
            continue

        if not isinstance(frame, list) or len(frame) < 5:
            continue

        _join_ref, _ref, _topic, event, payload = frame[:5]

        if event == "to_claude":
            content = (payload or {}).get("content", "")
            meta = (payload or {}).get("meta", {}) or {}
            LOG.debug("to_claude: content=%.80r meta_keys=%s", content, list(meta))
            push_notification_to_claude(content, meta)


async def connect_loop() -> None:
    """Outer loop: connect → join → run inbound + outbound + heartbeat → reconnect."""
    global _outbound_queue, _outbound_loop
    _outbound_queue = asyncio.Queue()
    _outbound_loop = asyncio.get_running_loop()

    url = ws_url_with_params()
    backoff = 2

    while True:
        try:
            LOG.info("connecting %s", url)
            async with websockets.connect(url, max_size=None, proxy=None) as ws:
                topic = bridge_topic()
                LOG.info("ws connected; joining %s", topic)

                ref_counter = [0]
                join_ref = "1"
                ref_counter[0] = 1

                join_frame = [
                    join_ref,
                    "1",
                    topic,
                    "phx_join",
                    {},
                ]
                await ws.send(json.dumps(join_frame))

                # Phoenix replies with ["1","1",topic,"phx_reply",
                # {"response":{}, "status":"ok"}] — consume + verify before
                # starting the inbound loop so a join failure surfaces cleanly.
                reply_raw = await asyncio.wait_for(ws.recv(), timeout=10)
                reply = json.loads(reply_raw)
                if not (isinstance(reply, list) and len(reply) >= 5 and reply[3] == "phx_reply"):
                    LOG.error("unexpected join reply: %r", reply)
                    continue
                status = (reply[4] or {}).get("status")
                if status != "ok":
                    LOG.error("join rejected: %r", reply[4])
                    await asyncio.sleep(backoff)
                    continue

                LOG.info("join ok; starting loops")
                backoff = 2

                await asyncio.gather(
                    inbound_loop(ws),
                    outbound_loop(ws, join_ref, ref_counter),
                    heartbeat_loop(ws, ref_counter),
                )
        except (OSError, websockets.exceptions.WebSocketException) as e:
            LOG.warning("ws error: %s; retry in %ds", e, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)
        except asyncio.TimeoutError:
            LOG.warning("ws join timeout; retry in %ds", backoff)
            await asyncio.sleep(backoff)


def enqueue_outbound(payload: dict) -> None:
    """Thread-safe push from the stdio thread onto the WS event loop."""
    if _outbound_queue is None or _outbound_loop is None:
        LOG.warning("outbound called before WS loop ready; dropping payload")
        return
    _outbound_loop.call_soon_threadsafe(_outbound_queue.put_nowait, payload)


# --- MCP stdio handler -----------------------------------------------------


def handle_mcp(msg: dict) -> None:
    method = msg.get("method", "")
    req_id = msg.get("id")
    params = msg.get("params", {}) or {}

    LOG.info("claude → bridge: method=%s id=%s", method, req_id)

    if method == "initialize":
        respond(
            req_id,
            {
                "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                "capabilities": {
                    "tools": {},
                    "experimental": {
                        # https://code.claude.com/docs/en/channels-reference
                        "claude/channel": {},
                    },
                },
                "serverInfo": {"name": "esr-bridge", "version": "2.0.0"},
                "instructions": (
                    'Messages from this channel arrive as <channel source="esr-bridge" ...>. '
                    "Treat them as user input. Reply by calling the `reply` tool with "
                    "the message text."
                ),
            },
        )

    elif method == "notifications/initialized":
        pass

    elif method == "tools/list":
        respond(
            req_id,
            {
                "tools": [
                    {
                        "name": "reply",
                        "description": (
                            "Send a reply back through the esr-bridge channel. "
                            "Use this whenever you want to respond to a "
                            "<channel source=\"esr-bridge\"> message. MUST "
                            "include session_uris (list of target session "
                            "URIs from the inbound <channel> tag meta) and "
                            "text."
                        ),
                        "inputSchema": {
                            "type": "object",
                            "properties": {
                                "session_uris": {
                                    "type": "array",
                                    "items": {"type": "string"},
                                    "description": (
                                        "Target session URI(s). Multi-session "
                                        "replies are allowed in one call."
                                    ),
                                },
                                "text": {
                                    "type": "string",
                                    "description": "The message text to send back.",
                                },
                                "ref": {
                                    "type": "string",
                                    "description": (
                                        "Optional URI of the message being "
                                        "replied to (consistency check upstream)."
                                    ),
                                },
                                "attachments": {
                                    "type": "array",
                                    "description": (
                                        "Optional list of files/images to "
                                        "attach. Each: {type: 'image'|'file', "
                                        "local_path: '/abs/path', "
                                        "name: 'display.ext'}. The Feishu "
                                        "adapter uploads from local_path."
                                    ),
                                    "items": {
                                        "type": "object",
                                        "properties": {
                                            "type": {
                                                "type": "string",
                                                "enum": ["image", "file"],
                                            },
                                            "local_path": {"type": "string"},
                                            "name": {"type": "string"},
                                        },
                                        "required": ["type", "local_path", "name"],
                                    },
                                },
                            },
                            "required": ["session_uris", "text"],
                        },
                    }
                ]
            },
        )

    elif method == "tools/call" and params.get("name") == "reply":
        args = params.get("arguments", {}) or {}
        payload = {
            "text": args.get("text", ""),
            "session_uris": args.get("session_uris", []),
        }
        ref = args.get("ref")
        if ref:
            payload["ref"] = ref
        attachments = args.get("attachments")
        if attachments:
            payload["attachments"] = attachments

        enqueue_outbound(payload)
        respond(
            req_id,
            {"content": [{"type": "text", "text": "reply enqueued"}]},
        )

    elif req_id is not None:
        respond(
            req_id,
            {"error": {"code": -32601, "message": f"Method not found: {method}"}},
        )


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
        LOG.info("stdin EOF; bridge shutting down")
        # Best-effort: nudge the asyncio loop to exit so the process
        # doesn't linger past claude's lifetime.
        if _outbound_loop is not None:
            _outbound_loop.call_soon_threadsafe(_outbound_loop.stop)


async def main() -> None:
    setup_logging()
    LOG.info("v2 bridge starting; ws=%s agent=%s", WS_URL, AGENT_URI or "(unset)")

    # stdio is blocking — drive it from a daemon thread so the asyncio
    # loop owns the WS connection.
    threading.Thread(target=stdin_loop, daemon=True).start()

    await connect_loop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

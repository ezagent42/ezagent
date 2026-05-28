#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["websockets>=13"]
# ///
"""
Codex AgentBridge sidecar.

The sidecar has two long-lived links:

* Phoenix Channel: receives ``codex_turn`` pushes from ezagent and
  sends ``reply`` events back through AgentBridge.
* Codex app-server proxy: submits those pushes as ``turn/start`` JSON-RPC
  requests to the per-agent ``codex app-server`` shared with the TUI.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Any
from urllib.parse import urlencode, urlparse, urlunparse

import websockets

LOG = logging.getLogger("ezagent_codex_bridge")


def float_env(name: str, default: float) -> float:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


WS_URL = os.environ.get("EZAGENT_BRIDGE_WS_URL", "ws://127.0.0.1:10042/agent_bridge/websocket")
AGENT_URI = os.environ.get("EZAGENT_AGENT_URI", "")
AGENT_TOKEN = os.environ.get("EZAGENT_AGENT_TOKEN", "")
CODEX_SOCK = os.environ.get("EZAGENT_CODEX_APP_SERVER_SOCK", "")
THREAD_ID_FILE = os.environ.get("EZAGENT_CODEX_THREAD_ID_FILE", "")
CWD = os.environ.get("EZAGENT_CODEX_CWD", os.getcwd())
CODEX_BIN = os.environ.get("EZAGENT_CODEX_BIN", "codex")
MODEL = os.environ.get("EZAGENT_CODEX_MODEL", "")
APPROVAL_POLICY = os.environ.get("EZAGENT_CODEX_APPROVAL_POLICY", "")
SANDBOX = os.environ.get("EZAGENT_CODEX_SANDBOX", "")
RPC_TIMEOUT = float_env("EZAGENT_CODEX_RPC_TIMEOUT", 20.0)


def setup_logging() -> None:
    home = os.path.expanduser(os.environ.get("EZAGENT_HOME", "~/.ezagent"))
    profile = os.environ.get("EZAGENT_PROFILE", "default")
    log_dir = os.path.join(home, profile, "logs")
    os.makedirs(log_dir, exist_ok=True)

    slug = AGENT_URI.replace("://", "-").replace("/", "_") or "anon"
    log_path = os.path.join(log_dir, f"codex-bridge-{slug}.log")

    handler = logging.FileHandler(log_path, mode="a", encoding="utf-8")
    handler.setFormatter(
        logging.Formatter(f"[ezagent_codex_bridge {slug}] %(asctime)s %(levelname)s %(message)s")
    )
    stream = logging.StreamHandler()
    stream.setFormatter(logging.Formatter("[ezagent_codex_bridge] %(levelname)s %(message)s"))

    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.handlers = [handler, stream]

    LOG.info("bridge log: %s", log_path)


def ws_url_with_params() -> str:
    if not AGENT_URI or not AGENT_TOKEN:
        raise SystemExit("EZAGENT_AGENT_URI and EZAGENT_AGENT_TOKEN are required")

    parsed = urlparse(WS_URL)
    query = urlencode({"token": AGENT_TOKEN, "agent_uri": AGENT_URI, "vsn": "2.0.0"})
    return urlunparse(parsed._replace(query=query))


def bridge_topic() -> str:
    explicit = os.environ.get("EZAGENT_BRIDGE_TOPIC", "")
    if explicit:
        return explicit
    return f"agent_bridge:codex:{AGENT_URI}"


def read_thread_id_file() -> str | None:
    if not THREAD_ID_FILE:
        return None
    try:
        with open(THREAD_ID_FILE, "r", encoding="utf-8") as f:
            thread_id = f.read().strip()
            return thread_id or None
    except FileNotFoundError:
        return None


def write_thread_id_file(thread_id: str) -> None:
    if not THREAD_ID_FILE:
        return
    dir_name = os.path.dirname(THREAD_ID_FILE)
    if dir_name:
        os.makedirs(dir_name, exist_ok=True)
    tmp_path = f"{THREAD_ID_FILE}.tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(thread_id)
        f.write("\n")
    os.replace(tmp_path, THREAD_ID_FILE)
    LOG.info("wrote codex thread id file: %s", THREAD_ID_FILE)


class CodexClient:
    def __init__(self) -> None:
        self.proc: asyncio.subprocess.Process | None = None
        self.next_id = 0
        self.pending: dict[int, asyncio.Future] = {}
        self.thread_id: str | None = None
        self.active_turns: dict[str, dict[str, Any]] = {}
        self.notifications: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.turn_lock = asyncio.Lock()

    async def start(self) -> None:
        if not CODEX_SOCK:
            raise RuntimeError("EZAGENT_CODEX_APP_SERVER_SOCK is required")

        LOG.info("starting codex app-server proxy; sock=%s cwd=%s", CODEX_SOCK, CWD)
        self.proc = await asyncio.create_subprocess_exec(
            CODEX_BIN,
            "app-server",
            "proxy",
            "--sock",
            CODEX_SOCK,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=CWD,
        )
        asyncio.create_task(self._read_stdout())
        asyncio.create_task(self._read_stderr())
        await self.call(
            "initialize",
            {
                "clientInfo": {"name": "ezagent-codex-bridge", "version": "0.1.0"},
                "capabilities": {},
            },
        )
        await self.notify("initialized", {})

    async def ensure_started(self) -> None:
        if self.proc is None or self.proc.returncode is not None:
            await self.start()

    async def ensure_thread(self) -> str:
        await self.ensure_started()
        if self.thread_id:
            return self.thread_id

        persisted_thread_id = read_thread_id_file()
        if persisted_thread_id:
            try:
                LOG.info("resuming persisted codex thread: %s", persisted_thread_id)
                params = self.thread_options()
                params["threadId"] = persisted_thread_id
                result = await self.call("thread/resume", params)
                thread = result.get("thread") or {}
                self.thread_id = thread.get("id") or persisted_thread_id
                write_thread_id_file(self.thread_id)
                LOG.info("codex thread ready: %s", self.thread_id)
                return self.thread_id
            except Exception:
                LOG.exception("failed to resume persisted codex thread %s", persisted_thread_id)

        LOG.info("starting new codex thread; cwd=%s", CWD)
        params = self.thread_options()
        params["sessionStartSource"] = "startup"
        params["ephemeral"] = False
        result = await self.call("thread/start", params)
        thread = result.get("thread") or {}
        thread_id = thread.get("id")
        if not thread_id:
            raise RuntimeError(f"thread/start did not return thread.id: {result!r}")

        self.thread_id = thread_id
        write_thread_id_file(thread_id)
        LOG.info("codex thread ready: %s", thread_id)
        return thread_id

    def thread_options(self) -> dict[str, Any]:
        params: dict[str, Any] = {
            "cwd": CWD,
        }
        if MODEL:
            params["model"] = MODEL
        if APPROVAL_POLICY:
            params["approvalPolicy"] = APPROVAL_POLICY
        if SANDBOX:
            params["sandbox"] = SANDBOX
        return params

    async def submit_turn(self, payload: dict[str, Any]) -> dict[str, Any]:
        async with self.turn_lock:
            thread_id = await self.ensure_thread()
            content = str(payload.get("content") or "")
            meta = payload.get("meta") or {}
            session_uri = payload.get("session_uri") or meta.get("session")

            result = await self.call(
                "turn/start",
                {
                    "threadId": thread_id,
                    "cwd": CWD,
                    "input": [{"type": "text", "text": content}],
                },
            )
            turn = result.get("turn") or {}
            turn_id = turn.get("id")
            if not turn_id:
                raise RuntimeError(f"turn/start did not return turn.id: {result!r}")

            state = {
                "text": [],
                "session_uri": session_uri,
                "message_id": payload.get("message_id") or meta.get("message_id"),
            }
            self.active_turns[turn_id] = state
            return await self._wait_for_turn(turn_id)

    async def _wait_for_turn(self, turn_id: str) -> dict[str, Any]:
        while True:
            notification = await self.notifications.get()
            method = notification.get("method")
            params = notification.get("params") or {}

            if method == "item/agentMessage/delta" and params.get("turnId") == turn_id:
                self.active_turns[turn_id]["text"].append(params.get("delta") or "")
                continue

            if method == "turn/completed":
                turn = params.get("turn") or {}
                completed_turn_id = turn.get("id")
                if completed_turn_id != turn_id:
                    continue

                state = self.active_turns.pop(turn_id, {})
                text = "".join(state.get("text") or []).strip()
                if not text:
                    text = extract_agent_message_text(turn).strip()
                return {
                    "text": text,
                    "session_uris": [state["session_uri"]] if state.get("session_uri") else [],
                }

    async def call(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        await self.ensure_started()
        self.next_id += 1
        req_id = self.next_id
        loop = asyncio.get_running_loop()
        fut = loop.create_future()
        self.pending[req_id] = fut
        await self._write({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params})
        try:
            return await asyncio.wait_for(fut, timeout=RPC_TIMEOUT)
        except asyncio.TimeoutError as exc:
            self.pending.pop(req_id, None)
            raise TimeoutError(f"codex RPC {method} timed out after {RPC_TIMEOUT}s") from exc

    async def notify(self, method: str, params: dict[str, Any]) -> None:
        await self._write({"jsonrpc": "2.0", "method": method, "params": params})

    async def _write(self, frame: dict[str, Any]) -> None:
        if self.proc is None or self.proc.stdin is None:
            raise RuntimeError("codex proxy stdin is not available")
        self.proc.stdin.write(json.dumps(frame).encode("utf-8") + b"\n")
        await self.proc.stdin.drain()

    async def _read_stdout(self) -> None:
        assert self.proc is not None and self.proc.stdout is not None
        while True:
            raw = await self.proc.stdout.readline()
            if not raw:
                self._fail_pending(RuntimeError("codex proxy stdout closed"))
                return
            try:
                msg = json.loads(raw.decode("utf-8"))
            except json.JSONDecodeError:
                LOG.warning("non-JSON codex proxy stdout: %r", raw[:200])
                continue

            if "id" in msg and ("result" in msg or "error" in msg):
                fut = self.pending.pop(msg["id"], None)
                if fut is None:
                    continue
                if fut.done():
                    continue
                if "error" in msg:
                    fut.set_exception(RuntimeError(msg["error"]))
                else:
                    fut.set_result(msg.get("result") or {})
                continue

            if "id" in msg and "method" in msg:
                await self._handle_server_request(msg)
                continue

            if "method" in msg:
                await self.notifications.put(msg)

    def _fail_pending(self, exc: Exception) -> None:
        for fut in self.pending.values():
            if not fut.done():
                fut.set_exception(exc)
        self.pending.clear()

    async def _read_stderr(self) -> None:
        assert self.proc is not None and self.proc.stderr is not None
        while True:
            raw = await self.proc.stderr.readline()
            if not raw:
                return
            LOG.info("codex proxy stderr: %s", raw.decode("utf-8", errors="replace").rstrip())

    async def _handle_server_request(self, msg: dict[str, Any]) -> None:
        req_id = msg.get("id")
        method = msg.get("method")
        if method in {
            "item/commandExecution/requestApproval",
            "execCommandApproval",
        }:
            result = {"decision": "decline"}
        elif method in {
            "item/fileChange/requestApproval",
            "applyPatchApproval",
        }:
            result = {"decision": "decline"}
        else:
            await self._write(
                {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"Unsupported request: {method}"},
                }
            )
            return

        await self._write({"jsonrpc": "2.0", "id": req_id, "result": result})


def extract_agent_message_text(turn: dict[str, Any]) -> str:
    items = turn.get("items") or []
    texts = [
        item.get("text") or ""
        for item in items
        if isinstance(item, dict) and item.get("type") == "agentMessage"
    ]
    return "".join(texts)


async def heartbeat_loop(ws, ref_counter: list[int]) -> None:
    while True:
        await asyncio.sleep(30)
        ref_counter[0] += 1
        await ws.send(json.dumps([None, str(ref_counter[0]), "phoenix", "heartbeat", {}]))


async def send_reply(ws, join_ref: str, ref_counter: list[int], payload: dict[str, Any]) -> None:
    ref_counter[0] += 1
    frame = [join_ref, str(ref_counter[0]), bridge_topic(), "reply", payload]
    await ws.send(json.dumps(frame))


async def handle_codex_turn(
    client: CodexClient,
    ws,
    join_ref: str,
    ref_counter: list[int],
    payload: dict[str, Any],
) -> None:
    try:
        reply = await client.submit_turn(payload or {})
        if reply.get("text") and reply.get("session_uris"):
            await send_reply(ws, join_ref, ref_counter, reply)
        else:
            LOG.warning("not sending empty or unroutable codex reply: %r", reply)
    except Exception:
        LOG.exception("codex turn failed")


async def inbound_loop(ws, client: CodexClient, join_ref: str, ref_counter: list[int]) -> None:
    async for raw in ws:
        try:
            frame = json.loads(raw)
        except json.JSONDecodeError:
            LOG.warning("non-JSON WS frame: %r", raw[:120])
            continue
        if not isinstance(frame, list) or len(frame) < 5:
            continue
        _join_ref, _ref, _topic, event, payload = frame[:5]
        if event == "codex_turn":
            asyncio.create_task(handle_codex_turn(client, ws, join_ref, ref_counter, payload or {}))


async def connect_loop() -> None:
    url = ws_url_with_params()
    client = CodexClient()
    backoff = 2

    while True:
        try:
            await client.ensure_thread()
            LOG.info("connecting %s", url)
            async with websockets.connect(url, max_size=None) as ws:
                topic = bridge_topic()
                ref_counter = [1]
                join_ref = "1"
                join_payload = {
                    "codex_info": {
                        "app_server_socket": CODEX_SOCK,
                        "cwd": CWD,
                    },
                    "tools": ["reply"],
                }
                await ws.send(json.dumps([join_ref, "1", topic, "phx_join", join_payload]))

                reply_raw = await asyncio.wait_for(ws.recv(), timeout=10)
                reply = json.loads(reply_raw)
                status = (reply[4] or {}).get("status") if isinstance(reply, list) and len(reply) >= 5 else None
                if status != "ok":
                    LOG.error("join rejected: %r", reply)
                    await asyncio.sleep(backoff)
                    continue

                LOG.info("join ok: %s", topic)
                backoff = 2
                await asyncio.gather(
                    inbound_loop(ws, client, join_ref, ref_counter),
                    heartbeat_loop(ws, ref_counter),
                )
        except (OSError, websockets.exceptions.WebSocketException, asyncio.TimeoutError):
            LOG.exception("bridge connection failed; retry in %ds", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)
        except Exception:
            LOG.exception("codex bridge failed; retry in %ds", backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)


async def main() -> None:
    setup_logging()
    LOG.info(
        "starting codex bridge; ws=%s agent=%s sock=%s cwd=%s thread_id_file=%s",
        WS_URL,
        AGENT_URI,
        CODEX_SOCK,
        CWD,
        THREAD_ID_FILE,
    )
    await connect_loop()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass

#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["claude-agent-sdk>=0.2.94,<0.3"]
# ///
"""
Claude Code SDK worker for cc-headless agents.

Protocol: stdin/stdout JSON lines.

Request:
    {"id": "req-1", "op": "query", "text": "...", "session_id": "..."}

Response:
    {"id": "req-1", "ok": true, "content": "...", "usage": {...}}
    {"id": "req-1", "ok": false, "error": "..."}
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import traceback
from dataclasses import asdict, is_dataclass
from typing import Any

try:
    from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
except ImportError:  # pragma: no cover - lets the pure helpers below be
    # imported for unit tests on hosts without the SDK installed. The SDK is
    # required at runtime (Worker.start), where its absence surfaces loudly.
    ClaudeAgentOptions = None  # type: ignore[assignment,misc]
    ClaudeSDKClient = None  # type: ignore[assignment,misc]

try:
    from claude_agent_sdk.types import (
        AssistantMessage,
        ResultMessage,
        SdkPluginConfig,
        TextBlock,
    )
except ImportError:  # pragma: no cover - defensive across SDK releases
    AssistantMessage = object  # type: ignore[assignment,misc]
    ResultMessage = object  # type: ignore[assignment,misc]
    TextBlock = object  # type: ignore[assignment,misc]
    SdkPluginConfig = dict  # type: ignore[assignment,misc]


def env_json(name: str, default: Any) -> Any:
    raw = os.environ.get(name, "")
    if not raw:
        return default
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return default


def compact_error(exc: BaseException) -> str:
    return f"{exc.__class__.__name__}: {exc}"


def _server_names_from_mcp_file(path: str) -> list[str]:
    """Server names declared in a Claude-Code `.mcp.json` (`{"mcpServers": {...}}`)."""
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []
    servers = data.get("mcpServers") if isinstance(data, dict) else None
    if isinstance(servers, dict):
        return [str(name) for name in servers]
    return []


def resolve_mcp_config(
    config_dir: str,
    explicit_mcp: Any,
    existing_allowed: Any,
) -> tuple[Any, list[str]]:
    """Resolve the MCP servers + auto-allowed tools for a headless SDK session.

    Route B (per Claude Agent SDK >=0.2.94, where
    ``ClaudeAgentOptions.mcp_servers`` accepts ``dict | str | Path``):

    - If the elixir side passed an explicit ``mcp_servers`` value
      (``EZAGENT_CC_SDK_MCP_SERVERS``), honor it verbatim.
    - Otherwise load the materialized per-agent ``<config_dir>/.mcp.json`` —
      the SAME file the PTY/`cc` flavor points `claude` at via
      ``--mcp-config``. Passed as a path string so the SDK/CLI reads it
      directly. ``strict_mcp_config`` stays ``True``: only these servers are
      used, nothing leaks in from ambient project/user config.

    Because a headless sidecar cannot answer an interactive permission
    prompt, every loaded MCP server is added to ``allowed_tools`` at the
    server granularity (``mcp__<server>``) so its tools auto-execute under
    ``permission_mode="default"`` (SDK: an empty ``allowed_tools`` does not
    deny tools, it makes them *prompt* — fatal for headless). Built-in tools
    (Bash/Write/…) keep their normal permission behavior.

    Returns ``(mcp_servers, allowed_tools)``; ``mcp_servers`` is ``None`` when
    nothing is configured.
    """
    allowed: list[str] = [str(t) for t in (existing_allowed or [])]
    mcp_servers: Any = None
    names: list[str] = []

    if explicit_mcp:
        mcp_servers = explicit_mcp
        if isinstance(explicit_mcp, dict):
            names = [str(name) for name in explicit_mcp]
    elif config_dir:
        candidate = os.path.join(config_dir, ".mcp.json")
        if os.path.isfile(candidate):
            mcp_servers = candidate
            names = _server_names_from_mcp_file(candidate)

    for name in names:
        tool = f"mcp__{name}"
        if tool not in allowed:
            allowed.append(tool)

    return mcp_servers, allowed


def plain(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    if is_dataclass(value):
        return plain(asdict(value))
    data: dict[str, Any] = {}
    for key in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
        if hasattr(value, key):
            data[key] = plain(getattr(value, key))
    return data or repr(value)


def text_from_block(block: Any) -> str | None:
    if isinstance(block, TextBlock):
        return getattr(block, "text", None)
    text = getattr(block, "text", None)
    if isinstance(text, str):
        return text
    if isinstance(block, dict):
        text = block.get("text")
        if isinstance(text, str):
            return text
    return None


class Worker:
    def __init__(self) -> None:
        self.client: ClaudeSDKClient | None = None
        self.lock = asyncio.Lock()
        self.default_session_id = os.environ.get("EZAGENT_CC_SDK_SESSION_ID", "default")

    async def start(self) -> None:
        cwd = os.environ.get("EZAGENT_CC_SDK_CWD", os.getcwd())
        sdk_env = env_json("EZAGENT_CC_SDK_ENV", {})
        if not isinstance(sdk_env, dict):
            sdk_env = {}

        config_dir = os.environ.get("EZAGENT_CC_SDK_CONFIG_DIR", "")
        if config_dir:
            sdk_env["CLAUDE_CONFIG_DIR"] = config_dir
            os.environ["CLAUDE_CONFIG_DIR"] = config_dir

        # Route B (#1323): load the materialized per-agent `.mcp.json` from the
        # agent's config dir (same MCP surface the PTY/`cc` flavor uses) and
        # auto-allow its servers so a headless agent's tools are actually
        # callable. `strict_mcp_config` stays True — only these servers are used.
        mcp_servers, allowed_tools = resolve_mcp_config(
            config_dir,
            env_json("EZAGENT_CC_SDK_MCP_SERVERS", None),
            env_json("EZAGENT_CC_SDK_ALLOWED_TOOLS", []),
        )

        options = ClaudeAgentOptions(
            cwd=cwd,
            setting_sources=[],
            strict_mcp_config=True,
            env={str(k): str(v) for k, v in sdk_env.items()},
            permission_mode=os.environ.get("EZAGENT_CC_SDK_PERMISSION_MODE", "default"),
            model=os.environ.get("EZAGENT_CC_SDK_MODEL") or None,
            effort=os.environ.get("EZAGENT_CC_SDK_EFFORT") or os.environ.get("CLAUDE_EFFORT") or None,
            cli_path=os.environ.get("EZAGENT_CC_SDK_CLI_PATH") or None,
            system_prompt=os.environ.get("EZAGENT_CC_SDK_SYSTEM_PROMPT") or None,
        )

        if mcp_servers:
            options.mcp_servers = mcp_servers

        if allowed_tools:
            options.allowed_tools = list(allowed_tools)

        disallowed_tools = env_json("EZAGENT_CC_SDK_DISALLOWED_TOOLS", [])
        if disallowed_tools:
            options.disallowed_tools = list(disallowed_tools)

        plugins = env_json("EZAGENT_CC_SDK_PLUGINS", [])
        if plugins:
            options.plugins = [
                SdkPluginConfig(type=p["type"], path=p["path"])  # type: ignore[index,call-arg]
                if isinstance(p, dict) else p
                for p in plugins
            ]

        self.client = ClaudeSDKClient(options)
        await self.client.connect()

    async def close(self) -> None:
        if self.client is not None:
            await self.client.disconnect()
            self.client = None

    async def query(self, text: str, session_id: str | None) -> dict[str, Any]:
        if self.client is None:
            await self.start()

        assert self.client is not None
        sid = session_id or self.default_session_id
        parts: list[str] = []
        usage: dict[str, Any] = {}

        async with self.lock:
            await self.client.query(text, session_id=sid)
            async for msg in self.client.receive_response():
                if isinstance(msg, AssistantMessage):
                    for block in getattr(msg, "content", None) or []:
                        block_text = text_from_block(block)
                        if block_text:
                            parts.append(block_text)

                    msg_usage = getattr(msg, "usage", None)
                    if msg_usage is not None:
                        usage = plain(msg_usage)

                elif isinstance(msg, ResultMessage):
                    msg_usage = getattr(msg, "usage", None)
                    if msg_usage is not None:
                        usage = plain(msg_usage)

                else:
                    content = getattr(msg, "content", None)
                    if isinstance(content, str):
                        parts.append(content)
                    elif isinstance(content, list):
                        for block in content:
                            block_text = text_from_block(block)
                            if block_text:
                                parts.append(block_text)

        return {"content": "".join(parts), "usage": usage, "session_id": sid}


async def handle(worker: Worker, frame: dict[str, Any]) -> dict[str, Any]:
    req_id = frame.get("id")
    op = frame.get("op")

    if not isinstance(req_id, str) or not req_id:
        return {"id": req_id, "ok": False, "error": "missing request id"}

    if op == "query":
        text = frame.get("text")
        if not isinstance(text, str):
            return {"id": req_id, "ok": False, "error": "query.text must be a string"}
        result = await worker.query(text, frame.get("session_id"))
        return {"id": req_id, "ok": True, **result}

    if op == "shutdown":
        await worker.close()
        return {"id": req_id, "ok": True}

    return {"id": req_id, "ok": False, "error": f"unknown op: {op!r}"}


async def main() -> int:
    worker = Worker()

    while True:
        line = await asyncio.to_thread(sys.stdin.readline)
        if line == "":
            break
        line = line.strip()
        if not line:
            continue

        try:
            frame = json.loads(line)
            if not isinstance(frame, dict):
                raise ValueError("frame must be a JSON object")
            response = await handle(worker, frame)
        except Exception as exc:  # noqa: BLE001 - top-level protocol guard
            traceback.print_exc(file=sys.stderr)
            response = {"id": None, "ok": False, "error": compact_error(exc)}

        print(json.dumps(response, ensure_ascii=False), flush=True)

    await worker.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))

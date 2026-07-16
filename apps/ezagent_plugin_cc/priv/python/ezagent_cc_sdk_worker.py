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

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient

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

        allowed_tools = env_json("EZAGENT_CC_SDK_ALLOWED_TOOLS", [])
        if allowed_tools:
            options.allowed_tools = list(allowed_tools)

        disallowed_tools = env_json("EZAGENT_CC_SDK_DISALLOWED_TOOLS", [])
        if disallowed_tools:
            options.disallowed_tools = list(disallowed_tools)

        mcp_servers = env_json("EZAGENT_CC_SDK_MCP_SERVERS", None)
        if mcp_servers:
            options.mcp_servers = mcp_servers

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

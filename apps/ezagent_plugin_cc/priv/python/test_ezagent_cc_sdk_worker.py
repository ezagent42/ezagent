#!/usr/bin/env python3
"""Unit tests for the cc-headless SDK worker's MCP resolution (route B).

Runs without the Claude Agent SDK installed — the worker guards its
`claude_agent_sdk` import so these pure helpers stay importable. Run with:

    uv run --no-project python -m unittest \
        apps/ezagent_plugin_cc/priv/python/test_ezagent_cc_sdk_worker.py
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import ezagent_cc_sdk_worker as worker  # noqa: E402


def _write_mcp_json(config_dir: str, servers: dict) -> str:
    path = os.path.join(config_dir, ".mcp.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump({"mcpServers": servers}, fh)
    return path


BRIDGE_SERVERS = {
    "esr-bridge": {"command": "uv", "args": ["run", "--script", "bridge.py"]},
    "esr-orchestrator": {"command": "uv", "args": ["run", "--script", "orch.py"]},
}


class ResolveMcpConfigTest(unittest.TestCase):
    def test_loads_materialized_mcp_json_as_path(self):
        """A config dir with `.mcp.json` -> mcp_servers is that file path."""
        with tempfile.TemporaryDirectory() as config_dir:
            path = _write_mcp_json(config_dir, BRIDGE_SERVERS)
            mcp_servers, allowed = worker.resolve_mcp_config(config_dir, None, [])
            self.assertEqual(mcp_servers, path)
            # Each server is auto-allowed at server granularity so the
            # headless agent's tools are callable without a prompt.
            self.assertIn("mcp__esr-bridge", allowed)
            self.assertIn("mcp__esr-orchestrator", allowed)

    def test_explicit_mcp_dict_takes_precedence_and_is_allowed(self):
        with tempfile.TemporaryDirectory() as config_dir:
            _write_mcp_json(config_dir, BRIDGE_SERVERS)
            explicit = {"custom": {"type": "stdio", "command": "x"}}
            mcp_servers, allowed = worker.resolve_mcp_config(config_dir, explicit, [])
            self.assertEqual(mcp_servers, explicit)
            self.assertIn("mcp__custom", allowed)
            # The on-disk file is NOT consulted when explicit servers win.
            self.assertNotIn("mcp__esr-bridge", allowed)

    def test_no_config_dir_and_no_file_yields_none(self):
        mcp_servers, allowed = worker.resolve_mcp_config("", None, [])
        self.assertIsNone(mcp_servers)
        self.assertEqual(allowed, [])

    def test_config_dir_without_mcp_json_yields_none(self):
        with tempfile.TemporaryDirectory() as config_dir:
            mcp_servers, allowed = worker.resolve_mcp_config(config_dir, None, [])
            self.assertIsNone(mcp_servers)
            self.assertEqual(allowed, [])

    def test_existing_allowed_preserved_without_duplicates(self):
        with tempfile.TemporaryDirectory() as config_dir:
            _write_mcp_json(config_dir, {"esr-bridge": {"command": "uv"}})
            _mcp, allowed = worker.resolve_mcp_config(
                config_dir, None, ["Bash", "mcp__esr-bridge"]
            )
            self.assertEqual(allowed.count("mcp__esr-bridge"), 1)
            self.assertIn("Bash", allowed)

    def test_malformed_mcp_json_is_tolerated(self):
        with tempfile.TemporaryDirectory() as config_dir:
            with open(os.path.join(config_dir, ".mcp.json"), "w") as fh:
                fh.write("{ not json")
            mcp_servers, allowed = worker.resolve_mcp_config(config_dir, None, [])
            # Path is still returned (SDK surfaces the parse error loudly);
            # no server names are derived from an unparseable file.
            self.assertTrue(mcp_servers.endswith(".mcp.json"))
            self.assertEqual(allowed, [])


if __name__ == "__main__":
    unittest.main()

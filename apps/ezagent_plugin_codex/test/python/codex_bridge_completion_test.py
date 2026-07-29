#!/usr/bin/env python3
"""Regression tests for choosing the authoritative Codex completion text."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


def load_bridge_module():
    path = Path(__file__).resolve().parents[2] / "priv/python/ezagent_codex_bridge.py"
    spec = importlib.util.spec_from_file_location("ezagent_codex_bridge", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CompletionTextTest(unittest.TestCase):
    def test_completed_agent_message_overrides_streamed_deltas(self):
        bridge = load_bridge_module()
        turn = {
            "items": [
                {"type": "agentMessage", "text": '{"complete":true}'},
            ]
        }

        self.assertEqual(
            bridge.canonical_completion_text(['{"complete":false}'], turn),
            '{"complete":true}',
        )


if __name__ == "__main__":
    unittest.main()

# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Minimal `receive`-method fixture for the AgentLifecycle suite.

Mirrors the operator-supplied py-agent script shape (py-agent spec §1):
imports the shipped ezagent_python lib via EZAGENT_PYTHON_LIB_DIR and
registers a single `receive` handler.
"""

from __future__ import annotations

import os
import sys

# py-agent operator scripts MUST carry this preamble (spec §6.3): the
# Domain.Python launcher sets EZAGENT_PYTHON_LIB_DIR so the bare
# `from ezagent_python import ...` resolves.
sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])

from ezagent_python import method, run  # noqa: E402


@method("receive")
def receive(params):  # {"text", "from", "session"}
    """Echo the inbound text back as the reply payload."""
    return {"text": params.get("text", "")}


if __name__ == "__main__":
    run()

# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Operator-script fixture for the py-agent suite: echoes inbound text."""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])

from ezagent_python import method, run  # noqa: E402


@method("receive")
def receive(params):  # {"text", "from", "session"}
    return {"text": params.get("text", "")}


if __name__ == "__main__":
    run()

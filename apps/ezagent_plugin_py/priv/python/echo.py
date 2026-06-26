# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""The echo operator script (py-agent P2).

This is the FIRST shipped operator script for the `py` flavor — the trivial
echo behavior that the deleted echo plugin used to hard-code in Elixir, now
expressed as an operator-supplied python script. It is installed into the
`py_default` agent's per-agent `config_dir` at boot (see
`EzagentPluginPy.Application.after_boot/0`) and is the reference operator
script for the py flavor.

`@method("receive")` returns the inbound text verbatim under a `"text"` key —
the py-agent Behavior dispatches that back into the originating session as the
agent's reply (echo-equivalence).
"""

from __future__ import annotations

import os
import sys

sys.path.insert(0, os.environ["EZAGENT_PYTHON_LIB_DIR"])

from ezagent_python import method, run  # noqa: E402


@method("receive")
def receive(params):  # params: {"text", "from", "session"}
    return {"text": params.get("text", "")}


if __name__ == "__main__":
    run()

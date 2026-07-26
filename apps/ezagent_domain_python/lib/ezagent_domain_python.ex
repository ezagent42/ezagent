defmodule EzagentDomainPython do
  @moduledoc """
  Domain.Python — Tier-2 runtime for ezagent-launched Python
  subprocesses.

  Per SPEC `docs/superpowers/specs/2026-05-23-domain-python.md`
  (merged #254). This app owns the OS-process lifecycle for any
  Python subprocess that ezagent itself launches via uv: one
  `Ezagent.Domain.Python.Server` GenServer per managed handle,
  parented by `EzagentDomainPython.Supervisor` and self-registered
  in the unified `Ezagent.Runtime.SidecarRegistry` (`:via` keyed by
  the canonical handle — V5 pid-closure A1b; the private
  `EzagentDomainPython.Registry` is retired).

  ## What Domain.Python is

  A unified runtime for Python subprocesses ezagent itself launches:

    * Future Python-implemented Agent Kinds whose `Behavior.Session`
      invoke delegates to `Ezagent.Domain.Python.call/4`.
    * Future Behavior `:invoke` / Template `:instantiate`
      implementations written in Python.
    * Future Python plugins shipping a PEP-723 single-file script
      or a `pyproject.toml` project.

  ## What Domain.Python is NOT

    * NOT the cc / MCP-bridge path — `apps/ezagent_plugin_cc/python/
      ezagent_mcp_bridge.py` is spawned by claude (under Domain.Pty)
      as an MCP server, not by ezagent. Per Allen 2026-05-22, MCP
      bridges stay on Domain.Pty.
    * NOT a PTY — uses `:exec.run/2` WITHOUT `:pty`; line-buffered
      pipes only. Use `Ezagent.Domain.Pty` for terminal-style child
      processes.
    * NOT a sandbox / capability boundary — CapBAC is enforced at the
      dispatch boundary, not at the OS-process boundary.

  ## Public surface

  Use `Ezagent.Domain.Python` (the facade alias):

      Ezagent.Domain.Python.start_subprocess/1
      Ezagent.Domain.Python.call/4
      Ezagent.Domain.Python.stop/1
      Ezagent.Domain.Python.alive?/1

  Plus `Ezagent.Domain.Python.Spec` for the input struct and
  `Ezagent.Domain.Python.handle_key/1` for the canonicalization
  rules (SPEC §1.2.1).

  ## Wire — LSP-framed JSON-RPC 2.0

  Domain.Python keeps the Phase-6 LSP framing
  (`Content-Length: N\\r\\n\\r\\n<body>`) the Python plugin host
  was originally specced with — binary-clean for embedded newlines,
  base64 image data, arbitrary chat reply strings. See
  `EzagentDomainPython.JsonRpc` for the encoder/decoder + the four
  envelope shapes (request / response-ok / response-error /
  notification).
  """
end

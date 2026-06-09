defmodule Ezagent.Entity.NpAgent do
  @moduledoc """
  NpAgent Kind — an agent that evaluates numpy / sympy expressions in a
  per-agent Python subprocess managed by `Ezagent.Domain.Python`.

  ## URI scheme (SPEC v3 §3 + SPEC v2 §5.14)

  `entity://agent/<workspace>/np_<instance_name>` — flavor `np` prefix on
  the name segment distinguishes from `cc_*` / `curl_*` / `echo_*`.

  ## Slice shape

      %{
        # Python handle this Kind owns (1-to-1 per Kind instance).
        python_handle: URI.t(),

        # Last compute observed (for observability + slice snapshotting).
        last_input:   String.t() | nil,
        last_result:  term() | nil,
        last_error:   term() | nil
      }

  ## Persistence

  `:ephemeral` — the Python subprocess does the heavy lifting and is
  itself ephemeral.

  ## Per-agent (not shared) Python subprocess

  Each NpAgent Kind owns its OWN `Ezagent.Domain.Python.Server`
  identified by the agent URI as the Domain.Python handle. Mirrors
  the per-cc-agent `Ezagent.Domain.Pty.Server` ownership pattern.

  ## Phase 2-g r3 migration (2026-05-28)

  Adopts `use Ezagent.Kind, pattern: :entity, ...` per SPEC §2.3 +
  §3 composition patterns. Legacy `behaviors/0`, `persistence/0`,
  `type_name/0`, `supervisor/0` callbacks remain — `Kind.Server`
  still reads them — but the macro also runs OQ-2 / OQ-5
  compile-time checks (pattern compatibility + action collision).
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :np_agent,
    supervisor: EzagentPluginNp.InstanceSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.NpAgent)
  # PTY-phase-state-machine 2026-05-26 follow-up (b) codex HIGH-1
  # fix: Terminable attached so `lifecycle.terminate` dispatches reach
  # np-agents (Dead-Restart badge in LV).
  attach(Ezagent.Behavior.Terminable)

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  def behaviors, do: [Ezagent.Behavior.NpAgent, Ezagent.Behavior.Terminable]

  # Kind.Server still reads persistence/0; keep the legacy callback.
  def persistence, do: :ephemeral
end

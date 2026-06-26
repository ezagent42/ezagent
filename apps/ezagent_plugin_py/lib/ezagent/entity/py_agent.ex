defmodule Ezagent.Entity.PyAgent do
  @moduledoc """
  PyAgent Kind — a GENERAL script-driven agent backed by a per-agent Python
  subprocess (`Ezagent.Domain.Python`) running an OPERATOR-SUPPLIED script
  installed into the agent's per-agent `config_dir`.

  ## URI scheme (SPEC v3 §3)

  `entity://<workspace>/agent/py_<instance_name>` — the `py_` name-segment
  prefix is a convention only; flavor is stored attribute, never parsed from
  the URI (unify-uri-query).

  ## Per-agent (not shared) Python subprocess

  Each PyAgent Kind owns its OWN `Ezagent.Domain.Python.Server` keyed by the
  agent URI. Mirrors the per-NpAgent / per-cc-agent ownership pattern — keeps
  interpreter state scoped to the agent and prevents cross-agent message
  interleaving in the single-threaded python event loop.

  ## P1-only scaffolding (spec §2.2 Q3 / plan HIGH-3)

  own-Kind `Entity.PyAgent` is a defensible P1 simplification because the
  role-script channel (RF-5b) is not yet built. P4 retires this in favor of
  `native` + a `py` behavior layered per-instance via a role (the
  kanban-as-role precedent), with the subprocess self-healing in the
  behavior's `activate/2`.

  ## Persistence

  `:ephemeral` — the Python subprocess does the heavy lifting and is itself
  ephemeral.
  """

  use Ezagent.Kind,
    pattern: :entity,
    type_name: :py_agent,
    supervisor: EzagentPluginPy.InstanceSupervisor

  @behaviour Ezagent.Kind

  attach(Ezagent.Behavior.PyAgent)

  # Kind.Server still reads behaviors/0; keep the legacy callback.
  @doc false
  def behaviors, do: [Ezagent.Behavior.PyAgent]

  # Kind.Server still reads persistence/0; keep the legacy callback.
  @doc false
  def persistence, do: :ephemeral
end

defmodule Ezagent.Entity.NpAgent do
  @moduledoc """
  NpAgent Kind — an agent that evaluates numpy / sympy expressions in a
  per-agent Python subprocess managed by `Ezagent.Domain.Python`.

  ## URI scheme (SPEC v3 §3 + SPEC v2 §5.14)

  `entity://agent/<workspace>/np_<instance_name>` — flavor `np` prefix on
  the name segment distinguishes from `cc_*` / `curl_*` / `echo_*`.
  Spawned via the standard `entity://` SpawnRegistry dispatcher; the
  chat plugin's flavor resolver consults `Ezagent.AgentFlavorRegistry`
  to map `"np"` → this Kind module.

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
  itself ephemeral (no per-instance state worth persisting across
  phx restart). When the Kind is restarted the Template Class will
  re-start the Python subprocess on the next instantiate.

  ## Per-agent (not shared) Python subprocess

  Each NpAgent Kind owns its OWN `Ezagent.Domain.Python.Server`
  identified by the agent URI as the Domain.Python handle. The choice
  mirrors the per-cc-agent `Ezagent.Domain.Pty.Server` ownership
  pattern: keeps Python interpreter state (numpy globals, sympy
  caches, accidental mutable state) scoped to the agent, and prevents
  cross-agent message interleaving inside the single-threaded Python
  event loop (`ezagent_python.run/0` is single-threaded by design —
  see Domain.Python SPEC §6.2). A shared subprocess would serialize
  every NpAgent's compute call behind every other; a per-agent
  subprocess preserves the parallelism Allen expects when multiple
  np-agents are mentioned in a single workflow.
  """

  @behaviour Ezagent.Kind

  @impl Ezagent.Kind
  def type_name, do: :np_agent

  @impl Ezagent.Kind
  def behaviors, do: [Ezagent.Behavior.NpAgent]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  # V1 prevention (Allen 2026-05-21): NpAgent Kinds live under the
  # np plugin's own InstanceSupervisor. `Ezagent.Kind.spawn/2` reads
  # this.
  @impl Ezagent.Kind
  def supervisor, do: EzagentPluginNp.InstanceSupervisor
end

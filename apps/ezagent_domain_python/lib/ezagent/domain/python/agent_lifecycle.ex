defmodule Ezagent.Domain.Python.AgentLifecycle do
  @moduledoc """
  Shared Domain.Python *agent* lifecycle helpers — the subprocess-backed
  Behavior boilerplate every Python-flavor agent (np, py, …) needs, lifted
  out of the per-flavor Behavior so a second flavor reuses it instead of
  copy-pasting ~150 lines (py-agent spec §2.1 / round-2 MED-1).

  ## What this module owns

  - `ensure_alive/1` — idempotently (re)spawn the per-agent
    `Ezagent.Domain.Python` subprocess from a CALLER-BUILT `%Spec{}`. Built
    ON TOP of the real `Ezagent.Domain.Python.start_subprocess/1`
    (`python.ex`), NOT a new spawn API. If the subprocess is already alive
    for `spec.handle` it returns `:ok` without re-spawning.
  - `phase_from_signal/1` — map a `{:pty_phase, uri, phase, meta}` signal to
    its `:starting | :running | :dead` phase atom (or `:ignore`).

  (Pre-H1 this module also owned `subscribe_phase/1` + `phase_topic/1` —
  the Kind-side `pty:phase:` PubSub subscription. V5 use-side H1
  (delete-holes #200) DELETED them: the phase now reaches the behavior
  point-to-point via `EzagentActor.Signal.signal/2`, so no Kind subscribes
  to the shared topic anymore.)

  ## What this module deliberately does NOT own

  It is a **parametrizing** extraction, not a behaviour→template coupling.
  It has ZERO reference to any flavor's Template module — the caller builds
  its own `%Spec{}` (script_path, command, env, timeouts) and passes it in.
  This breaks the behavior→template back-reference by construction: a
  Behavior consuming this helper never names a Template module. (The np
  Behavior keeps its own private copy in P1 to avoid risking its tested
  suite; np re-homes onto this helper in P4 — py-agent plan Task 1.1.)

  Lives in `ezagent_domain_python` (the runtime tier) so any plugin tier
  Behavior can depend on it without a sibling-plugin dependency.
  """

  require Logger

  alias Ezagent.Domain.Python
  alias Ezagent.Domain.Python.Spec

  @typedoc "Python subprocess phase."
  @type phase :: :starting | :running | :dead

  @doc """
  Idempotently ensure the Domain.Python subprocess for `spec.handle` is
  alive.

  - already alive → `:ok` (no double-start)
  - not alive → `Ezagent.Domain.Python.start_subprocess(spec)` and map the
    result to `:ok` / `{:error, reason}`.

  The caller owns the `%Spec{}` entirely (script_path, command, env,
  timeouts) — this helper adds only the alive-check + start dance + uniform
  logging, so np and py share the self-heal logic without sharing a Spec.
  """
  @spec ensure_alive(Spec.t()) :: :ok | {:error, term()}
  def ensure_alive(%Spec{handle: handle} = spec) do
    if Python.alive?(handle) do
      :ok
    else
      case Python.start_subprocess(spec) do
        {:ok, _pid} ->
          :ok

        {:error, reason} = err ->
          Logger.warning(
            "Ezagent.Domain.Python.AgentLifecycle.ensure_alive: " <>
              "start_subprocess failed for #{inspect(handle)}: #{inspect(reason)}"
          )

          err
      end
    end
  end

  @doc """
  Map a Domain.Python phase signal to its phase atom.

  Returns `{:ok, agent_uri, phase}` for a well-formed
  `{:pty_phase, %URI{}, phase, meta}` message (phase ∈
  `:starting | :running | :dead`), else `:ignore`. The CALLER verifies the
  `agent_uri` matches its own `self_uri` (PubSub topics are not an auth
  boundary) before mutating state.
  """
  @spec phase_from_signal(term()) :: {:ok, URI.t(), phase()} | :ignore
  def phase_from_signal({:pty_phase, %URI{} = agent_uri, phase, _meta})
      when phase in [:starting, :running, :dead],
      do: {:ok, agent_uri, phase}

  def phase_from_signal(_), do: :ignore
end

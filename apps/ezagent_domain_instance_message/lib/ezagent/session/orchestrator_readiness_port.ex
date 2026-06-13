defmodule Ezagent.Session.OrchestratorReadinessPort do
  @moduledoc """
  Session-owned, transport-neutral PORT for orchestrator-MCP readiness/context
  (decomposition spec §3.6 / codex HIGH-3).

  `domain.session`'s orchestrator readiness logic
  (`Ezagent.Entity.Session.Orchestrator`) calls THIS module; a transport plugin
  (cc) registers an IMPLEMENTATION at boot via `put_impl/1`. The session NEVER
  names a plugin/transport module — it resolves the impl through this registry
  indirection at RUNTIME. That keeps the target `im → session → agent` graph
  acyclic when PR-8 relocates `Ezagent.Orchestrator.McpChannel`/`McpRegistry`/
  `LiveJoinRegistry` out of the session domain into the cc plugin: the port
  exists BEFORE the relocation, so the relocation never introduces a
  session → cc-plugin compile edge.

  ## PR-8a vs PR-8

  - PR-8a (this) introduces the port + rewrites the orchestrator call sites to
    use it. The transport modules still live in the session domain; the cc
    adapter forwards to them (cc depends on the session domain). Pure
    indirection — no behavior change with cc loaded.
  - PR-8 relocates the transport modules into the cc plugin; the cc adapter
    then forwards to the cc-resident modules. The session is unaffected.

  ## Neutral fallback (declare-don't-call — Invariant #8)

  When NO impl is registered (e.g. the cc plugin is not loaded), there is simply
  no orchestrator-MCP transport — which is CORRECT, not an error:
  `joined?/1 → false` and `ready?/1 → false` (the readiness gate holds/polls,
  never silently drops), `register_context/2 → :ok` (no-op), `clear/1 → :ok`,
  `unregister/1 → :ok` (no-op), `lifecycle_topic/0 → a dead neutral topic`
  (subscribing to it is harmless; nothing broadcasts).
  """

  @callback lifecycle_topic() :: String.t()
  @callback joined?(orchestrator_uri :: URI.t()) :: boolean()
  @callback ready?(orchestrator_uri :: URI.t()) :: boolean()
  @callback clear(orchestrator_uri :: URI.t()) :: :ok
  @callback unregister(orchestrator_uri :: URI.t()) :: :ok
  @callback register_context(orchestrator_uri :: URI.t(), context :: keyword()) ::
              :ok | {:error, term()}

  @pt_key {__MODULE__, :impl}
  @neutral_topic "orchestrator:no-transport"

  @doc "Register the implementing module (a transport plugin calls this at boot)."
  @spec put_impl(module()) :: :ok
  def put_impl(module) when is_atom(module), do: :persistent_term.put(@pt_key, module)

  @doc "The registered impl module, or `nil` when no transport plugin is loaded."
  @spec impl() :: module() | nil
  def impl, do: :persistent_term.get(@pt_key, nil)

  @spec lifecycle_topic() :: String.t()
  def lifecycle_topic do
    case impl() do
      nil -> @neutral_topic
      m -> m.lifecycle_topic()
    end
  end

  @spec joined?(URI.t()) :: boolean()
  def joined?(%URI{} = uri) do
    case impl() do
      nil -> false
      m -> m.joined?(uri)
    end
  end

  @spec ready?(URI.t()) :: boolean()
  def ready?(%URI{} = uri) do
    case impl() do
      nil -> false
      m -> m.ready?(uri)
    end
  end

  @spec clear(URI.t()) :: :ok
  def clear(%URI{} = uri) do
    case impl() do
      nil -> :ok
      m -> m.clear(uri)
    end
  end

  @spec unregister(URI.t()) :: :ok
  def unregister(%URI{} = uri) do
    case impl() do
      nil -> :ok
      m -> m.unregister(uri)
    end
  end

  @spec register_context(URI.t(), keyword()) :: :ok | {:error, term()}
  def register_context(%URI{} = uri, context) when is_list(context) do
    case impl() do
      nil -> :ok
      m -> m.register_context(uri, context)
    end
  end
end

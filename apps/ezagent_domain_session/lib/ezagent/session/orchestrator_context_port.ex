defmodule Ezagent.Session.OrchestratorContextPort do
  @moduledoc """
  Session-owned port for registering the transport context of an orchestrator.

  The session domain owns when an orchestrator context becomes valid, while a
  transport plugin owns how that context is exposed. This seam carries only
  context registration; generic transport readiness and live-join state remain
  in the agent domain.

  When no transport plugin is loaded, registration and cleanup are neutral
  no-ops. The session-side `SessionManager` still starts, so adding a transport
  later does not change the executor's ownership or capability boundary.
  """

  @callback register_context(orchestrator_uri :: URI.t(), context :: keyword()) ::
              :ok | {:error, term()}
  @callback unregister(orchestrator_uri :: URI.t()) :: :ok

  @pt_key {__MODULE__, :impl}

  @doc "Register the transport plugin's context-only adapter."
  @spec put_impl(module()) :: :ok
  def put_impl(module) when is_atom(module), do: :persistent_term.put(@pt_key, module)

  @doc "Return the registered adapter, or nil when no transport plugin is loaded."
  @spec impl() :: module() | nil
  def impl, do: :persistent_term.get(@pt_key, nil)

  @doc "Register an orchestrator context, or no-op when no adapter is loaded."
  @spec register_context(URI.t(), keyword()) :: :ok | {:error, term()}
  def register_context(%URI{} = orchestrator_uri, context) when is_list(context) do
    case impl() do
      nil -> :ok
      module -> module.register_context(orchestrator_uri, context)
    end
  end

  @doc "Unregister an orchestrator context, or no-op when no adapter is loaded."
  @spec unregister(URI.t()) :: :ok
  def unregister(%URI{} = orchestrator_uri) do
    case impl() do
      nil -> :ok
      module -> module.unregister(orchestrator_uri)
    end
  end
end

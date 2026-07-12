defmodule Ezagent.Orchestrator.McpRegistry do
  @moduledoc """
  `orchestrator_uri → bound MCP-server context` lookup table — the
  glue that lets the orchestrator MCP transport bridge reach the
  RIGHT per-orchestrator `Ezagent.Orchestrator.McpServer` (Phase 7
  completion SPEC §2 "PR-5" — "make `McpServer` reachable by the
  bridge for the orchestrator it belongs to").

  ## Why a registry

  `Ezagent.Orchestrator.McpServer` is per-orchestrator-agent: each
  orchestrator's `%McpServer{}` is bound to ITS session URI, ITS
  workspace, and ITS four delegated caps (§1.4). The Generator
  (`Ezagent.Entity.Session.spawn_from_template/2`) knows that binding
  at spawn time — it just spawned the orchestrator INTO a session.

  The MCP transport bridge (`priv/orchestrator_bridge.py`), however,
  is a `claude`-launched stdio process; on the wire it can only
  identify itself by the agent URI its WS connect token authenticates
  (`Ezagent.Orchestrator.McpSocket`). It cannot supply the session /
  workspace / caps — and MUST NOT, because that is exactly the
  context an untrusted `claude` process could spoof.

  This registry closes the gap: the Generator REGISTERS the
  `(session_uri, workspace_uri, owner_uri, parent_template_uri)`
  context under the orchestrator's URI; the bridge's Channel
  (`Ezagent.Orchestrator.McpChannel`) — having token-verified that
  URI — uses this row as the fail-closed "is this a registered orchestrator?"
  readiness gate (transport #53 Decision C: the executor is the session-domain
  `Ezagent.Session.SessionManager`, keyed by orchestrator URI; the orchestrator's
  delegated caps are reconstructed SESSION-side there, never carried on the
  wire). The full context the row stores is read by the session-side
  materialization / readiness-register API.

  ## Storage

  ETS-backed, `:set`, `:public`, `:named_table`. Declared by
  `init/0` from `EzagentDomainInstanceMessage.Application.start/2` — the same
  lazy `init/0` pattern as the AgentBridge registry (the
  registry lives in a domain app, so it cannot ride the core
  `EzagentCore.EtsOwner` table list).

  Each row: `{orchestrator_uri_string, context_map}` where
  `context_map` carries `:session_uri`, `:workspace_uri`,
  `:owner_uri`, `:parent_template_uri`, and the durable
  `:binding_epoch`. The epoch makes every cache fill traceable to the
  materialization generation that authorized it.

  ## Lifecycle

  Registration is best-effort and idempotent — re-registering an
  orchestrator overwrites its row. There is no automatic unregister
  on orchestrator termination: the row is a small static map and a
  stale entry is harmless (a dead orchestrator's bridge cannot
  authenticate). A `unregister/1` is provided for explicit cleanup
  (used by tests).

  ## This is a CACHE, not the source of truth (Task #110)

  The registry is rebuilt EMPTY on a phx restart. That used to be a
  correctness bug — the orchestrator's management MCP operations went dead
  until a fresh session re-spawn. As of Task #110 it is a non-issue:
  `Ezagent.Orchestrator.McpServer.from_orchestrator_uri/1` treats this
  table as a READ-THROUGH CACHE. On a miss it LAZILY REBUILDS the
  context from the Session's durable `kind_snapshots` row (Session is
  `{:snapshot, :on_change}`) and fills the cache. The durable Session
  snapshot — not this ETS row — is the source of truth.
  """

  @table :ezagent_orchestrator_mcp_registry

  @type context :: %{
          session_uri: URI.t(),
          workspace_uri: URI.t(),
          owner_uri: URI.t() | nil,
          parent_template_uri: URI.t() | nil,
          binding_epoch: String.t()
        }

  @doc """
  Create the ETS table. Idempotent — safe to call on every boot.
  Called from `EzagentDomainInstanceMessage.Application.start/2`.
  """
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  @doc "The ETS table name (exposed for diagnostics / tests)."
  @spec table() :: atom()
  def table, do: @table

  @doc """
  Register the bound MCP-server context for `orchestrator_uri`.

  Called by the Generator after it has spawned the orchestrator into
  a session (`Ezagent.Entity.Session.spawn_from_template/2`). The
  context is the server-derived (caller, session, workspace) binding
  the transport bridge must NOT be trusted to supply itself.

  `opts`:
  - `:session_uri` (required) — the orchestrator's session `%URI{}`
  - `:workspace_uri` (required) — the session's workspace `%URI{}`
  - `:owner_uri` (optional) — the human owner `%URI{}`
  - `:parent_template_uri` (optional) — the SessionTemplate `%URI{}`
    the session was instantiated from (drives `update_template`)

  Idempotent: a second register for the same orchestrator overwrites.
  """
  @spec register(URI.t(), keyword()) :: :ok | {:error, term()}
  def register(%URI{} = orchestrator_uri, opts) do
    init()

    with {:ok, session_uri} <- fetch_uri(opts, :session_uri),
         {:ok, workspace_uri} <- fetch_uri(opts, :workspace_uri),
         {:ok, binding_epoch} <- fetch_string(opts, :binding_epoch) do
      context = %{
        session_uri: session_uri,
        workspace_uri: workspace_uri,
        owner_uri: opt_uri(opts, :owner_uri),
        parent_template_uri: opt_uri(opts, :parent_template_uri),
        binding_epoch: binding_epoch
      }

      true = :ets.insert(@table, {URI.to_string(orchestrator_uri), context})
      :ok
    end
  end

  @doc """
  Look up the bound context for `orchestrator_uri`.

  Returns `{:ok, context_map}` or `:error` if the orchestrator was
  never registered (or the row was lost to a restart before the
  Generator re-registered).
  """
  @spec lookup(URI.t()) :: {:ok, context()} | :error
  def lookup(%URI{} = orchestrator_uri) do
    init()

    case :ets.lookup(@table, URI.to_string(orchestrator_uri)) do
      [{_, context}] -> {:ok, context}
      [] -> :error
    end
  end

  @doc "Remove an orchestrator's row. Idempotent."
  @spec unregister(URI.t()) :: :ok
  def unregister(%URI{} = orchestrator_uri) do
    init()
    :ets.delete(@table, URI.to_string(orchestrator_uri))
    :ok
  end

  # --- internals ---------------------------------------------------------

  defp fetch_uri(opts, key) do
    case Keyword.get(opts, key) do
      %URI{} = uri -> {:ok, uri}
      s when is_binary(s) and s != "" -> {:ok, Ezagent.URI.new!(s)}
      _ -> {:error, {:missing_opt, key}}
    end
  end

  defp opt_uri(opts, key) do
    case Keyword.get(opts, key) do
      %URI{} = uri -> uri
      s when is_binary(s) and s != "" -> Ezagent.URI.new!(s)
      _ -> nil
    end
  end

  defp fetch_string(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_opt, key}}
    end
  end
end

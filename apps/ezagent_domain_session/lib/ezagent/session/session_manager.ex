defmodule Ezagent.Session.SessionManager do
  @moduledoc """
  Per-orchestrator MCP **executor** — a plain supervised `GenServer` in the
  session domain that runs the orchestrator's management operations (Decision C,
  `docs/superpowers/specs/2026-06-13-orchestrator-sessionmanager-kind-design.md`).

  ## Why a plain GenServer (NOT a Kind)

  This is the spiritual + near-literal successor of the old per-orchestrator
  `Ezagent.Orchestrator.McpServer` GenServer: it ALREADY ran the tools in its
  own process and dispatched to the Session Kind cross-process (never
  deadlocked). Decision C relocates that executor into the session domain, with
  the wire transport split out to the cc plugin and the orchestrator's delegated
  caps reconstructed SESSION-side. A Kind corresponds to a first-class domain
  concept (each has a URI scheme); SessionManager is an EXECUTION MECHANISM, so
  it is NOT a Kind — there is no `SessionManager` URI scheme and no
  cap-exempt dispatchable action that could be a forgeable entry.

  ## Identity / addressing

  Registered in `Ezagent.Session.SessionManagerRegistry` keyed by the
  orchestrator URI string, so the cc transport can `GenServer.call` it by URI
  without naming this module (cc depends on the session domain `only: :test`).
  The cc transport reaches it via the Registry `:via` tuple built from the URI
  string — a runtime edge, NOT a compile dependency.

  ## Lifecycle

  Spawned under `Ezagent.Session.SessionManagerSupervisor` (a
  `DynamicSupervisor`) at orchestrator materialization
  (`EzagentDomainInstanceMessage.SessionCreator` step 7, alongside the existing
  MCP-context registration), terminated with the session. Near-stateless: it
  caches only the binding (`orchestrator_uri`, `session_uri`, `workspace_uri`,
  `owner_uri`, `parent_template_uri`) and RECONSTRUCTS the orchestrator's
  delegated caps on every call (they may change after spawn).

  ## Per-call flow — `handle_call({:run_tool, tool, args, bridge_token}, …)`

  0. **AUTHZ — verify the bridge token (THE unforgeable gate, §2 step 0).**
     The cc socket authenticated the orchestrator's WS connection with its
     bridge token and FORWARDS that token (its connection credential, NOT
     caps) with the call. SessionManager VERIFIES it via
     `Ezagent.AgentBridge.TokenStore.verify_token/2` — a constant-time compare
     INSIDE the TokenStore, so the secret never leaves it (a getter would let
     co-resident code read it + forge this very call). A mismatch / absent
     token → `{:error, :unauthorized}` (fail-loud) BEFORE anything else. Being a
     GenServer is NOT sufficient authz: the Registry key is URI-derivable and
     the pid is enumerable, so a co-resident process could `GenServer.call`
     it; only the secret token closes that. cc forwarding caps would not help
     (caps are readable, hence forgeable).
  1. **Structural check (defense-in-depth).** The bound `orchestrator_uri`
     must equal this session's stored orchestrator (the durable
     `template_working_copy.orchestrator_uri` field) — fail-closed; a
     stale/foreign binding is rejected.
  2. **Reconstruct the orchestrator's 4 delegated caps SESSION-side** — the
     privileged read of the orchestrator agent's `:identity` slice
     (`Ezagent.Identity.list_caps_for/1`), run HERE, not in cc. cc carries NO
     caps.
  3. **Run the tool** via `Ezagent.Orchestrator.Tools.<tool>` under those
     reconstructed caps. Each tool mutation `Invocation.dispatch`es to the
     **Session Kind cross-process** (SessionManager ≠ Session → no self-call),
     a complete normal dispatch where the Session chokepoint cap-checks each
     op with the reconstructed caps. THIS is where the real CapBAC gating
     happens.
  4. **Reply with the raw `{:ok, value}` / `{:error, reason}`** — cc encodes
     it into the MCP `tools/call` response.
  """

  use GenServer

  require Logger

  alias Ezagent.Session.OrchestratorBinding
  alias Ezagent.Session.Config, as: SessionConfig

  @registry Ezagent.Session.SessionManagerRegistry
  @supervisor Ezagent.Session.SessionManagerSupervisor

  @enforce_keys [:orchestrator_uri, :session_uri, :workspace_uri]
  defstruct [
    :orchestrator_uri,
    :session_uri,
    :workspace_uri,
    :owner_uri,
    :parent_template_uri
  ]

  @type binding :: %__MODULE__{
          orchestrator_uri: URI.t(),
          session_uri: URI.t(),
          workspace_uri: URI.t(),
          owner_uri: URI.t() | nil,
          parent_template_uri: URI.t() | nil
        }

  # --- addressing -------------------------------------------------------

  @doc "The Registry name used for `:via` addressing (exposed for cc + tests)."
  @spec registry() :: module()
  def registry, do: @registry

  @doc """
  The `:via` tuple addressing the SessionManager for `orchestrator_uri`.

  Built from the URI STRING through the shared Registry — the cc transport
  uses this (NOT an `alias` of this module) to reach the process.
  """
  @spec via(URI.t() | String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(%URI{} = orchestrator_uri), do: via(URI.to_string(orchestrator_uri))

  def via(orchestrator_uri) when is_binary(orchestrator_uri),
    do: {:via, Registry, {@registry, orchestrator_uri}}

  @doc "Look up the running SessionManager pid for `orchestrator_uri`."
  @spec whereis(URI.t() | String.t()) :: {:ok, pid()} | :error
  def whereis(%URI{} = orchestrator_uri), do: whereis(URI.to_string(orchestrator_uri))

  def whereis(orchestrator_uri) when is_binary(orchestrator_uri) do
    case Registry.lookup(@registry, orchestrator_uri) do
      # Filter a just-terminated pid whose Registry monitor-cleanup has not yet
      # fired (the `:DOWN` reaches `stop/1` before the Registry processes its own
      # monitor) — a dead pid is NOT a live executor.
      [{pid, _}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end

  # --- lifecycle --------------------------------------------------------

  @doc """
  Start a SessionManager bound to one orchestrator under the
  `SessionManagerSupervisor`, registered in `SessionManagerRegistry` keyed by
  the orchestrator URI string. Idempotent: if one is already running for the
  orchestrator, returns it.

  `opts` (all `%URI{}`):
  - `:orchestrator_uri` (required)
  - `:session_uri` (required)
  - `:workspace_uri` (required)
  - `:owner_uri` (optional)
  - `:parent_template_uri` (optional)
  """
  @spec ensure_started(keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(opts) do
    with {:ok, binding} <- build_binding(opts) do
      spec = %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [binding]},
        restart: :transient
      }

      case DynamicSupervisor.start_child(@supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, _} = err -> err
      end
    end
  end

  @doc """
  Ensure the SessionManager exists for `session_uri`'s orchestrator, rebuilding
  the binding from the session's LIVE `:session` slice.

  This is the COLD-RESTART self-heal (codex C-rC-P1): after a BEAM restart both
  the `SessionManagerRegistry` and the cc `McpRegistry` start empty; when the
  Session Kind rehydrates (the `session` SpawnRegistry route), this re-derives
  the orchestrator binding from the durable working copy + starts the executor,
  so the orchestrator's bridge can reconnect + drive `tools/call` without a fresh
  `create_session`. A session with NO orchestrator (the common case) is a no-op
  (`{:ok, :no_orchestrator}`).
  """
  @spec ensure_for_session(URI.t()) ::
          {:ok, pid()} | {:ok, :no_orchestrator} | {:error, term()}
  def ensure_for_session(%URI{} = session_uri) do
    case live_working_copy(session_uri) do
      wc when is_map(wc) ->
        case OrchestratorBinding.current(wc) do
          {:ok, binding} ->
            ensure_started(
              orchestrator_uri: binding.uri,
              session_uri: session_uri,
              workspace_uri: workspace_of(session_uri),
              owner_uri: live_owner_uri(session_uri),
              parent_template_uri: Map.get(wc, :session_template_uri)
            )

          _ ->
            {:ok, :no_orchestrator}
        end

      _ ->
        {:ok, :no_orchestrator}
    end
  end

  defp workspace_of(%URI{} = session_uri) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = ws -> ws
      _ -> nil
    end
  end

  defp live_owner_uri(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: %{owner_uri: %URI{} = owner}}} -> owner
      {:ok, %{owner_uri: %URI{} = owner}} -> owner
      _ -> nil
    end
  end

  @doc """
  Terminate the SessionManager for `orchestrator_uri` (with the session).

  SYNCHRONOUS w.r.t. the Registry: it waits for the process to die before
  returning, so the `SessionManagerRegistry` key is free. This matters for the
  rollback→recreate path (codex C-rC-P2): `Registry` cleans up its entry on the
  process `:DOWN` monitor (async), so without the wait a recreate's
  `ensure_started` could observe the dying registration and reuse a STALE pid.
  """
  @spec stop(URI.t() | String.t()) :: :ok
  def stop(orchestrator_uri) do
    case whereis(orchestrator_uri) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        _ = DynamicSupervisor.terminate_child(@supervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> Process.demonitor(ref, [:flush])
        end

      :error ->
        :ok
    end

    :ok
  end

  @doc false
  @spec start_link(binding()) :: GenServer.on_start()
  def start_link(%__MODULE__{orchestrator_uri: orchestrator_uri} = binding) do
    GenServer.start_link(__MODULE__, binding, name: via(orchestrator_uri))
  end

  # --- client API -------------------------------------------------------

  @doc """
  Run an orchestrator tool against the SessionManager for `orchestrator_uri`,
  authenticated by the orchestrator's `bridge_token`.

  This is what the cc transport calls (by URI, NOT by aliasing this module —
  cc uses the bare-tuple message form via `via/1`). Returns the tool's raw
  `{:ok, value}` / `{:error, reason}`, or `{:error, :session_manager_unavailable}`
  when no SessionManager is running for the orchestrator.
  """
  @spec run_tool(URI.t() | String.t(), String.t() | atom(), map(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def run_tool(orchestrator_uri, tool, arguments, bridge_token) do
    case whereis(orchestrator_uri) do
      {:ok, pid} ->
        # `:infinity` (codex C-rC-P2) — a tool may spawn/regenerate a worker
        # agent, exceeding the default 5s call timeout; the outer transports
        # bound the latency. Match the cc transport hop.
        GenServer.call(pid, {:run_tool, tool, arguments, bridge_token}, :infinity)

      :error ->
        {:error, :session_manager_unavailable}
    end
  end

  @doc "The assembled Session-Config operation names."
  @spec tool_names() :: [atom()]
  def tool_names do
    Ezagent.Session.Config.Catalog.operations()
    |> Enum.map(&String.to_existing_atom(&1.name))
  end

  # --- GenServer --------------------------------------------------------

  @impl GenServer
  def init(%__MODULE__{} = binding), do: {:ok, binding}

  @impl GenServer
  def handle_call({:run_tool, tool, arguments, bridge_token}, _from, %__MODULE__{} = binding) do
    args = if is_map(arguments), do: arguments, else: %{}
    {:reply, run(binding, tool, args, bridge_token), binding}
  end

  def handle_call(:binding, _from, %__MODULE__{} = binding), do: {:reply, binding, binding}

  # Transport authN and structural binding stay here; executable ownership
  # begins at the SessionConfig domain boundary.
  defp run(%__MODULE__{} = binding, tool, arguments, bridge_token) do
    with :ok <- verify_bridge_token(binding, bridge_token),
         {:ok, _working_copy} <- structural_check(binding) do
      SessionConfig.execute(
        tool,
        arguments,
        binding.orchestrator_uri,
        addressed_target(binding, tool)
      )
    end
  end

  defp addressed_target(binding, tool) do
    case SessionConfig.operation(tool) do
      %{target_scope: :workspace} -> binding.workspace_uri
      _ -> binding.session_uri
    end
  end

  # === Step 0 — verify the bridge token (THE unforgeable gate) ===========
  #
  # Delegate the constant-time compare to `TokenStore.verify_token/2` so the
  # orchestrator's secret NEVER leaves the TokenStore (codex C-r6-P1): a getter
  # would let co-resident code read the token + forge this very call. A
  # nil/non-binary token, an orchestrator with no minted token, or a mismatch →
  # `{:error, :unauthorized}` (fail-loud), BEFORE any tool or cap work. The token
  # is the orchestrator's CONNECTION credential (held by the cc socket that
  # authenticated the WS), never caps.
  defp verify_bridge_token(%__MODULE__{orchestrator_uri: orchestrator_uri}, presented) do
    credential = %Ezagent.Authentication.BridgeCredential{
      token: presented,
      principal: orchestrator_uri
    }

    case Ezagent.Authentication.authenticate(credential) do
      {:ok, ^orchestrator_uri} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  # === Step 1 — structural caller-is-our-orchestrator check ==============
  #
  # Defense-in-depth: the bound orchestrator URI MUST equal the session's
  # DURABLE stored orchestrator (the LIVE working-copy field). A stale binding or
  # a session whose orchestrator changed → fail-closed. Returns the LIVE working
  # copy `{:ok, wc}` so step 3 reads the CURRENT mutable fields
  # (`parent_template_uri` / owner) — a repair that re-materializes the same
  # orchestrator with a new parent is reflected immediately, never the stale
  # cached binding (codex C-r2-P2).
  defp structural_check(%__MODULE__{} = binding) do
    with wc when is_map(wc) <- live_working_copy(binding.session_uri),
         {:ok, stored} <- OrchestratorBinding.current(wc),
         true <- URI.to_string(stored.uri) == URI.to_string(binding.orchestrator_uri) do
      {:ok, wc}
    else
      _ -> {:error, :unauthorized}
    end
  end

  # Read the LIVE Session Kind's `:session` slice working copy via the
  # same-domain canonical reader `Ezagent.Kind.get_slice/2`. SessionManager is
  # materialized alongside the live session, so the live slice is authoritative;
  # we do not re-read the durable snapshot (that path belongs to the cc
  # transport's registration rebuild). Unwraps the Lifecycle two-container
  # `%{state: %{...}}` shape (a flat slice falls through unchanged).
  defp live_working_copy(%URI{} = session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :session) do
      {:ok, %{state: %{template_working_copy: wc}}} when is_map(wc) -> wc
      {:ok, %{template_working_copy: wc}} when is_map(wc) -> wc
      _ -> nil
    end
  end

  # --- binding construction ---------------------------------------------

  # The three required binding URIs must be present + well-formed; a malformed
  # one is a materialization bug, surfaced as `{:error, {:invalid_uri_opt, …}}`
  # (fail-loud, not silently dropped). The two optional URIs default to nil.
  defp build_binding(opts) do
    with {:ok, orchestrator_uri} <- require_uri(opts, :orchestrator_uri),
         {:ok, session_uri} <- require_uri(opts, :session_uri),
         {:ok, workspace_uri} <- require_uri(opts, :workspace_uri),
         {:ok, owner_uri} <- optional_uri(opts, :owner_uri),
         {:ok, parent_template_uri} <- optional_uri(opts, :parent_template_uri) do
      {:ok,
       %__MODULE__{
         orchestrator_uri: orchestrator_uri,
         session_uri: session_uri,
         workspace_uri: workspace_uri,
         owner_uri: owner_uri,
         parent_template_uri: parent_template_uri
       }}
    end
  end

  defp require_uri(opts, key) do
    case Keyword.get(opts, key) do
      %URI{} = uri -> {:ok, uri}
      s when is_binary(s) and s != "" -> parse_binding_uri(key, s)
      nil -> {:error, {:missing_opt, key}}
      other -> {:error, {:invalid_uri_opt, key, other}}
    end
  end

  defp optional_uri(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      %URI{} = uri -> {:ok, uri}
      s when is_binary(s) and s != "" -> parse_binding_uri(key, s)
      other -> {:error, {:invalid_uri_opt, key, other}}
    end
  end

  defp parse_binding_uri(key, s) do
    {:ok, Ezagent.URI.new!(s)}
  rescue
    ArgumentError -> {:error, {:invalid_uri_opt, key, s}}
  end
end

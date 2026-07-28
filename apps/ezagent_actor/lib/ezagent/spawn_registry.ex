defmodule Ezagent.SpawnRegistry do
  @moduledoc """
  Registry mapping a URI scheme to a spawn function.

  Phase 4c: the Workspace Loader holds a list of `{:member, URI}` tuples
  (returned by `Ezagent.ActionSet.Workspace.invoke(:instantiate, ...)`) and
  needs to bring each member URI back to life. It has no idea which
  plugin owns which Kind's supervisor — that's the **plugin isolation
  north star** at the boundary.

  Each plugin registers a spawn function for the URI schemes it owns:

      Ezagent.SpawnRegistry.register("entity", fn uri ->
        case Ezagent.URI.type(uri) do
          {:ok, "agent"} -> ...
          {:ok, "user"}  -> ...
        end
      end)

  When the Loader sees an agent entity URI it calls
  `Ezagent.SpawnRegistry.spawn(uri)` and ezagent_core never has to know
  about `EzagentDomainInstanceMessage.AgentSupervisor`.

  ## Idempotency

  `spawn/1,2` is safe to re-call for a URI that's already alive — it
  looks up `KindRegistry` first and returns `{:ok, pid}` for the
  existing process. This matters because Loader runs at app start
  and plugins may also spawn their own canonical Kinds (admin User,
  default Session).

  `spawn/1` collapses "this call started it" and "it already existed"
  into one `{:ok, pid}`. A caller that needs the distinction — e.g.
  `update_agent_template`'s rollback-safe swap, which must NOT adopt a
  worker another process created — uses `spawn_detailed/1,2`, which
  preserves the atomic `DynamicSupervisor` outcome
  (`{:ok, :started, pid}` vs `{:ok, :already_started, pid}`).

  ## ETS layout

  `:ezagent_spawn_registry` set table owned by `EzagentActor.EtsOwner`. Keys
  are scheme strings (e.g. `"entity"`), values are one-arity functions
  taking a `%URI{}` or two-arity functions taking the URI and runtime options.
  """

  @table :ezagent_spawn_registry

  def table, do: @table

  @doc """
  Register (or overwrite) the spawn fn for a URI scheme.

  Plugins call this in their `Application.start/2`. Re-registration
  is intentional — late-binding plugins win.

  ## PR #145 — co-registers scheme into `Ezagent.URI.SchemeRegistry`

  This is the **lockdown** (SPEC v2 §5.6 §5.11): plugins can extend
  the URI scheme allowlist ONLY through this audited path. A plugin
  cannot write directly to `:ezagent_scheme_registry` ETS in normal
  code, so any new scheme has a registered spawn fn to back it.
  """
  @type spawn_fun ::
          (URI.t() -> {:ok, pid()} | {:error, term()})
          | (URI.t(), keyword() -> {:ok, pid()} | {:error, term()})

  @spec register(String.t(), spawn_fun()) :: :ok
  def register(scheme, spawn_fn)
      when is_binary(scheme) and (is_function(spawn_fn, 1) or is_function(spawn_fn, 2)) do
    :ets.insert(@table, {scheme, spawn_fn})
    :ok = Ezagent.URI.SchemeRegistry.register(scheme)
    :ok
  end

  @doc """
  Spawn (or look up an existing) Kind at the given URI.

  The option-bearing form accepts only `:launch_context`. Unknown options fail
  closed. A legacy arity-one registration is used only with empty options;
  supplying launch context to it returns `{:error, :launch_context_unsupported}`.

  Returns `{:ok, pid}` either way. `{:error, :no_spawn_fn}` if no
  plugin registered the URI's scheme.

  ## Idempotency collapse (and why `spawn_detailed/1` exists)

  `spawn/1` deliberately collapses three distinct outcomes into a
  single `{:ok, pid}`:

    1. the URI was ALREADY live in `KindRegistry` (lookup hit);
    2. THIS call's `DynamicSupervisor.start_child` started the worker
       (`{:ok, pid}`);
    3. the worker was started CONCURRENTLY — the supervisor returned
       `{:error, {:already_started, pid}}`.

  For the Loader / boot path that collapse is correct (a re-run is a
  no-op). But it ERASES the "did THIS call win the start" signal —
  and that signal is the ground truth `update_agent_template`'s swap
  needs to know it is not silently adopting a worker another process
  created (codex round-6 HIGH-1). The `DynamicSupervisor` ALREADY
  distinguishes cases 2 and 3 atomically; `spawn_detailed/1` preserves
  that distinction instead of collapsing it.
  """
  @spec spawn(URI.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def spawn(%URI{scheme: scheme} = uri, opts \\ []) when is_binary(scheme) and is_list(opts) do
    case spawn_detailed(uri, opts) do
      {:ok, _started_or_adopted, pid} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  @doc """
  Ensure the Kind at `uri` is a LIVE actor, rehydrating it from durable
  state if needed (team-routing-unification §3.8 rehydrate-or-spawn).

  Unlike `spawn/1`, this REFUSES to materialise a Kind that was never
  durably created. An access path (e.g. the Feishu inbound dispatcher
  resolving a chat→session binding) uses this to bring a cold-but-real
  Kind back to life after a node restart — without silently creating an
  unowned fresh one when the durable state is genuinely absent.

    * `{:ok, :live}`            — already a live actor.
    * `{:ok, :rehydrated}`      — was cold but durably exists; spawned now.
    * `{:error, :not_created}`  — never durably created → no spawn.
    * `{:error, term()}`        — durable, but the rehydrate spawn failed.

  Durable existence is "a snapshot row was persisted for this URI"
  (`KindSnapshot.get/1` — a plain read, NOT the create/activate marker, so
  it stays within the persistence-access discipline). Row-existence — not
  the `ever_created` marker — is the right signal: a row means `save_now`
  ran, i.e. the Kind WAS created, and it is robust to legacy rows whose
  `ever_created` marker predates the marker column or was never set (codex
  review). A missing row means never-created (or destroyed → row deleted)
  → refuse, so an inbound binding to a vanished session never silently
  materialises a fresh unowned one.
  """
  @spec ensure_live(URI.t()) :: {:ok, :live | :rehydrated} | {:error, term()}
  def ensure_live(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        {:ok, :live}

      :error ->
        if is_nil(Ezagent.Ecto.KindSnapshot.get(URI.to_string(uri))) do
          {:error, :not_created}
        else
          case __MODULE__.spawn(uri) do
            {:ok, _pid} -> {:ok, :rehydrated}
            {:error, _} = err -> err
          end
        end
    end
  end

  @doc """
  #201 PR-1 — like `spawn_detailed/2`, but additionally surfaces the
  core-issued `created?` verdict as a creation receipt:

    * `{:ok, :started, pid, %{created?: created?}}` — THIS call won the
      atomic start; `created?` is the Lifecycle-owned logical-create
      verdict read back synchronously from the freshly started Kind
      (`Ezagent.Kind.create_freshness/1`). A cold rehydrate of a durably
      pre-existing Kind reports `created?: false` even though it won
      `:started` — the distinction a duplicate-create gate needs.
    * `{:ok, :already_started, pid, %{created?: false}}` — adopted; this
      call created nothing.
    * `{:error, term()}` — as `spawn_detailed/2`.

  The receipt is a synchronous return value only — nothing is threaded
  through invocation/signal. `spawn_detailed/2` is unchanged for callers
  that do not gate on logical-create.
  """
  @spec spawn_receipt(URI.t(), keyword()) ::
          {:ok, :started | :already_started, pid(), %{created?: boolean()}}
          | {:error, term()}
  def spawn_receipt(%URI{} = uri, opts \\ []) when is_binary(uri.scheme) and is_list(opts) do
    case spawn_detailed(uri, opts) do
      {:ok, :started, pid} ->
        {:ok, :started, pid, %{created?: started_create_freshness(uri, pid) == :created}}

      {:ok, :already_started, pid} ->
        {:ok, :already_started, pid, %{created?: false}}

      {:error, _} = err ->
        err
    end
  end

  # The registered spawn fn may spawn the Kind under a URI the registry
  # caller did not literally pass (production entity fns spawn AT the
  # requested URI, but the receipt must not assume it): resolve the fresh
  # Kind's own URI from its registration, falling back to the requested
  # URI. A pid that registered nothing (a non-Kind spawn fn) reads the
  # requested URI, which has no verdict row → fail-conservative `:unknown`.
  # #201-cred (codex r2 MEDIUM-6) — the verdict is read bound to the EXACT
  # started pid, so a supervisor restart cannot overwrite the winning
  # incarnation's verdict.
  defp started_create_freshness(%URI{} = uri, pid) do
    case Registry.keys(Ezagent.KindRegistry, pid) do
      [uri_str] -> Ezagent.Kind.create_freshness(uri_str, pid)
      _ -> Ezagent.Kind.create_freshness(uri, pid)
    end
  end

  @doc """
  Spawn (or look up an existing) Kind at the given URI, PRESERVING the
  atomic "this call won the start" signal.

  `spawn_detailed/2` validates the frozen `:launch_context` option surface;
  unsupported options are returned as an error before lookup or invocation.

  This is the structural fix for codex round-6 HIGH-1: the freshness
  of a worker MUST come from the atomic spawn result, never from a
  pre-probe of `KindRegistry` (a pre-probe is a TOCTOU window — a
  concurrent registration between the probe and the spawn makes an
  adopted worker read as fresh).

  Returns:

    * `{:ok, :started, pid}` — THIS call's `DynamicSupervisor.start_child`
      started the worker. The caller created it.
    * `{:ok, :already_started, pid}` — the worker already existed (a
      `KindRegistry` lookup hit OR the supervisor returned
      `{:error, {:already_started, pid}}` — a concurrent start that
      THIS call lost). The caller ADOPTED it.
    * `{:error, term()}` — no spawn fn for the scheme, or the spawn fn
      failed.

  A `KindRegistry` lookup hit is reported as `:already_started`
  (conservatively — the caller did not create the worker). The race
  window narrows to the spawn fn itself, where `DynamicSupervisor`
  resolves it atomically: exactly one concurrent caller gets
  `{:ok, :started, _}`, every other gets `{:ok, :already_started, _}`.
  """
  @spec spawn_detailed(URI.t(), keyword()) ::
          {:ok, :started | :already_started, pid()} | {:error, term()}
  def spawn_detailed(%URI{scheme: scheme} = uri, opts \\ [])
      when is_binary(scheme) and is_list(opts) do
    with {:ok, opts} <- Keyword.validate(opts, [:launch_context]),
         :ok <- dispatch_policy().assert_local_owner(uri, {:spawn, uri}) do
      do_spawn_detailed(uri, scheme, opts)
    end
  end

  defp do_spawn_detailed(%URI{} = uri, scheme, opts) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} ->
        {:ok, :already_started, pid}

      :error ->
        case :ets.lookup(@table, scheme) do
          [{^scheme, fun}] ->
            case invoke_spawn_fun(fun, uri, opts) do
              {:ok, pid} -> {:ok, :started, pid}
              {:error, {:already_started, pid}} -> {:ok, :already_started, pid}
              {:error, _} = err -> err
              other -> {:error, {:unexpected_spawn_fn_result, other}}
            end

          [] ->
            {:error, {:no_spawn_fn, scheme}}
        end
    end
  end

  defp invoke_spawn_fun(fun, uri, opts) when is_function(fun, 2), do: fun.(uri, opts)
  defp invoke_spawn_fun(fun, uri, []) when is_function(fun, 1), do: fun.(uri)

  defp invoke_spawn_fun(fun, _uri, [_ | _]) when is_function(fun, 1),
    do: {:error, :launch_context_unsupported}

  @doc "List registered URI schemes (for debugging / mix tasks)."
  @spec registered_schemes() :: [String.t()]
  def registered_schemes do
    :ets.tab2list(@table)
    |> Enum.map(fn {scheme, _fn} -> scheme end)
    |> Enum.sort()
  end

  # C5 §3.4 DispatchPolicyPort — the per-URI workspace owner gate goes
  # through the config-resolved port, never the literal
  # `Ezagent.WorkspaceOwnerGate` spine. Wired at core boot
  # (`Ezagent.Kind.Adapters.wire!/0`) to
  # `Ezagent.Kind.Adapters.DispatchPolicyAdapter`.
  defp dispatch_policy, do: Application.fetch_env!(:ezagent_actor, :dispatch_policy)
end

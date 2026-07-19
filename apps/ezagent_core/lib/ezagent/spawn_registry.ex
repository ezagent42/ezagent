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

  `spawn/1` is safe to re-call for a URI that's already alive — it
  looks up `KindRegistry` first and returns `{:ok, pid}` for the
  existing process. This matters because Loader runs at app start
  and plugins may also spawn their own canonical Kinds (admin User,
  default Session).

  `spawn/1` collapses "this call started it" and "it already existed"
  into one `{:ok, pid}`. A caller that needs the distinction — e.g.
  `update_agent_template`'s rollback-safe swap, which must NOT adopt a
  worker another process created — uses `spawn_detailed/1`, which
  preserves the atomic `DynamicSupervisor` outcome
  (`{:ok, :started, pid}` vs `{:ok, :already_started, pid}`).

  ## ETS layout

  `:ezagent_spawn_registry` set table owned by `EzagentCore.EtsOwner`. Keys
  are scheme strings (e.g. `"entity"`), values are 1-arity functions
  taking a `%URI{}`.
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
  @spec register(String.t(), (URI.t() -> {:ok, pid()} | {:error, term()})) :: :ok
  def register(scheme, spawn_fn) when is_binary(scheme) and is_function(spawn_fn, 1) do
    :ets.insert(@table, {scheme, spawn_fn})
    :ok = Ezagent.URI.SchemeRegistry.register(scheme)
    :ok
  end

  @doc """
  Spawn (or look up an existing) Kind at the given URI.

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
  @spec spawn(URI.t()) :: {:ok, pid()} | {:error, term()}
  def spawn(%URI{scheme: scheme} = uri) when is_binary(scheme) do
    case spawn_detailed(uri) do
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
        # task #180 (codex F1-b): the already-running return must not hand
        # back a tombstoned principal's still-live process — fence it (and
        # tear the stale process down) exactly like the spawn path.
        case Ezagent.SpawnFence.check(uri) do
          :ok -> {:ok, :live}
          {:error, reason} -> refuse_fenced_live(uri, reason)
        end

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
  Spawn (or look up an existing) Kind at the given URI, PRESERVING the
  atomic "this call won the start" signal.

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
  @spec spawn_detailed(URI.t()) ::
          {:ok, :started | :already_started, pid()} | {:error, term()}
  def spawn_detailed(%URI{scheme: scheme} = uri) when is_binary(scheme) do
    with :ok <- Ezagent.WorkspaceOwnerGate.assert_local_owner_for_uri(uri, {:spawn, uri}) do
      do_spawn_detailed(uri, scheme)
    end
  end

  defp do_spawn_detailed(%URI{} = uri, scheme) do
    # task #180 (codex F1-a/b) — the spawn fence runs at the REGISTRY
    # chokepoint, before BOTH the already-running return and the spawn-fn
    # invocation, so a tombstoned principal is refused no matter which
    # spawn fn is registered or which behavior set the Kind declares.
    case Ezagent.SpawnFence.check(uri) do
      :ok -> do_spawn_detailed_fenced(uri, scheme)
      {:error, reason} -> refuse_fenced_spawn(uri, reason)
    end
  end

  defp do_spawn_detailed_fenced(%URI{} = uri, scheme) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} ->
        {:ok, :already_started, pid}

      :error ->
        case :ets.lookup(@table, scheme) do
          [{^scheme, fun}] ->
            case fun.(uri) do
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

  # A fenced (tombstoned) URI that has NO live process: refuse the spawn.
  defp refuse_fenced_spawn(%URI{} = uri, reason) do
    # Defense in depth: a process may have slipped in between the fence
    # check and this return (or the tombstone raced a concurrent spawn) —
    # tear down anything registered at the fenced URI before refusing.
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} -> refuse_fenced_live(uri, reason)
      :error -> {:error, reason}
    end
  end

  # A fenced (tombstoned) URI WITH a live process: tear the stale process
  # down (best-effort — `Kind.terminate/1` is idempotent + swallows
  # teardown errors) and refuse the caller. The tombstoned principal is
  # never handed back as `{:ok, pid}` (codex F1-b).
  defp refuse_fenced_live(%URI{} = uri, reason) do
    _ = Ezagent.Kind.terminate(uri)
    {:error, reason}
  end

  @doc "List registered URI schemes (for debugging / mix tasks)."
  @spec registered_schemes() :: [String.t()]
  def registered_schemes do
    :ets.tab2list(@table)
    |> Enum.map(fn {scheme, _fn} -> scheme end)
    |> Enum.sort()
  end
end

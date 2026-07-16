defmodule Ezagent.ExternalMirror.WorkerSpawn do
  @moduledoc """
  `Ezagent.ExternalMirror.WorkerSpawn` — the spawn-side bridge
  between `Ezagent.Kind.spawn/2` semantics and the two-tier
  RootSupervisor → PerBindingSupervisor topology.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §6.3:

  > `Kind.spawn(ExternalMirrorWorker, ...)` is the public entry.
  > Internally it: (1) creates a PerBindingSupervisor under
  > RootSupervisor (via `DynamicSupervisor.start_child/2`);
  > (2) the PerBindingSupervisor's child spec spawns the Worker
  > Kind via standard `Kind.Server.start_link/1`.
  > **P16 (single Kind spawn entry) is preserved — plugin code
  > never sees PerBindingSupervisor directly.**

  The standard `Ezagent.Kind.spawn/2` issues
  `DynamicSupervisor.start_child(supervisor, {Kind.Server,
  {kind_module, params}})` and would put `Kind.Server` directly
  under whichever supervisor `kind_module.supervisor/0` names. For
  ExternalMirrorWorker the supervisor MUST be the two-tier shape;
  this helper does the layering.

  ## Why not extend Kind.spawn/2 in core

  The two-tier topology is a Domain concern (per-binding crash
  isolation for ExternalMirror workers, SPEC §5.3) — not a generic
  Kind framework concern. Embedding it in core would couple
  `apps/ezagent_core/` to ExternalMirror-specific semantics
  (PerBindingSupervisor restart budgets, Registry-keyed names).

  Instead, `Ezagent.Entity.ExternalMirrorWorker.spawn_strategy/0`
  declares the custom strategy; `Ezagent.Kind.spawn/2` reads it via
  `function_exported?/3` and delegates to this module's
  `spawn_kind_server/1` when present (a small, generic extension —
  see PR-EM-2's `Ezagent.Kind` change).

  ## Idempotency contract

  Concurrent `spawn/1` calls for the same `{session_uri,
  adapter_id, target_id}` triple collide on `WorkerRegistry` (via
  the PerBindingSupervisor's `{:via, Registry, ...}` name) — the
  second caller gets `{:error, {:already_started, sup_pid}}` from
  `DynamicSupervisor.start_child/2`, exactly matching the SPEC §3.1
  idempotency contract the reconciler relies on.
  """

  alias Ezagent.ExternalMirror.{PerBindingSupervisor, RootSupervisor, WorkerRegistry}
  alias Ezagent.Entity.ExternalMirrorWorker

  @doc """
  Spawn a Worker for `{session_uri, adapter_id, target_id}`.

  `opts` carries binding-time metadata (`bound_by`, `bound_at`,
  caller-supplied `metadata` map). PR-EM-3 builds the full args
  map at `:bind` action body time and passes it through; PR-EM-2
  acceptance tests build a minimal map directly.

  Returns:
  - `{:ok, sup_pid}` on fresh spawn (the PerBindingSupervisor pid;
    the Worker Kind pid is reachable via
    `Ezagent.KindRegistry.lookup(worker_uri/3)`).
  - `{:error, {:already_started, sup_pid}}` when a PerBindingSupervisor
    is already registered for this binding_uri (concurrent
    `start_child` for the same triple). Callers treat as success
    per SPEC §3.1.
  - `{:error, reason}` from `DynamicSupervisor.start_child/2` on
    any other failure (RootSupervisor not started, child init
    raised, …) — propagated verbatim.
  """
  @spec spawn(URI.t(), String.t(), term(), map()) ::
          DynamicSupervisor.on_start_child()
  def spawn(%URI{} = session_uri, adapter_id, target_id, opts \\ %{})
      when is_binary(adapter_id) and is_map(opts) do
    worker_uri = worker_uri_for(session_uri, adapter_id, target_id)
    binding_uri = URI.to_string(worker_uri)

    subscribe_cap = issue_subscribe_cap!(session_uri, worker_uri)

    worker_args = %{
      uri: worker_uri,
      session_uri: session_uri,
      adapter_id: adapter_id,
      target_id: target_id,
      opts: opts,
      subscribe_cap: subscribe_cap
    }

    child_spec = %{
      id: {PerBindingSupervisor, binding_uri},
      start:
        {PerBindingSupervisor, :start_link,
         [%{binding_uri: binding_uri, worker_args: worker_args}]},
      # codex round-1 CRIT (2026-05-25): r1 had `restart: :transient`
      # but OTP supervisor intensity exhaustion exits with `:shutdown`,
      # and `:transient` does NOT restart on `:shutdown`. The intended
      # SPEC §6.3 loop ("inner 3/30s burns → RootSupervisor restarts
      # PerBindingSupervisor → cycle continues until RootSupervisor's
      # 100/60s burns") never fired — a single restart-storm would
      # leave the binding permanently down after one inner-budget
      # exhaustion.
      #
      # `:permanent` is correct: ANY exit (`:normal`, `:shutdown`,
      # crash) restarts. The graceful-unbind path
      # (`DynamicSupervisor.terminate_child/2` from `terminate/3` below)
      # bypasses the restart strategy entirely — `terminate_child`
      # removes the child from the dynamic supervisor's bookkeeping
      # before propagating shutdown, so even `:permanent` children
      # do not respawn after explicit termination.
      restart: :permanent,
      type: :supervisor
    }

    DynamicSupervisor.start_child(RootSupervisor, child_spec)
  end

  defp issue_subscribe_cap!(session_uri, worker_uri) do
    requested =
      Ezagent.Capability.cap(
        :session,
        Ezagent.ActionSet.Publisher.SessionImpl,
        :subscribe_from,
        Ezagent.URI.instance(session_uri),
        Ezagent.Capability.workspace_of(session_uri)
      )

    case Ezagent.Identity.Grant.issue_cap(
           worker_uri,
           requested,
           {:admin, Ezagent.Entity.User.admin_uri()}
         ) do
      {:ok, cap} ->
        cap

      {:error, reason} ->
        raise "failed to issue ExternalMirrorWorker subscribe cap: #{inspect(reason)}"
    end
  end

  @doc """
  Adapt the params map handed by `Ezagent.Kind.spawn/2` into the
  4-arg `spawn/4` call above. Used by
  `ExternalMirrorWorker.spawn_strategy/0`'s contract: when
  `Kind.spawn(ExternalMirrorWorker, params)` is invoked, the
  framework dispatches here with `params` — we extract the triple
  and forward.

  `params` MUST include `:session_uri`, `:adapter_id`, `:target_id`.
  Optional `:opts` (default `%{}`). Returns the same shape as
  `DynamicSupervisor.start_child/2`.
  """
  @spec spawn_kind_server(map()) :: DynamicSupervisor.on_start_child()
  def spawn_kind_server(
        %{
          session_uri: %URI{} = session_uri,
          adapter_id: adapter_id,
          target_id: target_id
        } = params
      )
      when is_binary(adapter_id) do
    spawn(session_uri, adapter_id, target_id, Map.get(params, :opts, %{}))
  end

  def spawn_kind_server(params) do
    raise ArgumentError,
          "Ezagent.ExternalMirror.WorkerSpawn.spawn_kind_server/1 requires " <>
            "a map with :session_uri (URI.t), :adapter_id (binary), :target_id " <>
            "(term). Got: #{inspect(params)}"
  end

  @doc """
  Graceful unbind — terminate the PerBindingSupervisor for
  `{session_uri, adapter_id, target_id}`. PR-EM-3 calls this from
  the `:unbind` action body; PR-EM-2 includes the helper so the
  graceful-shutdown path is round-trippable in unit tests.

  Returns `:ok` on success OR if the binding is already absent
  (idempotent — same semantics as `Ezagent.Kind.terminate/1`).
  """
  @spec terminate(URI.t(), String.t(), term()) :: :ok | {:error, term()}
  def terminate(%URI{} = session_uri, adapter_id, target_id) when is_binary(adapter_id) do
    worker_uri = worker_uri_for(session_uri, adapter_id, target_id)
    terminate_by_uri(worker_uri)
  end

  @doc """
  Companion to `spawn_kind_server/1` — declared via
  `Ezagent.Entity.ExternalMirrorWorker.terminate_strategy/0`
  per the `Ezagent.Kind.terminate_strategy` callback contract.
  Called by `Ezagent.Kind.terminate/1` with the Worker URI +
  Kind.Server pid.

  Resolves the PerBindingSupervisor pid via the WorkerRegistry
  (the Kind.Server's URI is the WorkerRegistry key) and
  terminates THAT supervisor via
  `DynamicSupervisor.terminate_child(RootSupervisor, _)`. The
  `pid` arg (the Kind.Server pid) is IGNORED — the standard
  `DynamicSupervisor.terminate_child(RootSupervisor, kind_server_pid)`
  call returns `:not_found` because RootSupervisor only knows about
  PerBindingSupervisor pids, not their inner Kind.Server children.
  This is exactly the bug `terminate_strategy/0` exists to fix
  (codex round-1 HIGH-2, 2026-05-25).

  Idempotent — already-absent URI returns `:ok`.
  """
  @spec terminate_by_pid(URI.t(), pid()) :: :ok
  def terminate_by_pid(%URI{} = worker_uri, _kind_server_pid) do
    terminate_by_uri(worker_uri)
  end

  defp terminate_by_uri(%URI{} = worker_uri) do
    binding_uri = URI.to_string(worker_uri)

    case WorkerRegistry.lookup(binding_uri) do
      {:ok, sup_pid} ->
        case DynamicSupervisor.terminate_child(RootSupervisor, sup_pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          _other -> :ok
        end

      :error ->
        :ok
    end
  end

  @doc """
  Compute the canonical Worker Kind URI for
  `{session_uri, adapter_id, target_id}` per SPEC §7.2:

      entity://worker/<workspace>/em_<hash>

  where `<workspace>` is derived structurally from the session URI's
  3-segment `session://<template>/<workspace>/<name>` shape, and
  `<hash>` is the lowercase hex sha256 of
  `"<session_uri>/<adapter_id>/<target_id>"` truncated to 12
  characters (~48 bits — collision-resistant for the V1 binding
  count expectations + still short enough to read in logs).

  Stable: same `{session, adapter, target}` triple always maps to
  the same Worker URI (so eager-spawn + restart land at the same
  URI, the Registry key uniqueness check works, idempotency holds).
  """
  @spec worker_uri_for(URI.t(), String.t(), term()) :: URI.t()
  def worker_uri_for(%URI{scheme: "session"} = session_uri, adapter_id, target_id)
      when is_binary(adapter_id) do
    workspace = Ezagent.URI.workspace_name!(session_uri)

    hash =
      :crypto.hash(
        :sha256,
        URI.to_string(session_uri) <> "/" <> adapter_id <> "/" <> stringify(target_id)
      )
      |> Base.encode16(case: :lower)
      |> String.slice(0, 12)

    Ezagent.URI.worker(workspace, "em_#{hash}")
  end

  defp stringify(term) when is_binary(term), do: term
  defp stringify(term) when is_atom(term), do: Atom.to_string(term)
  defp stringify(term) when is_integer(term), do: Integer.to_string(term)
  defp stringify(term), do: inspect(term)

  @doc false
  # Internal contract: re-export the Worker Kind module so
  # `ExternalMirrorWorker.spawn_strategy/0` can name THIS module
  # without a cyclic alias.
  def worker_kind, do: ExternalMirrorWorker
end

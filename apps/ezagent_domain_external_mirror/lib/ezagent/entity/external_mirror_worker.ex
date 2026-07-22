defmodule Ezagent.Entity.ExternalMirrorWorker do
  @moduledoc """
  `Ezagent.Entity.ExternalMirrorWorker` — the Kind hosting the
  per-binding publish loop.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §7.2 / §6.1 / §6.3.

  One Kind instance = one
  `{session_uri, adapter_id, target_id}` binding. URI shape (§7.2):

      entity://worker/<workspace>/em_<hash>

  where `<workspace>` is structurally derived from the session URI
  and `<hash>` is `sha256(session_uri/adapter_id/target_id)`
  truncated to 12 lowercase hex chars (~48 bits — see
  `Ezagent.ExternalMirror.WorkerSpawn.worker_uri_for/3`). Stable:
  same triple always maps to the same Worker URI.

  ## Supervision

  Per **`spawn_strategy/0` returning `{:custom, WorkerSpawn,
  :spawn_kind_server}`**: `Ezagent.Kind.spawn(ExternalMirrorWorker,
  params)` delegates to
  `Ezagent.ExternalMirror.WorkerSpawn.spawn_kind_server/1` which
  builds the two-tier topology:

      RootSupervisor (DynamicSupervisor, 100/60s)
       └── PerBindingSupervisor (Supervisor, 3/30s, registered via
       │   {:via, Registry, {WorkerRegistry, binding_uri}})
       │   └── Kind.Server[ExternalMirrorWorker]

  P16 (single Kind.spawn entry) is preserved — plugin code never
  sees PerBindingSupervisor directly.

  ## Behaviors

  `Ezagent.ActionSet.Identity` owns the Worker's self-license-bearing
  principal slice; `Ezagent.ActionSet.ExternalMirrorWorker` owns the
  `:external_mirror_worker` slice + the `:publish` action +
  the post-init split-init pattern (SPEC §6.1 r4 HIGH-1 deadlock
  fix): `init_slice/1` returns minimal state with
  `subscription_state: :pending`; `post_init/2` returns
  `{:continue, :subscribe_and_init}`; `handle_continue/3` runs
  AFTER `:announce_ready` and (a) subscribes to the Session
  Publisher (b) calls `binding.init/1`; only after both succeed
  does `subscription_state` become `:active`.

  ## Persistence

  `:ephemeral` for V1 — the binding contract is the Session's
  `:external_mirror` slice (SPEC §7.1, written by PR-EM-3); the
  Worker's runtime cursor + count fields are interesting for
  telemetry but don't need durable persistence (a restart resets
  the cursor to `:latest` per OQ-EM-10, by design).

  PR-EM-3 may revisit if at-least-once delivery semantics need
  cursor-checkpointing.
  """

  @behaviour Ezagent.Kind

  alias Ezagent.ExternalMirror.{RootSupervisor, WorkerSpawn}

  @impl Ezagent.Kind
  def type_name, do: :external_mirror_worker

  @impl Ezagent.Kind
  def behaviors,
    do: [Ezagent.ActionSet.Identity, Ezagent.ActionSet.ExternalMirrorWorker]

  @impl Ezagent.Kind
  def persistence, do: :ephemeral

  @doc """
  Declares the two-tier spawn strategy per SPEC §6.3.
  `Ezagent.Kind.spawn/2` reads this via `function_exported?/3` and
  routes to `WorkerSpawn.spawn_kind_server/1` which:

  1. Computes the canonical Worker URI from
     `{session_uri, adapter_id, target_id}`.
  2. Spawns a `PerBindingSupervisor` under `RootSupervisor` (with a
     `{:via, Registry, {WorkerRegistry, binding_uri}}` name for
     idempotency).
  3. The PerBindingSupervisor's `Supervisor.init/1` then spawns the
     standard `Kind.Server` child with `{ExternalMirrorWorker,
     params}` — preserving the framework's "one GenServer module
     for all Kinds" invariant (#2).
  """
  @impl Ezagent.Kind
  def spawn_strategy, do: {:custom, WorkerSpawn, :spawn_kind_server}

  @doc """
  PR-EM-2 codex round-1 HIGH-2 fix (2026-05-25): companion to
  `spawn_strategy/0`. The standard `Kind.terminate/1` path calls
  `DynamicSupervisor.terminate_child(supervisor(),
  kind_server_pid)` — that does NOT work for the two-tier
  topology because `RootSupervisor` owns the PerBindingSupervisor
  pid, NOT the Kind.Server pid. `terminate_strategy/0` declares
  the custom teardown so `Kind.terminate/1` delegates to
  `WorkerSpawn.terminate_by_pid/2` which resolves the
  PerBindingSupervisor via the Kind.Server's URI + the
  WorkerRegistry, then calls
  `DynamicSupervisor.terminate_child(RootSupervisor,
  per_binding_sup_pid)`.
  """
  @impl Ezagent.Kind
  def terminate_strategy, do: {:custom, WorkerSpawn, :terminate_by_pid}

  @doc """
  The two-tier root that owns all ExternalMirrorWorker instances.
  Read by `Ezagent.Kind.terminate/1`'s `:standard` strategy path
  (which we OVERRIDE via `terminate_strategy/0` above, but we
  still declare `supervisor/0` so framework code that asks "where
  does this Kind live?" gets the right top-level answer).
  """
  @impl Ezagent.Kind
  def supervisor, do: RootSupervisor
end

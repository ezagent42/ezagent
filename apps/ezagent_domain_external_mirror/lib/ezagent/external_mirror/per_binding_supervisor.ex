defmodule Ezagent.ExternalMirror.PerBindingSupervisor do
  @moduledoc """
  `Ezagent.ExternalMirror.PerBindingSupervisor` — one Supervisor per
  active binding; the inner tier of the two-tier topology.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §5.3 + §6.3 — r4 HIGH-2 + r5 codex round-4 HIGH-2 invariant.

  Owns exactly ONE child:
  `Ezagent.Kind.Server` running `Ezagent.Entity.ExternalMirrorWorker`
  for ONE `binding_uri`.

  ## Restart policy

  - **Supervisor itself:** `:one_for_one`, `max_restarts: 3,
    max_seconds: 30`. Tight per-binding budget: a flaky binding
    that keeps crashing exhausts this and the PerBindingSupervisor
    itself crashes (Worker child config below stays `:permanent`).
    When PerBindingSupervisor crashes, the RootSupervisor's
    `:transient` strategy + the supervisor's `:shutdown` exit
    reason controls whether it gets restarted (it does — `:exit`
    other than `:normal`/`:shutdown` is treated as crash).
  - **Worker child:** `:permanent`. Always restart on crash within
    the inner budget — that's what the per-binding budget is for.

  ## Registry-keyed name (r5 HIGH-3 fix)

  The Supervisor is started with
  `name: {:via, Registry, {WorkerRegistry, binding_uri}}` so
  concurrent `start_child` for the same `binding_uri` collide on
  the Registry and the second caller gets
  `{:error, {:already_started, pid}}` — the reconciler's
  idempotency contract (SPEC §3.1).

  `binding_uri` is the full Worker Kind URI string
  (`entity://worker/<workspace>/em_<hash>`) — cross-workspace
  bindings can't collide.

  ## Lifecycle

  Started by `Ezagent.ExternalMirror.WorkerSpawn.spawn/1` via
  `DynamicSupervisor.start_child(RootSupervisor, child_spec)`.
  Terminated by `WorkerSpawn.terminate/1` via
  `DynamicSupervisor.terminate_child(RootSupervisor, sup_pid)`
  during `:unbind`. The `:shutdown` propagates to the Worker child
  which runs `terminate/2` → calls the Binding's `terminate/2` →
  Worker exits cleanly.
  """

  use Supervisor

  alias Ezagent.ExternalMirror.WorkerRegistry

  @doc """
  Start a PerBindingSupervisor for `binding_uri`. `worker_args` is
  the params map handed verbatim to `Ezagent.Kind.Server` (must
  include `:uri` per `Kind.Server.init/1` contract; per SPEC §6.1
  also `:session_uri` + `:binding`).

  Returns:
  - `{:ok, sup_pid}` on a fresh registration.
  - `{:error, {:already_started, sup_pid}}` when the binding_uri
    is already registered in `WorkerRegistry` (concurrent spawn
    or reconciler re-attempt — the caller treats as success per
    SPEC §3.1 idempotency).
  """
  @spec start_link(%{required(:binding_uri) => String.t(), required(:worker_args) => map()}) ::
          Supervisor.on_start()
  def start_link(%{binding_uri: binding_uri, worker_args: worker_args})
      when is_binary(binding_uri) and is_map(worker_args) do
    Supervisor.start_link(__MODULE__, %{worker_args: worker_args},
      name: via_name(binding_uri)
    )
  end

  @impl Supervisor
  def init(%{worker_args: worker_args}) do
    # The ExternalMirrorWorker child wraps a Kind.Server (the
    # framework's shared GenServer that hosts every Kind) — same
    # invocation Kind.spawn/2 uses for any other Kind, but routed
    # under THIS Supervisor instead of the default
    # `Ezagent.KindSupervisor`. P16 (single Kind.Server module
    # for all Kinds) preserved.
    children = [
      worker_child_spec(worker_args)
    ]

    # SPEC §5.3 / §6.3: tight per-binding budget.
    Supervisor.init(children, strategy: :one_for_one, max_restarts: 3, max_seconds: 30)
  end

  @doc """
  Build the standard child spec for ONE
  `Ezagent.Entity.ExternalMirrorWorker` Kind under this
  PerBindingSupervisor. Exposed as a function (rather than inline
  in `init/1`) so tests can assert the shape (PR-EM-2 acceptance
  test 3 — every per-binding child IS a Kind.Server, not something
  else).
  """
  @spec worker_child_spec(map()) :: Supervisor.child_spec()
  def worker_child_spec(worker_args) when is_map(worker_args) do
    %{
      id: Ezagent.Kind.Server,
      start:
        {Ezagent.Kind.Server, :start_link,
         [{Ezagent.Entity.ExternalMirrorWorker, worker_args}]},
      restart: :permanent,
      type: :worker
    }
  end

  @doc """
  Build the via-name used to register a PerBindingSupervisor in
  `WorkerRegistry`. Exposed for tests + `WorkerSpawn.terminate/1`.
  """
  @spec via_name(binding_uri :: String.t()) :: {:via, module(), {module(), String.t()}}
  def via_name(binding_uri) when is_binary(binding_uri) do
    {:via, Registry, {WorkerRegistry, binding_uri}}
  end
end

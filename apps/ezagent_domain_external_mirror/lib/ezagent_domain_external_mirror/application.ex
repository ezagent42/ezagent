defmodule EzagentDomainExternalMirror.Application do
  @moduledoc """
  ExternalMirror Domain OTP application.

  ## PR-EM-0 scope (Publisher contract only)

  - `Ezagent.Behavior.Publisher` — the `@behaviour` contract (4
    callbacks) any publishing Kind declares it implements.
  - `Ezagent.Publisher.Event` — the typed event struct subscribers
    receive on `{:publisher_event, _}`.

  The Session-side IMPLEMENTATION (`Ezagent.Behavior.Publisher.SessionImpl`
  + the `subscribe_from/3`/`snapshot/1`/`history/3` module functions
  on `Ezagent.Entity.Session`) lives in `apps/ezagent_domain_chat/`
  (chat depends on this Domain for the contract; external_mirror
  has zero reverse references to chat). Kind ↔ Behavior registration
  for SessionImpl happens in `EzagentDomainChat.Application` (per
  the existing convention: Kind ↔ Behavior binding lives in the
  app that defines the Kind).

  ## PR-EM-1 additions (AdapterRegistry + BindingRegistry + facade)

  - `AdapterRegistry` (ETS via `EzagentCore.EtsOwner`) — adapter_id → adapter_module.
  - `BindingRegistry` (ETS via `EzagentCore.EtsOwner`) — adapter_id → binding_module.
  - `Ezagent.ExternalMirror` facade (read-only helpers; SPEC §4.4).
  - `Ezagent.Plugin` extended with `adapters/0` optional callback +
    Grill-5 compile gate + boot-time registration.

  ## PR-EM-2 additions (Worker Kind + 2-tier supervision)

  Per SPEC §6.3 (r4 HIGH-2 + r5 codex round-4 HIGH-2 + HIGH-3 fixes):

  - `Ezagent.ExternalMirror.WorkerRegistry` — `Registry` (`:unique`)
    keyed by full Worker Kind URI string. Must start BEFORE
    `RootSupervisor` so PerBindingSupervisor `:via` registrations
    succeed.
  - `Ezagent.ExternalMirror.RootSupervisor` — `DynamicSupervisor`,
    `:one_for_one`, `max_restarts: 100, max_seconds: 60`. Children
    are `PerBindingSupervisor` instances.

  ## PR-EM-3 additions (this PR — Behavior.ExternalMirror + bind/unbind)

  Per SPEC §9 PR-EM-3 + §8.2 (r6 facade) + §3.1 (rehydration):

  - `Ezagent.ExternalMirror.TargetCheckTaskSup` —
    `Task.Supervisor` for the facade's `target_ownership_check/2`
    Task. MUST start BEFORE `BootReconciler` runs (the reconciler
    doesn't use it, but the facade does and we want it ready
    immediately when application boot completes).
  - Register per-adapter cap subjects (Step 7 from PR-EM-1, deferred):
    walks every `AdapterRegistry` entry + calls
    `CapabilityRegistry.register/3` for the cap-only Behavior named
    in `adapter.cap_subject()`.
  - `Ezagent.ExternalMirror.BootReconciler` — one-shot GenServer
    that walks `external_mirror_bindings` and idempotently spawns
    Session + Worker Kinds. Application-boot safety net for the
    multi-node case (V1 single-node = no-op).

  Worker Behavior (`Ezagent.Behavior.ExternalMirrorWorker`) was
  registered on `Ezagent.Entity.ExternalMirrorWorker` in PR-EM-2.

  The bind/unbind Behavior (`Ezagent.Behavior.ExternalMirror`) is
  registered against `Ezagent.Entity.Session` from
  `EzagentDomainChat.Application` per the convention that
  Kind ↔ Behavior wiring lives in the app that DEFINES the Kind.
  """

  use Application

  require Logger

  alias Ezagent.CapabilityRegistry
  alias Ezagent.ExternalMirror.{AdapterRegistry, BootReconciler, RootSupervisor, WorkerRegistry}

  @impl true
  def start(_type, _args) do
    children = [
      # WorkerRegistry MUST start before RootSupervisor so the
      # PerBindingSupervisor's `{:via, Registry, ...}` name
      # registrations succeed.
      WorkerRegistry,
      RootSupervisor,
      # PR-EM-3: Task.Supervisor for the bind-facade's
      # target_ownership_check/2 Task. Must be alive before the
      # first `Ezagent.ExternalMirror.bind/4` call.
      {Task.Supervisor, name: Ezagent.ExternalMirror.TargetCheckTaskSup},
      # PR-EM-3: one-shot reconciliation of persisted bindings.
      # Ordered LAST so RootSupervisor + TargetCheckTaskSup are
      # alive when it runs. Exits cleanly after one pass per SPEC
      # §3.1 trigger (2).
      #
      # `restart: :transient` — `:normal` exit does NOT respawn.
      # Without this, the default `:permanent` strategy would
      # restart-loop the reconciler after every successful pass,
      # tripping the Application supervisor's intensity and
      # crashing the whole `external_mirror` app at boot.
      %{
        id: BootReconciler,
        start: {BootReconciler, :start_link, [[]]},
        restart: :transient,
        type: :worker
      }
    ]

    case Supervisor.start_link(children,
           strategy: :one_for_one,
           name: EzagentDomainExternalMirror.Supervisor
         ) do
      {:ok, sup_pid} ->
        :ok = register_worker_behavior()
        :ok = register_per_adapter_cap_subjects()
        {:ok, sup_pid}

      other ->
        other
    end
  end

  # Register the Worker Behavior's `:publish` action against the
  # Worker Kind so dispatch step 5.5 finds it. Per the SPEC §4.3
  # cap shape (Cap 3 in §7.3 table): `{kind: :external_mirror_worker,
  # behavior: ExternalMirrorWorker, instance: :any, workspace_uri: ws}`.
  defp register_worker_behavior do
    :ok =
      CapabilityRegistry.register(
        Ezagent.Entity.ExternalMirrorWorker,
        :publish,
        Ezagent.Behavior.ExternalMirrorWorker
      )

    :ok
  end

  # PR-EM-3 — completes the deferred Plugin.boot Step 7 from PR-EM-1.
  #
  # SPEC §5.1 step 7: for each declared `(adapter, binding)` pair,
  # register the per-adapter cap subject from `adapter.cap_subject()`.
  # PR-EM-1 deferred this with the comment "Step 7 (CapabilityRegistry
  # per `adapter.cap_subject()`) is DEFERRED to PR-EM-2 when
  # `Behavior.ExternalMirror` lands" — PR-EM-2 introduced the
  # Worker, not the bind/list Behavior. PR-EM-3 lands the bind
  # Behavior + completes this step.
  #
  # The per-adapter Behavior is cap-only (`dispatchable?/0 == false`)
  # — it exists ONLY to give Check 2 (per SPEC §4.2) a stable cap
  # shape. The Behavior module itself is named by `adapter.cap_subject()`
  # (typically `Ezagent.Behavior.ExternalAdapter.<id>.Allow`).
  #
  # ## Why one action atom per adapter
  #
  # `CapabilityRegistry.register/3` rejects two Behaviors registered
  # for the same `{kind, action}` (caller-bug rule). The per-adapter
  # Allow Behaviors all gate "bind THIS adapter" against the same
  # Session Kind — so we use a UNIQUE action atom per adapter:
  # `String.to_atom("allow_" <> adapter_id)`. This makes the cap
  # shape readable in `/admin/caps` (the cap subject's table shows
  # "Session allow_feishu = Behavior.ExternalAdapter.Feishu.Allow"
  # for each adapter) without action-atom collisions.
  #
  # ## Idempotency
  #
  # `CapabilityRegistry.register/3` is idempotent on
  # `(kind, action, behavior)` repeats, so reboot / hot-restart is
  # safe. Plugin uninstall isn't supported in V1.
  #
  # IMPORTANT: this registration runs AFTER Plugin.boot has already
  # populated AdapterRegistry (the umbrella starts external_mirror
  # AFTER plugin apps that depend on it — see mix.exs comments).
  # We walk the live registry rather than re-reading `Plugin.adapters/0`
  # because external_mirror has no compile-time list of which plugins
  # exist.
  defp register_per_adapter_cap_subjects do
    Enum.each(AdapterRegistry.list(), fn %{module: adapter_module, id: adapter_id} ->
      try do
        %{behavior_module: behavior_module} = adapter_module.cap_subject()
        action = String.to_atom("allow_" <> adapter_id)

        :ok =
          CapabilityRegistry.register(
            Ezagent.Entity.Session,
            action,
            behavior_module
          )
      rescue
        err ->
          Logger.warning(
            "ExternalMirror: per-adapter cap registration failed for " <>
              "#{inspect(adapter_module)}: #{inspect(err)}"
          )
      end
    end)

    :ok
  end
end

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
  alias Ezagent.ExternalMirror.{BootReconciler, FacadeNonceTable, RootSupervisor, WorkerRegistry}

  @impl true
  def start(_type, _args) do
    children = [
      # WorkerRegistry MUST start before RootSupervisor so the
      # PerBindingSupervisor's `{:via, Registry, ...}` name
      # registrations succeed.
      WorkerRegistry,
      RootSupervisor,
      # PR-EM-3 codex r3 CRIT fix (2026-05-25): protected-ETS nonce
      # table that hands a single-use unforgeable token from the
      # facade's `bind/4` (after Checks 2 + 3) to the action body's
      # `invoke(:bind, ...)`. Replaces the forgeable
      # `args[:_facade_checks_ok]` flag. Owned by the Domain
      # Application so it starts before the facade is callable.
      FacadeNonceTable,
      # PR-EM-3: Task.Supervisor for the bind-facade's
      # target_ownership_check/2 Task. Must be alive before the
      # first `Ezagent.ExternalMirror.bind/4` call.
      {Task.Supervisor, name: Ezagent.ExternalMirror.TargetCheckTaskSup},
      # PR-EM-3 + r3: one-shot reconciliation that ensures the
      # SESSION Kind exists for every persisted binding row. Worker
      # reconciliation moved to `AdapterInstall.install/1` per the
      # r2 HIGH-1 fix (event-driven on adapter register, not
      # one-shot at app boot — see AdapterInstall moduledoc). This
      # GenServer still helps ensure that Session Kinds rehydrate
      # in the rare case that the only trigger for them would be a
      # mirror Worker referencing them.
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
        # r2 HIGH-3 fix (2026-05-25): the old one-shot
        # `register_per_adapter_cap_subjects/0` walked
        # `AdapterRegistry.list/0` at app boot — but adapter plugins
        # depend on external_mirror so they boot LATER, leaving the
        # registry empty at this moment. Per-adapter cap-subject
        # registration is now event-driven inside
        # `Ezagent.ExternalMirror.AdapterRegistry.register/1`
        # (delegating to `Ezagent.ExternalMirror.AdapterInstall.install/1`).
        # Nothing for this Application to do post-boot for
        # per-adapter caps.

        # PR-CC-2b (SPEC caps-cleanup-v1 §4.3) — seed external_mirror-owned
        # system principals per §4.1 Operating context. Idempotent;
        # test-env skip.
        :ok = seed_external_mirror_system_principals()

        {:ok, sup_pid}

      other ->
        other
    end
  end

  # PR-CC-2b (SPEC caps-cleanup-v1 §4.3) — external_mirror-owned principals:
  #
  # - `system://boot-reconciler` — `BootReconciler` reconciles persisted
  #   bindings at app boot
  # - `system://adapter-install` — `AdapterInstall` installs per-adapter
  #   cap subjects against Session Kind
  # - `system://worker-publish` — `Behavior.ExternalMirrorWorker` outbound
  #   publish dispatches
  defp seed_external_mirror_system_principals do
    if test_env?() do
      :ok
    else
      Enum.each(
        [
          "system://boot-reconciler",
          "system://adapter-install",
          "system://worker-publish"
        ],
        &ensure_principal_logged/1
      )

      :ok
    end
  end

  defp ensure_principal_logged(uri_str) do
    case Ezagent.SystemPrincipal.ensure(URI.parse(uri_str)) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "EzagentDomainExternalMirror seed: ensure(#{uri_str}) failed " <>
            "(#{inspect(reason)}); idempotent retry on next boot."
        )

        :ok
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
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
end

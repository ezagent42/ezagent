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

  ## PR-EM-2 additions (this PR — Worker Kind + 2-tier supervision)

  Per SPEC §6.3 (r4 HIGH-2 + r5 codex round-4 HIGH-2 + HIGH-3 fixes):

  - `Ezagent.ExternalMirror.WorkerRegistry` — `Registry` (`:unique`)
    keyed by full Worker Kind URI string. Must start BEFORE
    `RootSupervisor` so PerBindingSupervisor `:via` registrations
    succeed.
  - `Ezagent.ExternalMirror.RootSupervisor` — `DynamicSupervisor`,
    `:one_for_one`, `max_restarts: 100, max_seconds: 60`. Children
    are `PerBindingSupervisor` instances (NOT Kind.Servers — the
    two-tier shape is the architectural invariant per acceptance
    test 3).
  - Registers the `Ezagent.Behavior.ExternalMirrorWorker` Behavior
    on `Ezagent.Entity.ExternalMirrorWorker` Kind via
    `Ezagent.CapabilityRegistry.register/3` for the `:publish`
    action.

  ## Why register here (and not in chat)

  Per the existing convention (`feedback_register_lookup_key_parity`
  / `Plugin.boot` SPEC §5.1 step 7): Kind ↔ Behavior wiring lives
  in the app that DEFINES the Kind. Both
  `Ezagent.Entity.ExternalMirrorWorker` and
  `Ezagent.Behavior.ExternalMirrorWorker` ship in
  `:ezagent_domain_external_mirror`, so registration lives here.

  PR-EM-3 will add `Ezagent.Behavior.ExternalMirror` (the bind /
  unbind / list_bindings Behavior on the Session Kind) — that
  Behavior is registered against `Ezagent.Entity.Session` from
  `EzagentDomainChat.Application` per the same convention.
  """

  use Application

  alias Ezagent.CapabilityRegistry
  alias Ezagent.ExternalMirror.{RootSupervisor, WorkerRegistry}

  @impl true
  def start(_type, _args) do
    children = [
      # WorkerRegistry MUST start before RootSupervisor so the
      # PerBindingSupervisor's `{:via, Registry, ...}` name
      # registrations succeed.
      WorkerRegistry,
      RootSupervisor
    ]

    case Supervisor.start_link(children,
           strategy: :one_for_one,
           name: EzagentDomainExternalMirror.Supervisor
         ) do
      {:ok, sup_pid} ->
        :ok = register_worker_behavior()
        {:ok, sup_pid}

      other ->
        other
    end
  end

  # Register the Worker Behavior's `:publish` action against the
  # Worker Kind so dispatch step 5.5 finds it. Per the SPEC §4.3
  # cap shape (Cap 3 in §7.3 table): `{kind: :external_mirror_worker,
  # behavior: ExternalMirrorWorker, instance: :any, workspace_uri: ws}`.
  # The matching subject is registered here; PR-EM-3 wires the
  # scope-bounded delegation cap from Session at bind time.
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

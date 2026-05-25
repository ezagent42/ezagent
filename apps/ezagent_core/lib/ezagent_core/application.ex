defmodule EzagentCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # ① ETS tables — must be ready before any process that reads/writes them
      # (KindRegistry, Idempotency.Sweeper, plugin Kind instances).
      # See DECISIONS impl-time §ETS+Application children.
      EzagentCore.EtsOwner,

      # ② stdlib Registry for URI → pid (Ezagent.KindRegistry wraps this).
      {Registry, keys: :unique, name: Ezagent.KindRegistry},

      # ③ Idempotency LRU prune — its own GenServer so a crash doesn't
      # take the ETS owner with it.
      Ezagent.Idempotency.Sweeper,

      # ③·5 Plugin RegistrationHooks (SPEC
      # docs/superpowers/specs/2026-05-25-external-mirror-auth-model-audit.md §5)
      # — backing GenServer for `Ezagent.Plugin.publish_after_all_registered/2`,
      # the cross-registry "wait for both/all populated" hook primitive.
      # Started BEFORE any plugin boots (plugin boots run via each plugin's
      # OTP Application — those start AFTER ezagent_core via umbrella mix
      # deps). First consumer: ExternalMirror's AdapterInstall.
      Ezagent.Plugin.RegistrationHooks,

      # ④ SQLite repo + migrations (Phase 0 baseline).
      EzagentCore.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ezagent_core, :ecto_repos),
       skip: EzagentCore.MigrationGate.skip?()},
      {DNSCluster, query: Application.get_env(:ezagent_core, :dns_cluster_query) || :ignore},

      # ⑤ PubSub — needed by LiveView audit:stream + future view fan-outs.
      {Phoenix.PubSub, name: EzagentCore.PubSub},

      # ⑤·5 Presence (SPEC `docs/superpowers/specs/2026-05-23-presence.md`)
      # — Phoenix.Presence CRDT for cross-node entity liveness. Must run
      # AFTER PubSub (depends on it) and BEFORE any domain Application
      # that subscribes. `permdown_on_shutdown: true` makes graceful node
      # shutdown remove this node's local presences immediately; non-graceful
      # crash still leaves remote view stale for `:down_period` (~30s) per
      # SPEC §6.3 SLA.
      {Ezagent.Presence.Tracker, [pool_size: 1, permdown_on_shutdown: true]},

      # ⑥ Audit batch writer — must come after Repo + PubSub.
      Ezagent.Audit.Writer,

      # ⑥·5 Notification subscription registry (SPEC v2 PR-N1,
      # docs/superpowers/specs/2026-05-24-notification-architecture-v2.md).
      # Dedicated GenServer with `:protected` ETS — codex PR-N1
      # round-2 HIGH-1: cannot live in EtsOwner because `:public`
      # would let raw `:ets.insert` bypass cap enforcement. Writes
      # serialise through this GenServer's mailbox after cap check;
      # reads stay direct (`:ets.match/2` on `:protected` works
      # cross-process). Starts after PubSub because LV mount-time
      # re-subscriptions (PR-N2) depend on both being up.
      Ezagent.NotificationSubscriptions,

      # ⑦ Snapshot async writer (Phase 4-completion Spec 04) — handles
      # `:periodic` strategy; `:on_change` / `:on_terminate` go through
      # `Ezagent.Kind.Snapshot.save_now/3` synchronously.
      Ezagent.Snapshot.Writer,

      # ⑧ Foundation singleton supervisor — Phase 6 PR 2. Hosts core
      # singletons (System Kind sentinels + future cross-domain
      # controllers). Workspace.Supervisor moved out to
      # ezagent_domain_workspace as part of the three-layer split.
      {DynamicSupervisor, name: Ezagent.Core.SingletonSupervisor, strategy: :one_for_one},

      # ⑨ Default Kind supervisor — V1 structural prevention (Allen
      # 2026-05-21). `Ezagent.Kind.spawn/2` routes here when a Kind
      # module doesn't declare its own `supervisor/0` callback. Always
      # available so spawn calls from any plugin or domain app at boot
      # have a destination.
      Ezagent.KindSupervisor
    ]

    result = Supervisor.start_link(children, strategy: :one_for_one, name: EzagentCore.Supervisor)

    # Attach telemetry handlers after the writer is up. Idempotent on restart.
    :ok = Ezagent.Audit.attach()

    # PR #145 (SPEC v2 §5.6 §5.11) — seed the runtime URI scheme allowlist
    # BEFORE any code path that calls `Ezagent.URI.parse!/1` or
    # `Ezagent.SpawnRegistry.register/2` (which now co-registers schemes).
    # EtsOwner already created the table; this populates the 6 core schemes.
    :ok = seed_uri_schemes()

    # PR #146 (SPEC v2 §5.7) — synthetic singleton `routing-admin://default`
    # dissolved. `Ezagent.Behavior.Routing` is registered against the
    # scope-owning Kinds (Workspace + Session + System) in their respective
    # domain Applications and here for System. Global rules dispatch to
    # `system://routing/default`, spawned below.
    :ok = register_system_kind()

    # Presence SPEC `docs/superpowers/specs/2026-05-23-presence.md` §4 —
    # register the cap-only `Ezagent.Behavior.Presence` against User +
    # Agent so `Ezagent.Presence.subscribe/2` finds a coherent cap shape
    # via `CapabilityRegistry.needed_for/3`. `dispatchable?: false` keeps
    # this out of `BehaviorRegistry` — `Invocation.dispatch/1` can never
    # accidentally invoke `:online`.
    :ok = register_presence_behavior()

    # Phase 7 completion PR-3 (SPEC §1.7 (c)) — hydrate the TemplateTags
    # ETS read cache from the `template_tags` SQLite table, the
    # `Ezagent.Routing.RuleStore.load_into_registry/1` analogue. Runs
    # after the Repo + Migrator children are up (children ④); EtsOwner
    # (child ①) already created the cache table.
    :ok = Ezagent.TemplateTags.load_into_registry()

    # Post-Phase-5 (Allen 2026-05-17): start distributed Erlang as the
    # named runtime node so `mix esr` (CLI) can reach us via :rpc.call.
    # Cookie + node name from Ezagent.Runtime. Skip in test env to avoid
    # interfering with ExUnit's own process tree.
    if not is_test?() do
      :ok = Ezagent.Runtime.configure_for_runtime!()
    end

    # PR-CC-2b (SPEC caps-cleanup-v1 §4.3) — seed the operator-/UI-shaped
    # system principals whose Operating context is core (no domain owns
    # the call sites). `mix-task` is invoked from any `mix ezagent.*`
    # task; `lv-anon-mount` is invoked from LV mount paths when no
    # `current_entity_uri` is in session. Seeding here is idempotent and
    # ensures the Identity slice exists when the lazy callers fire.
    #
    # Test-env skip mirrors `EzagentDomainIdentity.maybe_seed_admin_kind_for_tests/0`
    # — tests that need these principals alive at boot must invoke
    # `SystemPrincipal.ensure/1` in setup against the Sandbox-owned repo
    # connection. Dev / prod see the seed on every boot.
    :ok = seed_core_system_principals()

    result
  end

  defp is_test? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end

  # PR #145 — seed the 6 SPEC §5.6 schemes into SchemeRegistry. Idempotent
  # (`:ets.insert/2` overwrites the same key), safe on supervisor restart.
  # Idempotent `SchemeRegistry.init/0` covers the rare case where EtsOwner
  # has not yet finished initializing on a hot path — in normal boot,
  # EtsOwner is child ① in the supervision tree so the table is ready.
  defp seed_uri_schemes do
    :ok = Ezagent.URI.SchemeRegistry.init()

    Enum.each(~w(entity workspace session template resource system), fn s ->
      :ok = Ezagent.URI.SchemeRegistry.register(s)
    end)

    :ok
  end

  # PR #146 — register Routing Behavior on the System Kind, spawn the
  # canonical global-rules sentinel `system://routing/default`, and
  # register a SpawnRegistry fn for the `system://` scheme so future
  # sentinels (`system://bootstrap/default`, `system://migration-<id>`)
  # spawn through the standard SpawnRegistry path.
  defp register_system_kind do
    alias Ezagent.Behavior.Routing, as: RB
    alias Ezagent.CapabilityRegistry
    alias Ezagent.Entity.System, as: SK

    Enum.each(RB.actions(), fn action ->
      :ok = CapabilityRegistry.register(SK, action, RB)
    end)

    :ok =
      Ezagent.SpawnRegistry.register("system", fn %URI{} = uri ->
        # V1 prevention (Allen 2026-05-21): routed through Ezagent.Kind.spawn/2.
        # System Kind declares Ezagent.Core.SingletonSupervisor via
        # supervisor/0 callback so destination is preserved.
        Ezagent.Kind.spawn(SK, %{uri: uri})
      end)

    uri = SK.routing_default_uri()

    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        case Ezagent.SpawnRegistry.spawn(uri) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          err -> err
        end
    end
  end

  # PR-CC-2b (SPEC caps-cleanup-v1 §4.3) — seed system principals whose
  # Operating context (§4.1 table) is the core application:
  #
  # - `system://mix-task` — every `mix ezagent.*` task that needs caps.
  #   No domain owns this — Mix tasks are operator entry points so the
  #   core Application is the boot home.
  #
  # Each call is idempotent; `ensure/1` is safe across application restarts.
  #
  # Boot-order note: `Ezagent.Kind.spawn(Entity.User, ...)` reads
  # `Ezagent.Entity.User.supervisor/0` which returns
  # `EzagentDomainIdentity.Application.UserSupervisor`. That supervisor
  # is started by identity's `Application.start/2` — identity boots
  # AFTER core (`ezagent_domain_identity` depends on `ezagent_core`).
  # So at this point in core's start/2, identity has NOT yet booted
  # and the supervisor is absent. We capture the error + log; lazy
  # callers re-run `ensure/1` once identity is up (`ensure/1` is
  # idempotent so the second call succeeds). Future PR may move this
  # into `Ezagent.Plugin.RegistrationHooks.publish_after_all_registered/2`
  # gated on `EzagentDomainIdentity.Application` boot completion.
  defp seed_core_system_principals do
    if is_test?() do
      :ok
    else
      ensure_principal_logged("system://mix-task")
    end
  end

  # PR-CC-2b (codex round-1 HIGH-1 fix) — `SystemPrincipal.ensure/1`
  # calls `Ezagent.Kind.spawn(Entity.User, ...)`, which reads
  # `EzagentDomainIdentity.Application.UserSupervisor` via `User.supervisor/0`.
  # That supervisor is started by identity's `Application.start/2` —
  # `ezagent_domain_identity` depends on `ezagent_core`, so identity boots
  # AFTER core. At core's seed point, `UserSupervisor` does NOT yet exist;
  # `DynamicSupervisor.start_child/2` against an absent named supervisor
  # EXITS with `:noproc`. The `case do {:ok, _} / {:error, _}` clause
  # below cannot catch an exit — without the try/catch, this kills core
  # boot. Wrap the whole call.
  #
  # The lazy callers (`mix ezagent.*` tasks) re-invoke `ensure/1` once
  # identity is up; the idempotency arm (`{:already_started, _}` /
  # `{:already_registered, _}`) makes the second call cheap.
  defp ensure_principal_logged(uri_str) do
    try do
      case Ezagent.SystemPrincipal.ensure(URI.parse(uri_str)) do
        :ok ->
          :ok

        {:error, reason} ->
          log_seed_failure(uri_str, reason)
      end
    rescue
      e ->
        log_seed_failure(uri_str, e)
    catch
      kind, reason ->
        log_seed_failure(uri_str, {kind, reason})
    end
  end

  defp log_seed_failure(uri_str, reason) do
    require Logger

    Logger.warning(
      "seed_core_system_principals: ensure(#{uri_str}) failed " <>
        "(#{inspect(reason)}); lazy caller will retry — idempotent."
    )

    :ok
  end

  defp register_presence_behavior do
    # Presence SPEC `docs/superpowers/specs/2026-05-23-presence.md` §4 —
    # register cap-only Behavior against User + Agent. CapabilityRegistry
    # handles the dispatchable?: false sentinel: subjects table gets
    # `(User|Agent, :online, Ezagent.Behavior.Presence)` entries, but
    # BehaviorRegistry is NOT touched. `Ezagent.Presence.subscribe/2`
    # uses `CapabilityRegistry.needed_for(kind, :online, uri)` to build
    # the needed-cap shape for authorization.
    alias Ezagent.Behavior.Presence, as: PB

    :ok = Ezagent.CapabilityRegistry.register(Ezagent.Entity.User, :online, PB)
    :ok = Ezagent.CapabilityRegistry.register(Ezagent.Entity.Agent, :online, PB)

    # PR-C Notifications (Allen 2026-05-23) — cap-only Behavior for
    # the unified user-notifications inbox. Registered ONLY against
    # User Kind (agents don't have an inbox; they receive via
    # chat.receive dispatch). `Ezagent.Notifications.notify/2` checks
    # `:notify` cap; `.subscribe/2` checks `:subscribe` cap.
    alias Ezagent.Behavior.Notifications, as: NB

    :ok = Ezagent.CapabilityRegistry.register(Ezagent.Entity.User, :notify, NB)
    :ok = Ezagent.CapabilityRegistry.register(Ezagent.Entity.User, :subscribe, NB)

    :ok
  end
end

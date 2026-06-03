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
      # **Skipped in :test env** (2026-05-26): the 100ms timer-driven
      # `Repo.insert_all("invocations", _)` flush is the singleton
      # GenServer that triggers SQLite "Database busy" + DBConnection
      # owner-exit interleaving against `Ecto.Adapters.SQL.Sandbox`'s
      # per-test ownership lifecycle. Test code that exercises audit
      # writes opts in via `use Ezagent.Test.AuditCase` (calls
      # `start_supervised!/1` and `Sandbox.allow/3` per-test).
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
      # **Skipped in :test env** for the same Sandbox-ownership reason
      # as ⑥; see `Ezagent.Test.AuditCase` for opt-in pattern. Most
      # tests use `:on_change` strategy so this writer is dormant; the
      # 100ms timer firing in a sandbox-rolled-back state was leaving
      # SQLite WAL locks contended for the next test's snapshot writes.
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
    |> Enum.reject(&skip_in_test_env?/1)

    result = Supervisor.start_link(children, strategy: :one_for_one, name: EzagentCore.Supervisor)

    # Attach telemetry handlers after the writer is up. Idempotent on restart.
    :ok = Ezagent.Audit.attach()

    # PR #145 (SPEC v2 §5.6 §5.11) — seed the runtime URI scheme allowlist
    # BEFORE any code path that calls `Ezagent.URI.new!/1` or
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

    # Remediation C-B (#114) — hydrate the AgentLineage ETS read cache
    # from the durable `agent_lineage` SQLite table, the
    # `Ezagent.TemplateTags.load_into_registry/0` analogue. Without this
    # the lineage `agent_uri → spawned_by` mapping is lost on every
    # restart (EtsOwner recreates the table empty), so previously-owned
    # agents become "foreign" and `{:spawned_by, P}` CapBAC matching
    # breaks. Runs after the Repo + Migrator children are up (children
    # ④); EtsOwner (child ①) already created the (empty) cache table.
    :ok = Ezagent.AgentLineage.rehydrate()

    # Post-Phase-5 (Allen 2026-05-17): start distributed Erlang as the
    # named runtime node so `mix ezagent` (CLI) can reach us via :rpc.call.
    # Cookie + node name from Ezagent.Runtime. Skip in test env to avoid
    # interfering with ExUnit's own process tree.
    if not is_test?() do
      :ok = Ezagent.Runtime.configure_for_runtime!()
    end

    result
  end

  defp is_test? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end

  # 2026-05-26 C-snapshot fix — `Ezagent.Audit.Writer` and
  # `Ezagent.Snapshot.Writer` are global singleton GenServers that
  # batch-flush to `Repo` on a 100ms timer. Against
  # `Ecto.Adapters.SQL.Sandbox`'s per-test ownership model their
  # async flush stamps over connections owned by tests that have
  # already exited, causing `Database busy` to bleed into subsequent
  # tests (seen as ~22 "baseline flakes" in `ezagent_plugin_liveview`
  # and the 4 `SnapshotTest` failures at seed 0). Test code that needs
  # to verify audit writes / periodic-snapshot writes opts in via
  # `Ezagent.Test.AuditCase`, which `start_supervised!`s the writer
  # AND `Sandbox.allow`s it onto the per-test connection.
  #
  # An invariant test (`audit_writer_test_env_isolation_test.exs`)
  # pins **both** halves: prod env children list MUST include the
  # writers, test env children list MUST NOT.
  @writers_skipped_in_test [Ezagent.Audit.Writer, Ezagent.Snapshot.Writer]

  defp skip_in_test_env?(child),
    do: is_test?() and child in @writers_skipped_in_test

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

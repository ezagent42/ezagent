defmodule EzagentCore.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # ① ETS tables — must be ready before any process that reads/writes them
        # (KindRegistry, Idempotency.Sweeper, plugin Kind instances).
        # See DECISIONS impl-time §ETS+Application children.
        EzagentCore.EtsOwner,

        # ①·5 Resource FS-resolver allowlist owner — Resource-unification SPEC
        # §5.1 (codex round-1 HIGH). Owns the `:protected`
        # `:ezagent_resource_fs_types` table (sole writer). Must start before any
        # boot-time `Ezagent.Resource.FsResolver.register_type/2`. For P0 it is
        # dormant (zero real types registered).
        Ezagent.Resource.FsResolver.Registry,

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
        Ezagent.Cap.DeliveryOutbox.Sweeper,
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

    # Resource-unification P3 (SPEC §10 OI-3) — the `system://<type>[/<name>]`
    # resolution seam for node-global artifacts (global app creds, plugin config,
    # diagnostic logs). System artifacts have no `<ws>`, but per OI-3 that is NOT
    # an exemption: they route through `UriQuery` via the already-allowlisted
    # `system://` scheme instead of `resource://`. Stateless + global, so a plain
    # UriQuery attr (no `:protected` registry — no per-type authority fn).
    :ok = Ezagent.System.FsResolver.register()

    # Resource-unification P2b — uploads are stored + read through the generic
    # `resource://` FS-resolver `uploads` type (registered immutably in
    # `Ezagent.Resource.FsResolver.Registry.boot_registrations/0`, child ①·5), so
    # `Ezagent.Uploads` no longer owns a separate `UriQuery` resolver — its old
    # boot `Ezagent.Uploads.register()` call is gone.

    # Resource-unification P0/P1/P2 — the generic `resource://` FS-resolver
    # allowlist (config-dir `<ns>-agents` types + uploads) is applied immutably
    # inside `Ezagent.Resource.FsResolver.Registry.init/1` from its
    # compile/config-time `boot_registrations/0` source (child ①·5); there is no
    # runtime registration call here (codex round-4: no externally-mutable reopen
    # window).

    # PR #146 (SPEC v2 §5.7) — synthetic singleton `routing-admin://default`
    # dissolved. `Ezagent.ActionSet.Routing` is registered against the
    # scope-owning Kinds (Workspace + Session + System) in their respective
    # domain Applications and here for System. Global rules dispatch to
    # `system://routing/default`, spawned below.
    :ok = register_system_kind()

    # #154 cleanup (2026-06-20) — register the cap-only
    # `Ezagent.ActionSet.Notifications` `:subscribe` cap against User. This
    # is the ONE live cap-only subject: `Ezagent.NotificationSubscriptions`
    # authorizes cross-entity subscribe/admin against it. `Behavior.Presence`
    # and the dead `:notify` action were deleted — presence is VM-internal
    # (lives in `Ezagent.Presence`, no cap), and nothing consumed `:notify`.
    :ok = register_notifications_behavior()

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

    # Unified-revocation Phase F-1 — warm the immutable `key_id -> public_key`
    # authority memo from the durable `kind_cap_authorities` rows (the
    # `Ezagent.AgentLineage.rehydrate/0` analogue). Optimization only: a miss
    # reads through to the DB row, and the CURRENT key_id is always read
    # fresh from the DB active row, so a skipped warm is never a stale answer.
    :ok = Ezagent.Cap.AuthorityCache.rehydrate()

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
  # tests (seen as operator UI baseline flakes and the 4 `SnapshotTest`
  # failures at seed 0). Test code that needs
  # to verify audit writes / periodic-snapshot writes opts in via
  # `Ezagent.Test.AuditCase`, which `start_supervised!`s the writer
  # AND `Sandbox.allow`s it onto the per-test connection.
  #
  # An invariant test (`audit_writer_test_env_isolation_test.exs`)
  # pins **both** halves: prod env children list MUST include the
  # writers, test env children list MUST NOT.
  @writers_skipped_in_test [
    Ezagent.Audit.Writer,
    Ezagent.Snapshot.Writer,
    Ezagent.Cap.DeliveryOutbox.Sweeper
  ]

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
    alias Ezagent.ActionSet.Routing, as: RB
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
        # derivation-edge: genesis-root system Kind has no parent
        Ezagent.Kind.spawn(SK, %{uri: uri})
      end)

    # #52 Mode-B fix (test-isolation race): in `:test`, do NOT eagerly
    # spawn `system://routing/default` at boot. The eager spawn runs
    # `Kind.Server.init/1` → a `kind_snapshots` READ (`Snapshot.load_or_init`)
    # and `persist_initial_snapshot/3` WRITE under the app supervisor tree,
    # BEFORE any test's `Ecto.Adapters.SQL.Sandbox` owner exists. With no
    # allowed process in manual mode that DB work raises
    # `DBConnection.OwnershipError` — today silently rescued by
    # `StateRebuilder.snapshot_exists?/1` / `persist_initial_snapshot`
    # (hence the green-but-noisy umbrella run) and, in the cold-restart-gate
    # tests, surfacing as flakiness (a restarted snapshot Kind reads
    # `kind_snapshots` before it registers in KindRegistry, so it can only
    # reach a connection via a foreign/reverted shared owner).
    #
    # We KEEP the Behavior registration + the `system://` SpawnRegistry fn
    # above (no DB touch); only the eager boot-spawn is deferred. Tests that
    # dispatch to / assert the routing sentinel spawn it explicitly inside a
    # checked-out test (greppable: `routing_default_uri`). This mirrors the
    # existing `@writers_skipped_in_test` precedent (Audit/Snapshot writers).
    if is_test?() do
      :ok
    else
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
  end

  defp register_notifications_behavior do
    # PR-C Notifications (Allen 2026-05-23) — cap-only Behavior for the
    # unified user-notifications inbox. Registered ONLY against User Kind
    # (agents don't have an inbox; they receive via chat.receive dispatch).
    # CapabilityRegistry handles the `dispatchable?: false` sentinel: the
    # subjects table gets a `(User, :subscribe, Ezagent.ActionSet.Notifications)`
    # entry, but BehaviorRegistry is NOT touched.
    #
    # #154 cleanup (2026-06-20): only `:subscribe` is registered now. It is
    # the live cap-only subject — `Ezagent.NotificationSubscriptions`
    # authorizes cross-entity subscribe/admin against it. The `:notify`
    # action was deleted: notification-push is VM-internal under #154
    # (`Ezagent.Notifications.notify/2` has no cap check), so nothing
    # consumed the `:notify` cap.
    alias Ezagent.ActionSet.Notifications, as: NB

    :ok = Ezagent.CapabilityRegistry.register(Ezagent.Entity.User, :subscribe, NB)

    :ok
  end
end

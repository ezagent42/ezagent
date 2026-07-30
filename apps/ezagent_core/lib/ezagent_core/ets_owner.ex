defmodule EzagentCore.EtsOwner do
  @moduledoc """
  EtsOwner — owns the lifecycle of ETS tables for the ETS-backed
  reliability primitives.

  Per DECISIONS implementation-decision §ETS table owner — Option B:
  one GenServer holds all tables, reducing supervisor noise and
  giving a single restart point that recreates every table together.
  Post-C5 this owner holds the CORE tables (cap spine, registries,
  plugin/query caches); the actor-framework tables (`:ezagent_ready_gate`,
  `:ezagent_pending_delivery`, `:ezagent_idempotency`,
  `:ezagent_behavior_registry`, `:ezagent_spawn_registry`,
  `:ezagent_slice_change_cursors`, scheme registry) moved to
  `EzagentActor.EtsOwner`. The stdlib `Registry` for `Ezagent.KindRegistry`
  is a child of `EzagentActor.Application` (different lifecycle shape).

  ## Boot order invariant (DECISIONS impl-time §ETS+Application children)

  This GenServer **must** start before any process that touches the
  tables — `Ezagent.KindRegistry` Registry, `Ezagent.Idempotency.Sweeper`,
  plugin Echo's default instance spawn, etc. Children order in
  `EzagentCore.Application` puts this first.

  ## Recovery semantics

  If the owner crashes, `:public` tables die with it. Supervisor
  restart recreates them empty. State stored in these tables is
  ephemeral by design (ReadyGate / PendingDelivery / Idempotency
  are all "what's in flight right now"; reset on restart is
  acceptable). Persistent state lives in Postgres via `Ezagent.Kind.Snapshot`.
  """

  use GenServer

  @tables [
    # C5 physical move (§3.2): the framework tables — `Ezagent.ReadyGate`,
    # `Ezagent.PendingDelivery`, `Ezagent.Idempotency`,
    # `Ezagent.BehaviorRegistry`, `Ezagent.SpawnRegistry`,
    # `Ezagent.SliceChange.Cursors` — moved to `EzagentActor.EtsOwner`
    # (OTP starts `ezagent_actor` before core).
    # Durable capability delivery keeps only target-presence hints in ETS so
    # ordinary Kind ready transitions avoid a cross-workspace DB query. The
    # outbox rows remain authoritative and the Sweeper rehydrates this cache.
    {Ezagent.Cap.DeliveryOutbox, :set},
    # Unified-revocation Phase F-1 (MF4): `Ezagent.Cap.AuthorityCache` memoizes
    # ONLY the immutable `key_id -> public_key` mapping — never a mutable
    # "current" pointer (the current key_id always comes fresh from the DB
    # active row), so there is no stale-cache window to invalidate.
    {Ezagent.Cap.AuthorityCache, :set},
    {Ezagent.RoutingRegistry, :set},
    {Ezagent.TemplateRegistry, :set},
    # role-as-data (SPEC §3): `Ezagent.Agent.RecipeRegistry`'s ETS cache moved to
    # `EzagentDomainAgent.EtsOwner`. The registry now resolves read-through over
    # `Ezagent.Socialware.ConfigStore` (an `ezagent_domain_identity` concern), so
    # it relocated from `ezagent_core` to `ezagent_domain_agent` (which deps
    # identity) to keep core free of any identity/ConfigStore reference — the
    # umbrella no-core→identity invariant. The table is owned there too.
    # Phase 7 PR 31 (IMPL-7-1): session→workspace back-edge for
    # Ezagent.ActionSet.Session.invoke(:send) to plumb workspace_uri into
    # Resolver. See WorkspaceRegistry moduledoc.
    {Ezagent.WorkspaceRegistry, :set},
    # Phase 7 PR 40: agent spawn lineage for {:spawned_by, _} cap
    # shape (Decision #137 / PR 42). Ezagent.Entity.Agent.spawn/4
    # records here; CapBAC step 5.5 (future PR 46+) reads here.
    {Ezagent.AgentLineage, :set},
    # PR #149 (SPEC v2 §5.14): `Ezagent.AgentTypeRegistry` deleted.
    # Agent flavor is now a free-form prefix on the URI's name segment
    # (`entity://agent/<flavor>_<name>`); the AgentTemplate that
    # instantiated the agent is the authoritative source for the
    # backing kind_module. The chat plugin's `entity://` SpawnRegistry
    # fn looks up kind_module from snapshot first, AgentTemplate
    # second — no per-flavor lookup table needed.
    # PR #145 (SPEC v2 §5.6 §5.11): the runtime ETS allowlist of URI
    # schemes (`{Ezagent.URI.SchemeRegistry, :set}`) moved to
    # `EzagentActor.EtsOwner` in the C5 atomic scheme-registry commit —
    # module, table, and the 6-scheme boot seed travel together (§3.2);
    # OTP starts `ezagent_actor` before core, so the seed precedes any
    # core `Ezagent.URI.new!/1`.
    # Plugin authoring contract PR-1 (SPEC
    # docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md):
    # - PluginRegistry §4 — runtime catalog of installed plugins;
    #   each plugin self-registers during `Ezagent.Plugin.boot/1`.
    {Ezagent.PluginRegistry, :set},
    # Unify URI Query PR-A: attr → resolver function dispatcher. Domain
    # and plugin owners register query resolvers at boot; core callers use
    # `Ezagent.UriQuery.resolve/2` without depending on downstream apps.
    {Ezagent.UriQuery, :set},
    # Phase 7 completion PR-3 (SPEC §1.7 (c)): TemplateTags read cache.
    # `Ezagent.TemplateTags` persists `(workspace, name, tag) → hash`
    # rows in Postgres (the CAS source of truth) and mirrors them into
    # this ETS table for O(1) `resolve/3`/`list/1` reads — the
    # `Ezagent.Routing.RuleStore` pattern.
    {Ezagent.TemplateTags, :set},
    # CapabilityRegistry (SPEC docs/superpowers/specs/2026-05-23-capability-registry.md):
    # `:ezagent_capability_subjects` — keyed by `{kind, behavior, action}` →
    # `%{description, dispatchable?}`. Non-bypassable cap-subject truth table;
    # populated by each Application's `start/2` via
    # `Ezagent.CapabilityRegistry.register/3` (which ALSO writes to
    # `Ezagent.BehaviorRegistry` for dispatchable subjects).
    {Ezagent.CapabilityRegistry.Subjects, :set},
    # `:ezagent_capability_default_grants` — keyed by `kind` → grant_fn.
    # Populated via `Ezagent.CapabilityRegistry.register_default_grant/2`.
    {Ezagent.CapabilityRegistry.Defaults, :set},
    # ExternalMirror Domain PR-EM-1 (SPEC
    # docs/superpowers/specs/2026-05-24-external-mirror-domain.md §5.2):
    # AdapterRegistry — `adapter_id` (string) → `adapter_module`
    # (atom). Populated at plugin boot from `adapters/0` via
    # `Ezagent.Plugin.boot/1`. Per P22 the table lives here (NOT
    # lazy-init in the Domain) so plugin authors cannot bypass it.
    #
    # KEYED BY LITERAL TABLE NAME (not by module) because the owning
    # modules live downstream of `ezagent_core` in
    # `ezagent_domain_external_mirror` — at this app's test/boot time
    # those modules may not be on the codepath. The literal atom
    # keeps the table-creation contract decoupled from the consumer
    # module. The owning module's `table/0` returns the same atom for
    # consistency (single source of truth).
    {:literal, :ezagent_external_mirror_adapter_registry, :set},
    # BindingRegistry — `adapter_id` (string) → `binding_module`
    # (atom). Grill-5 one-to-one reverse lookup; populated alongside
    # AdapterRegistry at plugin boot. Used by Worker `:publish`
    # dispatch (PR-EM-2) to reach the Binding's `publish/2` callback.
    {:literal, :ezagent_external_mirror_binding_registry, :set},
    # Notification SPEC v2 PR-N3 codex r2 HIGH-1 fix (Allen 2026-05-25):
    # `:ezagent_slice_change_cursors` — moved to `EzagentActor.EtsOwner`
    # with `Ezagent.SliceChange` in the C5 physical move (the owning module
    # is framework).
    # Plugin-package (Q1-C): runtime catalog of unpacked plugin packages —
    # slug → %{manifest, app, ebin, priv_dir, modules}. Populated by
    # `Ezagent.PluginPackage.install/1`, reduced by `unload/1`. Owned here
    # (same crash-recovery + boot-order discipline as the other registries)
    # so the unload path can reverse a hot-load without re-reading the
    # plugin module (which may have been purged).
    {:literal, :ezagent_plugin_asset_registry, :set},
    {:literal, :ezagent_plugin_package_registry, :set}
    # Notification SPEC v2 PR-N1 (Allen 2026-05-24):
    # `:ezagent_notification_subscriptions` is INTENTIONALLY NOT
    # owned here. Codex PR-N1 round-2 HIGH-1: this is a
    # security-gated registry where `:public` would let any process
    # bypass cap enforcement via raw `:ets.insert`. It's owned by
    # its own GenServer (`Ezagent.NotificationSubscriptions`) which
    # creates a `:protected` table; writes serialise through the
    # GenServer mailbox after `check_subscribe_cap/2` + admin-cap
    # verification. Read path (`:ets.match/2`) stays direct.
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    table_names =
      Enum.map(@tables, fn
        # Downstream-app table: keyed by literal atom (the owning
        # module isn't on this app's codepath at boot — see the
        # `:literal` notes in the @tables list).
        {:literal, name, type} ->
          :ets.new(name, [type, :public, :named_table, read_concurrency: true])
          name

        # Core-owned table: ask the owning module for its table name
        # (single source of truth via `mod.table/0`).
        {mod, type} ->
          name = mod.table()
          :ets.new(name, [type, :public, :named_table, read_concurrency: true])
          name
      end)

    :ok = EzagentCore.EtsReadiness.ready(self())
    {:ok, %{tables: table_names}}
  end

  @doc false
  def subscribe_lifecycle(pid \\ self()) when is_pid(pid) do
    case EzagentCore.EtsReadiness.subscribe(pid) do
      {:ok, _owner, _generation} -> :ok
    end
  end

  @doc false
  # Test-only recreation of THIS owner's `Ezagent.CapabilityRegistry.Subjects`
  # table, run from within this owner's own process so the recreated
  # table's real ETS ownership stays correctly tied to this GenServer.
  #
  # Root-cause note (provider-connection suite-health P0, 2026-07): this
  # function used to ALSO reach across and recreate
  # `Ezagent.BehaviorRegistry`'s table — a table owned by
  # `EzagentActor.EtsOwner`, not this process. Doing that `:ets.new` from
  # here silently reassigned the table's real owner to THIS process, so a
  # later genuine crash of `EzagentCore.EtsOwner` destroyed
  # `BehaviorRegistry`'s table too — permanently, since it isn't in this
  # module's `@tables` list and would never be recreated on restart. That
  # deterministically crash-looped `Ezagent.ProviderConnection.RegistryOwner`
  # (ArgumentError on every reconcile attempt against the missing table)
  # until the whole domain Application died. Callers that need to
  # simulate a full capability-table wipe must call BOTH this function
  # AND `EzagentActor.EtsOwner.recreate_capability_tables_for_test/0` —
  # each recreates only the table(s) it actually owns.
  def recreate_capability_tables_for_test do
    GenServer.call(__MODULE__, :recreate_capability_tables_for_test)
  end

  @impl true
  def handle_call(:recreate_capability_tables_for_test, _from, state) do
    if Mix.env() == :test do
      recreate_table(Ezagent.CapabilityRegistry.Subjects.table())

      :ok = EzagentCore.EtsReadiness.ready(self())

      {:reply, :ok, state}
    else
      {:reply, {:error, :test_only}, state}
    end
  end

  # PRIVATE and reachable ONLY through the `Mix.env() == :test`-gated
  # `handle_call` above. Codex review (PR #1628) round 1 caught an earlier
  # version of this fix that shared this body publicly via
  # `EzagentActor.EtsOwner.recreate_table/1` — a public, unguarded function
  # is callable by ANY caller in ANY env, and the calling process becomes
  # the table's real ETS owner if the table is absent, reopening the exact
  # bug class this PR fixes. Kept as a duplicate (not shared) per that
  # review's explicit guidance — see the `cross_file_duplicate_fn_groups`
  # cap-bump note in `arch_baseline_manifest.exs`.
  defp recreate_table(table) do
    if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    :ets.new(table, [:set, :public, :named_table, read_concurrency: true])
  end
end

defmodule EzagentCore.EtsOwner do
  @moduledoc """
  EtsOwner — owns the lifecycle of ETS tables for the ETS-backed
  reliability primitives.

  Per DECISIONS implementation-decision §ETS table owner — Option B:
  one GenServer holds all tables, reducing supervisor noise and
  giving a single restart point that recreates every table together.
  Phase 1 owns: `:ezagent_ready_gate`, `:ezagent_pending_delivery`,
  `:ezagent_idempotency`, `:ezagent_behavior_registry`. The stdlib `Registry`
  for `Ezagent.KindRegistry` is its own supervisor child (different
  lifecycle shape).

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
  acceptable). Persistent state lives in SQLite via `Ezagent.Kind.Snapshot`.
  """

  use GenServer

  @tables [
    {Ezagent.ReadyGate, :set},
    {Ezagent.PendingDelivery, :set},
    {Ezagent.Idempotency, :set},
    {Ezagent.BehaviorRegistry, :set},
    {Ezagent.RoutingRegistry, :set},
    {Ezagent.SpawnRegistry, :set},
    {Ezagent.TemplateRegistry, :set},
    # Phase 7 PR 31 (IMPL-7-1): session→workspace back-edge for
    # Ezagent.Behavior.Chat.invoke(:send) to plumb workspace_uri into
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
    # PR #145 (SPEC v2 §5.6 §5.11): runtime ETS allowlist of URI schemes
    # accepted by `Ezagent.URI.parse!/1`. Seeded at boot with the 6 core
    # schemes; plugins extend it ONLY via `Ezagent.SpawnRegistry.register/2`
    # (which co-registers). Eliminates the hardcoded `@known_schemes`
    # drift bug.
    {Ezagent.URI.SchemeRegistry, :set},
    # Plugin authoring contract PR-1 (SPEC
    # docs/superpowers/specs/2026-05-22-plugin-authoring-contract.md):
    # - PluginRegistry §4 — runtime catalog of installed plugins;
    #   each plugin self-registers during `Ezagent.Plugin.boot/1`.
    # - AgentFlavorRegistry §6.3 — declarative flavor→{kind,
    #   template_class} map; populated by `boot/1` per `agent_flavors/0`.
    {Ezagent.PluginRegistry, :set},
    {Ezagent.AgentFlavorRegistry, :set},
    # Phase 7 completion PR-3 (SPEC §1.7 (c)): TemplateTags read cache.
    # `Ezagent.TemplateTags` persists `(workspace, name, tag) → hash`
    # rows in SQLite (the CAS source of truth) and mirrors them into
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
    {Ezagent.CapabilityRegistry.Defaults, :set}
  ]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    Enum.each(@tables, fn {mod, type} ->
      :ets.new(mod.table(), [type, :public, :named_table, read_concurrency: true])
    end)

    {:ok, %{tables: Enum.map(@tables, fn {mod, _} -> mod.table() end)}}
  end
end

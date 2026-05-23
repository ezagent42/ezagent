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

      # ④ SQLite repo + migrations (Phase 0 baseline).
      EzagentCore.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:ezagent_core, :ecto_repos),
       skip: EzagentCore.MigrationGate.skip?()},
      {DNSCluster, query: Application.get_env(:ezagent_core, :dns_cluster_query) || :ignore},

      # ⑤ PubSub — needed by LiveView audit:stream + future view fan-outs.
      {Phoenix.PubSub, name: EzagentCore.PubSub},

      # ⑥ Audit batch writer — must come after Repo + PubSub.
      Ezagent.Audit.Writer,

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
    alias Ezagent.BehaviorRegistry
    alias Ezagent.Behavior.Routing, as: RB
    alias Ezagent.Entity.System, as: SK

    Enum.each(RB.actions(), fn action ->
      :ok = BehaviorRegistry.register(SK, action, RB)
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
end

defmodule Ezagent.Behavior.Routing do
  @moduledoc """
  Routing Behavior — routing rule mutations on a **scope-owning Kind**.

  PR #146 (SPEC v2 §5.7) generalization of the previous
  `Ezagent.Behavior.RoutingAdmin`. The synthetic `routing-admin://default`
  singleton Kind is dissolved; this Behavior is registered on the
  three scope classes that own routing rules:

  - `Ezagent.Entity.Workspace` — `workspace://<name>` rules
  - `Ezagent.Entity.Session`   — `session://<name>` rules
  - `Ezagent.Entity.System`    — `system://routing/default` (global)

  ## Actions

  - `:add_rule` — args `%{table: atom, matcher_json: map, receivers: [String]}`
    → returns `%{id: integer}`. The dispatch target URI's instance is
    read in the handler and recorded as the rule's `workspace_uri` when
    the target scheme is `workspace://`; for `session://` and
    `system://` the rule is unscoped at the workspace dimension (rules
    apply by virtue of being installed; session/global semantics
    live in the matcher/receiver shape itself).
  - `:delete_rule` — args `%{table: atom, id: integer}` → `:ok`
    (refuses system_default).
  - `:disable_rule` — args `%{table: atom, id: integer}` → `:ok`.
  - `:enable_rule` — args `%{table: atom, id: integer}` → `:ok`.

  Wraps `Ezagent.Routing.RuleStore` + automatically calls
  `RuleStore.load_into_registry(table)` after each mutation so the live
  `RoutingRegistry` ETS reflects the change immediately.

  ## Cap check

  Cap check fires at dispatch step 5.5 against the **target URI's
  scope** (the scope-owning Kind):

  - For `workspace://X` targets: cap needed `kind: :workspace,
    behavior: Ezagent.Behavior.Routing, instance: <workspace uri>`.
  - For `session://default/team-alpha/Y` targets: cap needed `kind: :session,
    behavior: Ezagent.Behavior.Routing, instance: <session uri>`.
  - For `system://routing/default` targets: cap needed `kind: :system,
    behavior: Ezagent.Behavior.Routing, instance: <system uri>`.

  Admin's triple-`:any` cap satisfies all three; non-admins need an
  explicit grant per scope they want to mutate.

  ## Slice

  Trivial counter (`%{calls: 0}`). Snapshot intentionally not declared
  here — each scope-owning Kind's own `persistence/0` decides what
  survives restart. The routing counter is incidental state.

  ## Migration to §2.2 declarative contract (Phase 2.5 — 2026-05-28)

  Per SPEC `2026-05-28-router-behavior-kind-architecture.md` §6.2,
  migrated from `@behaviour Ezagent.Behavior` + `invoke/4` to
  `use Ezagent.Behavior` + `action/3` + `handle_<action>/2`.

  The `RuleStore.add/5` + `RuleStore.load_into_registry/1` calls stay
  in the handler body — they are SYNCHRONOUS database operations
  whose return values gate the action result (`row.id` is part of the
  return). Expressing these as `{:dispatch, ...}` / `{:effect, ...}`
  is not possible: the new contract's effect grammar discards effect
  return values, so a RuleStore operation that produces an id usable
  by the caller must remain inline (matches the chat reference
  Behavior's "result-dependent in-handler dispatches stay direct"
  pattern). The slice counter bump moves to a `{:set, :calls, ...}`
  effect.

  `workspace_scoped?/0 == false` preserved: the system-routing
  dispatch target (`system://routing/default`) is cross-workspace by
  nature; dispatching routing rules to a `workspace://` or
  `session://` target stays workspace-scoped via the target URI shape.

  ## Migration to `use Ezagent.Lifecycle` (Phase B — 2026-05-29)

  State-only Behavior: the slice is a trivial `:calls` counter — no
  PIDs/refs/handles, so there are NO transients. `init_slice/1` →
  `create/1` (the persistent `%{calls: 0}` builder); `activate/2` is the
  macro's no-op default. The slice key auto-derives to `:routing`
  (module last segment), matching the previous explicit `state_slice/0`,
  so no `state_slice:` override is needed. Handlers are byte-identical
  except `ctx[:read]` → `ctx.read`. The synchronous `RuleStore` calls
  stay inline (their return values gate the action result).
  """

  use Ezagent.Lifecycle

  alias Ezagent.Routing.{Matcher, RuleStore}

  action(:add_rule,
    args: %{table: :atom, matcher_json: :map, receivers: {:list, :string}},
    returns: %{id: :integer},
    caps: [:add_rule],
    modes: [:call],
    description: "add a routing rule to this scope's rule store"
  )

  action(:delete_rule,
    args: %{table: :atom, id: :integer},
    returns: %{deleted: :integer},
    caps: [:delete_rule],
    modes: [:call],
    description: "delete a routing rule from this scope's rule store"
  )

  action(:disable_rule,
    args: %{table: :atom, id: :integer},
    returns: %{disabled: :integer},
    caps: [:disable_rule],
    modes: [:call],
    description: "disable an existing routing rule without removing it"
  )

  action(:enable_rule,
    args: %{table: :atom, id: :integer},
    returns: %{enabled: :integer},
    caps: [:enable_rule],
    modes: [:call],
    description: "re-enable a previously disabled routing rule"
  )

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Routing is registered on System + Workspace + Session — kind axis is
  # `:any` per check 11(b)'s multi-Kind escape. The macro-derived default
  # already yields `:any`, but we keep the explicit override so a future
  # macro default change can't silently widen the cap shape. workspace_scoped?
  # = false: the system-routing dispatch target (system://routing/default)
  # is cross-workspace by nature.
  @doc "Cap map for the rule-CRUD actions (add/delete/disable/enable_rule), pinned to `kind: :any` (Routing is multi-Kind: it backs both per-session routing and the global `system://routing/default`)."
  def required_caps do
    %{
      add_rule: Ezagent.Capability.cap(:any, __MODULE__, :add_rule),
      delete_rule: Ezagent.Capability.cap(:any, __MODULE__, :delete_rule),
      disable_rule: Ezagent.Capability.cap(:any, __MODULE__, :disable_rule),
      enable_rule: Ezagent.Capability.cap(:any, __MODULE__, :enable_rule)
    }
  end

  @doc "`false` — the system-routing target (`system://routing/default`) is cross-workspace by nature, so the rule caps are not workspace-scoped."
  def workspace_scoped?, do: false

  # State-only: persistent `:calls` counter, no transients. Slice key
  # auto-derives to `:routing` (module last segment).
  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{calls: 0}}

  @doc "Add a routing rule (`matcher_json` → `receivers`) to `table`: parse the matcher, persist via `RuleStore.add/5` (stamping `created_by` for per-scope ownership/idempotent reconcile), reload the registry, and bump the `:calls` counter. Returns `%{id: row.id}`."
  def handle_add_rule(args, ctx) do
    %{table: table, matcher_json: matcher_json, receivers: receivers} = args
    opts = build_add_opts(args, ctx)
    # `created_by` is the rule's per-scope owner identity (used by
    # `find_by_identity/4` for idempotent reconcile + by per-session
    # snapshot/prune scoping). A programmatic caller may stamp it via
    # `args.opts[:created_by]` (e.g. the orchestrator tools stamp
    # `created_by = session_uri`, matching PR-7 `install_one_rule`); when
    # absent it stays `nil` (admin-LV / system-default rows).
    created_by = Keyword.get(opts, :created_by)
    prev_calls = ctx.read.(:calls, 0)

    with {:ok, matcher} <- Matcher.from_json(matcher_json),
         {:ok, row} <- RuleStore.add(table, matcher, receivers, created_by, opts),
         :ok <- RuleStore.load_into_registry(table) do
      {:ok, %{id: row.id}, [{:set, :calls, prev_calls + 1}]}
    else
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  @doc "Permanently delete routing rule `id` from `table` (via `RuleStore.delete/1`), reload the registry, and bump `:calls`. Returns `%{deleted: id}`."
  def handle_delete_rule(%{id: id} = args, ctx) when is_integer(id) do
    table = Map.fetch!(args, :table)
    prev_calls = ctx.read.(:calls, 0)

    case RuleStore.delete(id) do
      :ok ->
        :ok = RuleStore.load_into_registry(table)
        {:ok, %{deleted: id}, [{:set, :calls, prev_calls + 1}]}

      err ->
        err
    end
  end

  @doc "Disable (soft-off, retained) routing rule `id` in `table` (via `RuleStore.disable/1`), reload the registry, and bump `:calls`. Returns `%{disabled: id}`."
  def handle_disable_rule(%{id: id} = args, ctx) when is_integer(id) do
    table = Map.fetch!(args, :table)
    prev_calls = ctx.read.(:calls, 0)

    case RuleStore.disable(id) do
      :ok ->
        :ok = RuleStore.load_into_registry(table)
        {:ok, %{disabled: id}, [{:set, :calls, prev_calls + 1}]}

      err ->
        err
    end
  end

  @doc "Re-enable a disabled routing rule `id` in `table` (via `RuleStore.enable/1`), reload the registry, and bump `:calls`. Returns `%{enabled: id}`."
  def handle_enable_rule(%{id: id} = args, ctx) when is_integer(id) do
    table = Map.fetch!(args, :table)
    prev_calls = ctx.read.(:calls, 0)

    case RuleStore.enable(id) do
      :ok ->
        :ok = RuleStore.load_into_registry(table)
        {:ok, %{enabled: id}, [{:set, :calls, prev_calls + 1}]}

      err ->
        err
    end
  end

  # Build RuleStore.add/5 opts, populating `workspace_uri` when the
  # dispatch target scheme is `workspace://`. Caller can override via
  # explicit `opts` arg if needed (programmatic callers).
  #
  # `ctx.self_uri` is the URI of the scope-owning Kind instance the
  # Behavior is invoked against (injected by `Kind.Runtime` step 5);
  # for `workspace://X?action=routing.add_rule` it is `workspace://X`.
  defp build_add_opts(args, ctx) do
    explicit_opts = Map.get(args, :opts, [])

    case Keyword.fetch(explicit_opts, :workspace_uri) do
      {:ok, _} ->
        explicit_opts

      :error ->
        case Map.get(ctx, :self_uri) do
          %URI{scheme: "workspace"} = wuri ->
            Keyword.put(explicit_opts, :workspace_uri, wuri)

          _ ->
            explicit_opts
        end
    end
  end

  # PR-OWN-4 round-3 (codex round-2 HIGH fix): Routing covers BOTH
  # workspace-scoped routing tables AND the global
  # `system://routing/default` sentinel. The latter affects all
  # tenants — only bootstrap admin should grant. The former is
  # workspace-admin-grantable.
  #
  # Differentiator: `Capability.workspace_of/1` on the instance.
  # Workspace-scoped instances (`session://`, `workspace://`,
  # `entity://`) return a concrete `%URI{}`. Global system
  # instances (`system://routing/default`) return `:any` — those
  # require bootstrap admin per the `:no_owner` branch.
  @doc "Cap data-owner for a Routing instance: a workspace-scoped instance (`session://`/`workspace://`/`entity://`) resolves to `:any` (in-scope holders qualify); the global `system://routing/default` resolves to `:no_owner`, so editing system rules requires the bootstrap-admin cap."
  def data_owner(%URI{} = instance) do
    case Ezagent.Capability.workspace_of(instance) do
      %URI{} -> :any
      :any -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end

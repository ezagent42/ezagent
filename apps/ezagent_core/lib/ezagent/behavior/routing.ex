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
    read in `invoke/4` and recorded as the rule's `workspace_uri` when
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
  - For `session://default/team-alpha/Y` targets: cap needed `kind: :session, behavior:
    Ezagent.Behavior.Routing, instance: <session uri>`.
  - For `system://routing/default` targets: cap needed `kind: :system,
    behavior: Ezagent.Behavior.Routing, instance: <system uri>`.

  Admin's triple-`:any` cap satisfies all three; non-admins need an
  explicit grant per scope they want to mutate.

  ## Slice

  Trivial counter (`%{calls: 0}`). Snapshot intentionally not declared
  here — each scope-owning Kind's own `persistence/0` decides what
  survives restart. The routing counter is incidental state.
  """

  @behaviour Ezagent.Behavior

  alias Ezagent.Routing.{Matcher, RuleStore}

  @impl Ezagent.Behavior
  def actions, do: [:add_rule, :delete_rule, :disable_rule, :enable_rule]

  @impl Ezagent.Behavior
  def cap_subjects do
    [
      {:add_rule, "add a routing rule to this scope's rule store"},
      {:delete_rule, "delete a routing rule from this scope's rule store"},
      {:disable_rule, "disable an existing routing rule without removing it"},
      {:enable_rule, "re-enable a previously disabled routing rule"}
    ]
  end

  @impl Ezagent.Behavior
  def state_slice, do: :routing

  @impl Ezagent.Behavior
  def init_slice(_args), do: %{calls: 0}

  @impl Ezagent.Behavior
  def invoke(:add_rule, slice, args, ctx) do
    %{table: table, matcher_json: matcher_json, receivers: receivers} = args
    opts = build_add_opts(args, ctx)

    with {:ok, matcher} <- Matcher.from_json(matcher_json),
         {:ok, row} <- RuleStore.add(table, matcher, receivers, nil, opts) do
      :ok = RuleStore.load_into_registry(table)
      {:ok, bump(slice), %{id: row.id}}
    else
      {:error, _} = err -> err
      err -> {:error, err}
    end
  end

  def invoke(:delete_rule, slice, %{id: id} = args, _ctx) when is_integer(id) do
    table = Map.fetch!(args, :table)

    case RuleStore.delete(id) do
      :ok ->
        :ok = RuleStore.load_into_registry(table)
        {:ok, bump(slice), %{deleted: id}}

      err ->
        err
    end
  end

  def invoke(:disable_rule, slice, %{id: id} = args, _ctx) when is_integer(id) do
    table = Map.fetch!(args, :table)

    case RuleStore.disable(id) do
      :ok ->
        :ok = RuleStore.load_into_registry(table)
        {:ok, bump(slice), %{disabled: id}}

      err ->
        err
    end
  end

  def invoke(:enable_rule, slice, %{id: id} = args, _ctx) when is_integer(id) do
    table = Map.fetch!(args, :table)

    case RuleStore.enable(id) do
      :ok ->
        :ok = RuleStore.load_into_registry(table)
        {:ok, bump(slice), %{enabled: id}}

      err ->
        err
    end
  end

  # Defensive — when Routing is registered on a Kind that does NOT
  # declare it in `behaviors/0` (Session + Workspace per SPEC v2 §5.7
  # register Routing after-the-fact via `BehaviorRegistry.register/3`),
  # `Snapshot.init_fresh/2` skips `init_slice/1` and the runtime hands
  # us an empty slice (`%{}` via `Map.get(state, slice_key, %{})` in
  # `Kind.Runtime.handle_dispatch/4`). The original `%{slice | calls:
  # ...}` form crashes on missing key. Lazy-seed the counter so the
  # Behavior is correct for any Kind it's registered against.
  defp bump(slice), do: Map.update(slice, :calls, 1, &(&1 + 1))

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

  @impl Ezagent.Behavior
  def interface do
    %{
      add_rule: %{
        description: "Add a routing rule to a table and reload the live registry",
        args: %{table: :atom, matcher_json: :map, receivers: {:list, :string}},
        returns: %{id: :integer},
        modes: [:call]
      },
      delete_rule: %{
        description: "Delete a routing rule by id and reload the live registry",
        args: %{table: :atom, id: :integer},
        returns: %{deleted: :integer},
        modes: [:call]
      },
      disable_rule: %{
        description: "Disable a routing rule by id and reload the live registry",
        args: %{table: :atom, id: :integer},
        returns: %{disabled: :integer},
        modes: [:call]
      },
      enable_rule: %{
        description: "Enable a routing rule by id and reload the live registry",
        args: %{table: :atom, id: :integer},
        returns: %{enabled: :integer},
        modes: [:call]
      }
    }
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
  @impl Ezagent.Behavior
  def data_owner(%URI{} = instance) do
    case Ezagent.Capability.workspace_of(instance) do
      %URI{} -> :any
      :any -> :no_owner
    end
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end

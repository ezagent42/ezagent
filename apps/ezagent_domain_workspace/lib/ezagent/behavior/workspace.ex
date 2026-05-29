defmodule Ezagent.Behavior.Workspace do
  @moduledoc """
  Workspace Behavior — declarative cluster-shape state for the
  Workspace Kind (Phase 4 D3/D5).

  ## SPEC 2026-05-28 (PR #445) Router/Behavior/Kind migration

  This Behavior is migrated to the new `use Ezagent.Behavior` per-action
  declarative contract (Phase 2-c). The semantic surface (action names,
  args/returns, slice shape, cap subjects, cross-domain dispatch) is
  identical to the pre-migration legacy `@behaviour Ezagent.Behavior`
  module. The wire-level changes are:

    - `actions/0`, `interface/0`, `cap_subjects/0`, `required_caps/0`
      are derived by `@before_compile` from per-action `action :name`
      declarations.
    - Each legacy per-action `invoke` clause was replaced by
      `def handle_action(args, ctx)`. The slice is read via
      `ctx[:read].(:key, default)` and mutated via `{:set, :key, value}`
      effects (the runtime's `apply_effects/2` applies them BEFORE any
      downstream `:dispatch` / `:notify` / `:emit`).
    - `state_slice/0`, `init_slice/1`, and `data_owner/1` remain as
      regular functions (the macro does not redeclare them).
    - Cross-domain interactions remain expressed as either:
      * inline `Ezagent.Router.dispatch/1` when the handler needs
        the return value before continuing (e.g. `resolve_source_config_dir/2` —
        was the legacy Invocation entry-point pre-2026-05-29
        dispatch_returning SPEC; swapped to Router because the `with`
        chain's per-flavor error mapping happens INSIDE the handler
        body, not in downstream effects),
      * inline facade calls when the handler needs a structured return
        (e.g. `EzagentDomainChat.create_session/3` in `:create_session`),
      * `{:dispatch, %Ezagent.Cmd{...}}` effects when the side-effect
        is fire-and-forget AFTER the slice mutation is committed
        (e.g. the post-add-member `:create_session` cap grant),
      * `{:dispatch_returning, %Ezagent.Cmd{...}, bind_as: name}` effects
        when downstream effects need the dispatch return value via
        `{:ref, name, [path]}`.

  ## State slice (`:workspace`)

      %{
        members: MapSet.t(URI.t()),
        # session templates: name → %{members: [URI], routing_rules: [map]}
        session_templates: %{String.t() => map()},
        routing_rules: [map()]
      }

  ## Actions

  - `:list_members` — `{:ok, %{members: [URI]}, []}`
  - `:add_member` — args `%{member: URI}` → `{:set, :members, MapSet}` + grant-cap dispatch
  - `:remove_member` — args `%{member: URI}` → `{:set, :members, MapSet}`
  - `:list_templates` — `{:ok, %{templates: map()}, []}`
  - `:add_template` — args `%{name: String, template: map}` → `{:set, :session_templates, map}`
  - `:remove_template` — args `%{name: String}` → `{:set, :session_templates, map}`
  - `:list_routing_rules` — `{:ok, %{rules: [map]}, []}`
  - `:set_routing_rules` — args `%{rules: [map]}` → `{:set, :routing_rules, list}`
  - `:instantiate` — returns the children list this Workspace declares:
    `{:ok, %{children: [...]}, []}`. The caller (Phase 4c `Ezagent.Workspace.Loader`)
    walks the list and spawns each via plugin-registered spawn functions.
  - `:create_agent` — unified CLI/LV agent provisioning (SPEC 2026-05-25)
  - `:create_session` — unified CLI/LV session provisioning (SPEC 2026-05-26)
  - `:remove_cross_prefix_members` — atomic cleanup of legacy cross-prefix
    members (task #55 codex r2 HIGH-2)

  ## Why `:instantiate` returns data, not side-effects

  Plugin isolation: `ezagent_core` does not know which plugin owns which
  Kind's supervisor. The Workspace Kind itself stays plugin-agnostic
  by returning the declared shape; the Loader injects the spawn
  policy (DI at the boundary, per the north star).
  """

  use Ezagent.Behavior

  # ---------------------------------------------------------------
  # Action declarations (SPEC §4.3 — per-action grammar)
  # ---------------------------------------------------------------
  #
  # `description` doubles as the cap subject string consumed by
  # `cap_subjects/0` (derived by `@before_compile`). Format matches
  # the pre-migration `cap_subjects/0` returns verbatim.
  #
  # The `caps:` axis defaults to `[action_name]`; the legacy
  # `required_caps/0` derivation uses the first cap atom and the
  # Behavior module to build the `Ezagent.Capability.cap/3` shape —
  # which is identical to the pre-migration explicit construction
  # (`Ezagent.Capability.cap(:workspace, __MODULE__, :action)`).
  # The `:any` kind axis at the `cap/3` level is fine because
  # `Ezagent.Kind.Runtime.resolve_required_cap/4` substitutes the
  # actual Kind's `type_name/0` at dispatch time.

  action :list_members,
    args: %{},
    returns: %{members: {:list, :uri}},
    caps: [:list_members],
    modes: [:call],
    description: "list members (user URIs) of this workspace"

  action :add_member,
    args: %{member: :uri},
    returns: %{},
    caps: [:add_member],
    modes: [:cast, :call],
    description: "add a user URI to this workspace's member set"

  action :remove_member,
    args: %{member: :uri},
    returns: %{},
    caps: [:remove_member],
    modes: [:cast, :call],
    description: "remove a user URI from this workspace's member set"

  action :list_templates,
    args: %{},
    returns: %{templates: :map},
    caps: [:list_templates],
    modes: [:call],
    description: "list templates (SessionTemplate / AgentTemplate) bound to this workspace"

  action :add_template,
    args: %{name: :string, template: :map},
    returns: %{},
    caps: [:add_template],
    modes: [:cast, :call],
    description: "bind a template version to this workspace"

  action :remove_template,
    args: %{name: :string},
    returns: %{},
    caps: [:remove_template],
    modes: [:cast, :call],
    description: "unbind a template from this workspace"

  action :list_routing_rules,
    args: %{},
    returns: %{rules: {:list, :map}},
    caps: [:list_routing_rules],
    modes: [:call],
    description: "list workspace-scoped routing rules"

  action :set_routing_rules,
    args: %{rules: {:list, :map}},
    returns: %{},
    caps: [:set_routing_rules],
    modes: [:cast, :call],
    description: "replace the workspace's routing rule set"

  action :instantiate,
    args: %{},
    returns: %{children: {:list, :tuple}},
    caps: [:instantiate],
    modes: [:call],
    description: "instantiate a fresh workspace from a workspace template"

  action :create_agent,
    args: %{
      flavor: :string,
      name: :string,
      cwd: :string,
      with_pty: :boolean,
      from: {:option, :uri}
    },
    returns: %{agent_uri: :uri, template_name: :string},
    caps: [:create_agent],
    modes: [:call],
    description:
      "create a new agent in this workspace (registers Template Class, " <>
        "spawns Agent Kind, starts PTY for cc / echo-with-PTY)"

  action :create_session,
    args: %{short_name: :string, template_name: :string},
    returns: %{
      session_uri: :uri,
      orchestrator_uri: {:option, :uri},
      orchestrator_status: :atom,
      orchestrator_error: {:option, :string}
    },
    caps: [:create_session],
    modes: [:call],
    description:
      "create a new session in this workspace + auto-spawn the " <>
        "orchestrator agent owned by the caller (SPEC " <>
        "2026-05-26-session-create-orchestrator-unified Gap C)"

  action :remove_cross_prefix_members,
    args: %{},
    returns: %{removed: {:list, :uri}, kept_count: :integer},
    caps: [:remove_cross_prefix_members],
    modes: [:call],
    description:
      "atomically strip members whose URI workspace segment doesn't " <>
        "match this workspace (task #55 codex r2 HIGH-2 cleanup)"

  # ---------------------------------------------------------------
  # State slice machinery (unchanged from legacy contract — the macro
  # does not redeclare these)
  # ---------------------------------------------------------------

  def state_slice, do: :workspace

  def init_slice(args) do
    %{
      members: read_members(args),
      session_templates: Map.get(args, :session_templates, %{}),
      routing_rules: Map.get(args, :routing_rules, [])
    }
  end

  defp read_members(args) do
    case Map.get(args, :members) do
      nil -> MapSet.new()
      %MapSet{} = set -> set
      list when is_list(list) -> MapSet.new(list)
    end
  end

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): workspace-scoped
  # Behavior — workspace admin grants. `:any` return signals
  # "class-wide cap, grantable by workspace admin via §5.2 admin branch".
  def data_owner(_), do: :any

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Workspace is registered on the Workspace Kind only — kind axis is
  # `:workspace`. The new `use Ezagent.Behavior` macro derives a
  # legacy `required_caps/0` from `action :name, caps: [...]` decls,
  # but its derivation always emits the `:any` kind axis (the macro
  # cannot know the Behavior's intended Kind binding from the action
  # declaration alone). We override it here to preserve the
  # `:workspace` kind axis the dispatch tests + caps catalogue
  # expect. Phase 2-c migration parity.
  #
  # workspace_scoped? defaults to true (intra-workspace admin); the
  # structural ws-cap-set on `workspace://system` members bypasses
  # isolation via step 5.6.
  def required_caps do
    %{
      list_members: Ezagent.Capability.cap(:workspace, __MODULE__, :list_members),
      add_member: Ezagent.Capability.cap(:workspace, __MODULE__, :add_member),
      remove_member: Ezagent.Capability.cap(:workspace, __MODULE__, :remove_member),
      list_templates: Ezagent.Capability.cap(:workspace, __MODULE__, :list_templates),
      add_template: Ezagent.Capability.cap(:workspace, __MODULE__, :add_template),
      remove_template: Ezagent.Capability.cap(:workspace, __MODULE__, :remove_template),
      list_routing_rules:
        Ezagent.Capability.cap(:workspace, __MODULE__, :list_routing_rules),
      set_routing_rules: Ezagent.Capability.cap(:workspace, __MODULE__, :set_routing_rules),
      instantiate: Ezagent.Capability.cap(:workspace, __MODULE__, :instantiate),
      create_agent: Ezagent.Capability.cap(:workspace, __MODULE__, :create_agent),
      # SPEC `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
      # Gap C — workspace-scoped session creation. Invariant #2: cap
      # subject uses MODULE reference (`__MODULE__`), not atom shorthand.
      create_session:
        Ezagent.Capability.cap(:workspace, __MODULE__, :create_session),
      # Task #55 round-2 codex HIGH-2 — admin-only cleanup. The mix
      # task dispatches under `system://workspace-loader` so the system
      # principal's caps satisfy this; no operator-facing entry point
      # holds it.
      remove_cross_prefix_members:
        Ezagent.Capability.cap(:workspace, __MODULE__, :remove_cross_prefix_members)
    }
  end

  # ---------------------------------------------------------------
  # Handlers (new-contract — `handle_<action>(args, ctx)`)
  # ---------------------------------------------------------------
  # Each handler reads the slice via `ctx[:read].(:key, default)` and
  # returns `{:ok, result, effects}` where `effects` is a list of
  # `{:set, key, value}` / `{:dispatch, %Cmd{}}` / `{:emit, ...}` /
  # etc.

  # --- members ---------------------------------------------------------

  def handle_list_members(_args, ctx) do
    members = ctx[:read].(:members, MapSet.new())
    {:ok, %{members: MapSet.to_list(members)}, []}
  end

  def handle_add_member(%{member: %URI{} = uri}, ctx) do
    # Task #55 (Allen 2026-05-27) — workspace prefix invariant. The
    # workspace's member set MAY ONLY contain entities whose URI prefix
    # matches the workspace. `entity://user/<workspace>/...` OR
    # `entity://agent/<workspace>/...`. A member URI like
    # `entity://user/system/linyilun` is REJECTED inside `h2oslabs`
    # because the URI's workspace segment (`system`) doesn't match the
    # workspace name (`h2oslabs`).
    #
    # Order (composed across PR #419 task #46 + PR #417 task #55):
    #   1. validate prefix invariant (rejected URI never persists, ever)
    #   2. ensure member's Kind is spawned (so grant_cap doesn't race
    #      KindRegistry registration — PR #419 task #46 fix)
    #   3. compute new member set (committed via `:set` effect)
    #   4. grant `:create_session` cap to the new member (via `:dispatch`
    #      effect — runs AFTER the slice mutation per apply_effects order)
    workspace_uri = Map.get(ctx, :self_uri)
    members = ctx[:read].(:members, MapSet.new())

    with :ok <- validate_member_prefix(uri, workspace_uri),
         :ok <- ensure_member_kind_spawned(uri) do
      new_members = MapSet.put(members, uri)

      effects =
        [{:set, :members, new_members}] ++
          grant_member_create_session_cap_effects(workspace_uri, uri)

      {:ok, %{}, effects}
    end
  end

  # Task #55 — workspace prefix validator. Confirms the member URI's
  # workspace segment matches the workspace URI's host. Non-entity
  # members are rejected outright — `system://`/`workspace://`/
  # `session://` URIs have no business in a workspace's member set
  # (membership models "who lives in this workspace", and only
  # entities live).
  #
  # When `workspace_uri` is missing (`ctx.self_uri == nil`), we let it
  # through to preserve the existing test surface for unit tests that
  # drive the handler directly with an empty ctx. The structural call
  # site (`Ezagent.Kind.Server`) always populates `self_uri`, so
  # production paths get the check; tests that intentionally want to
  # bypass it can keep ctx empty.
  #
  # Task #55 round-2 codex HIGH-1 (2026-05-27) — canonicalize via
  # `Ezagent.URI.parse!/1` + `Ezagent.URI.instance/1` to reject ALL
  # non-canonical shapes that the pre-fix `String.split(rest, "/",
  # parts: 2)` accepted as a side-effect of the `parts: 2` limit:
  #
  #   - `entity://user/ws/name/extra` (4-segment — parts=2 globbed
  #     "name/extra" into entity_name)
  #   - `entity://user/ws/name/` (trailing slash — same glob)
  #   - `entity://user/ws/alice?action=x` (query string — not stripped)
  #   - `entity://something/ws/name` (no host allowlist on user|agent)
  #
  # `Ezagent.URI.parse!/1` enforces the 3-segment shape + scheme
  # registry; `Ezagent.URI.instance/1` strips query + fragment.
  # Together they fully canonicalize before the prefix comparison.
  defp validate_member_prefix(_member_uri, nil), do: :ok

  defp validate_member_prefix(
         %URI{scheme: "entity"} = member_uri,
         %URI{scheme: "workspace", host: workspace_name} = workspace_uri
       )
       when is_binary(workspace_name) and workspace_name != "" do
    # Task #55 round-2 codex r2 review HIGH-1 follow-up — explicitly
    # reject query + fragment on the ORIGINAL member URI. Pre-fix
    # `Ezagent.URI.parse!/1` accepts URIs with query strings (they're
    # not malformed per the parser); `instance/1` strips them for the
    # workspace-prefix check, so a same-workspace URI with a query
    # passed the prefix gate AND landed durable in the slice/Store
    # with its query attached. Member URIs are identities — they must
    # be in instance form (no query, no fragment) to participate in
    # the structural invariants.
    cond do
      member_uri.query != nil ->
        {:error, {:bad_member_uri, member_uri}}

      member_uri.fragment != nil ->
        {:error, {:bad_member_uri, member_uri}}

      true ->
        validate_member_prefix_canonical(member_uri, workspace_uri, workspace_name)
    end
  end

  defp validate_member_prefix(%URI{} = member_uri, %URI{} = workspace_uri) do
    # Non-entity member (system://, workspace://, …) — refuse. Only
    # `entity://user/...` / `entity://agent/...` are valid workspace
    # members per the prefix invariant.
    {:error, {:non_entity_member, member_uri, workspace_uri}}
  end

  defp validate_member_prefix_canonical(member_uri, workspace_uri, workspace_name) do
    with {:ok, canonical} <- canonicalize_entity_uri(member_uri),
         %URI{host: host, path: "/" <> rest} = canonical,
         true <- host in ["user", "agent"] or {:bad_host, host} do
      # parse!/instance guarantees rest splits cleanly into [ws, name].
      case String.split(rest, "/") do
        [^workspace_name, entity_name] when entity_name != "" ->
          :ok

        [_other_workspace, _entity_name] ->
          {:error, {:cross_workspace_member_not_permitted, member_uri, workspace_uri}}

        _ ->
          # Defense in depth — `Ezagent.URI.parse!/1` already rejects
          # non-3-segment forms, so this branch is structurally
          # unreachable in production. Kept so a future change to
          # `parse!/1` can't silently widen acceptance.
          {:error, {:bad_member_uri, member_uri}}
      end
    else
      {:bad_host, _host} ->
        # `entity://something_weird/ws/name` — host axis must be
        # exactly `user` or `agent` (the two allowed entity types
        # per SPEC v3 §3). Anything else is malformed.
        {:error, {:bad_member_uri, member_uri}}

      {:error, _} = err ->
        err
    end
  end

  # Canonicalize via `Ezagent.URI.parse!/1` (3-segment shape gate +
  # scheme registry) and `Ezagent.URI.instance/1` (strip query +
  # fragment). A `parse!`-rejecting URI (4-segment, trailing slash,
  # missing workspace) raises ArgumentError → we catch and return
  # `{:bad_member_uri, ...}` so the caller gets a structured error
  # instead of a crash.
  defp canonicalize_entity_uri(%URI{} = member_uri) do
    canonical =
      member_uri
      |> URI.to_string()
      |> Ezagent.URI.parse!()
      |> Ezagent.URI.instance()

    {:ok, canonical}
  rescue
    ArgumentError ->
      {:error, {:bad_member_uri, member_uri}}
  end

  # Task #46 (Allen 2026-05-27) — pre-spawn the member's User Kind so
  # the `identity.grant_cap` dispatch in `grant_member_create_session_cap_effects/2`
  # doesn't race the `KindRegistry` registration. Idempotent: an
  # already-alive Kind returns `{:ok, _pid}` (no-op).
  #
  # Only user URIs are pre-spawned — agents don't drive `:create_session`
  # so the grant skips them, and agent lifecycle is owned elsewhere
  # (Template Class spawn, LV agent creation).
  #
  # `:no_spawn_fn` tolerance — unit tests that drive the handler directly
  # (without booting the chat plugin) have no `entity://` spawn fn
  # registered. Treating that as `:ok` keeps the unit-test surface
  # working; production never reaches this branch because
  # `EzagentDomainChat.Application.start/2` registers the `entity://`
  # spawn fn before any workspace dispatch can fire.
  defp ensure_member_kind_spawned(%URI{scheme: "entity", host: "user"} = uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, _pid} ->
        :ok

      {:error, {:no_spawn_fn, _scheme}} ->
        :ok

      {:error, reason} ->
        {:error, {:member_user_spawn_failed, uri, reason}}
    end
  end

  defp ensure_member_kind_spawned(_other), do: :ok

  def handle_remove_member(%{member: %URI{} = uri}, ctx) do
    members = ctx[:read].(:members, MapSet.new())
    {:ok, %{}, [{:set, :members, MapSet.delete(members, uri)}]}
  end

  # Task #55 round-2 codex HIGH-2 (2026-05-27) — dispatch-owned cleanup
  # of legacy cross-prefix members. Replaces the mix task's prior
  # direct-Store mutation pattern (which had race + stale-slice
  # issues; see `Mix.Tasks.Ezagent.Workspace.CleanupCrossPrefixMembers`
  # moduledoc).
  #
  # Acts ATOMICALLY against the live slice — classifies via the same
  # canonicalization rules the `:add_member` validator uses, returns
  # the kept set + list of removed URIs. The facade then persists the
  # kept set via the standard `Store.update_members/2` write so DB +
  # slice stay aligned.
  #
  # Why one action (not per-violator `:remove_member` dispatches)?
  #
  #   Per-violator dispatch would NOT be atomic w.r.t. concurrent
  #   `:add_member` calls: a legitimate add interleaved between
  #   violator dispatches would either be silently dropped (if it
  #   targeted a violator we're about to remove — unlikely but
  #   possible) or persisted out of order. One action body that runs
  #   under the Kind GenServer's serialized message queue makes the
  #   classify-then-mutate sequence single-threaded.
  def handle_remove_cross_prefix_members(_args, ctx) do
    workspace_uri = Map.get(ctx, :self_uri)
    members = ctx[:read].(:members, MapSet.new())

    case workspace_uri do
      %URI{scheme: "workspace", host: workspace_name}
      when is_binary(workspace_name) and workspace_name != "" ->
        {violators, kept} =
          members
          |> MapSet.to_list()
          |> Enum.split_with(&cross_prefix_violator?(&1, workspace_name))

        {:ok, %{removed: violators, kept_count: length(kept)},
         [{:set, :members, MapSet.new(kept)}]}

      _ ->
        # Production dispatch through `Kind.Server` always populates
        # `self_uri`; test harnesses that drive the handler directly
        # without a self_uri get a structured error rather than a
        # crash.
        {:error, {:missing_self_uri, workspace_uri}}
    end
  end

  # Task #55 round-2 codex r2 review HIGH-2 follow-up — cleanup
  # classification MUST share the validator's canonicalization. A
  # member URI counts as a violator under any of:
  #
  #   - non-entity scheme (`system://`, `workspace://`, …);
  #   - entity URI with `?query` or `#fragment` set (those URIs would
  #     be rejected by `:add_member` per the HIGH-1 follow-up;
  #     classifying them as violators is the natural cleanup);
  #   - entity URI whose canonicalized workspace segment doesn't match
  #     `workspace_name`;
  #   - entity URI whose host axis isn't `user`/`agent`;
  #   - entity URI that `Ezagent.URI.parse!/1` raises on (4-segment,
  #     trailing slash, missing workspace).
  #
  # Implemented by reusing `validate_member_prefix/2` with a
  # synthesized `workspace_uri` — `:ok` means clean, any `{:error, _}`
  # means violator.
  defp cross_prefix_violator?(%URI{} = member_uri, workspace_name) do
    case validate_member_prefix(
           member_uri,
           %URI{scheme: "workspace", host: workspace_name, path: nil}
         ) do
      :ok -> false
      {:error, _} -> true
    end
  end

  defp cross_prefix_violator?(_, _), do: true

  # --- session templates ----------------------------------------------

  def handle_list_templates(_args, ctx) do
    {:ok, %{templates: ctx[:read].(:session_templates, %{})}, []}
  end

  def handle_add_template(%{name: name, template: tmpl}, ctx)
      when is_binary(name) and is_map(tmpl) do
    templates = ctx[:read].(:session_templates, %{})
    {:ok, %{}, [{:set, :session_templates, Map.put(templates, name, tmpl)}]}
  end

  def handle_remove_template(%{name: name}, ctx) when is_binary(name) do
    templates = ctx[:read].(:session_templates, %{})
    {:ok, %{}, [{:set, :session_templates, Map.delete(templates, name)}]}
  end

  # --- routing rules ---------------------------------------------------

  def handle_list_routing_rules(_args, ctx) do
    {:ok, %{rules: ctx[:read].(:routing_rules, [])}, []}
  end

  def handle_set_routing_rules(%{rules: rules}, _ctx) when is_list(rules) do
    {:ok, %{}, [{:set, :routing_rules, rules}]}
  end

  # --- create_agent (unified CLI/LV agent provisioning) ---------------
  #
  # SPEC `docs/superpowers/specs/2026-05-25-agent-create-cli-gui-parity.md`.
  # Runs inside the Workspace Kind GenServer. The handler:
  #
  #   1. coerces + validates args
  #   2. resolves the source agent's config dir (if `--from` set) via
  #      a SYNCHRONOUS `Invocation.dispatch/1` of `sandbox.read` (we
  #      need the return value to build the template, so this can't
  #      be expressed as a `:dispatch` effect).
  #   3. dispatches per-flavor to either Template Class registration
  #      (cc/echo/codex) or direct `SpawnRegistry.spawn` (curl/np/other).
  #   4. returns the slice mutation as a `:set` effect on
  #      `:session_templates` (for flavors that register a template).
  #
  # cc / echo / codex:  register a Workspace-scoped template → mutate slice →
  #             persist via Store.update_templates → call
  #             Ezagent.Workspace.Loader.invoke_template (Template Class
  #             instantiates Agent Kind + PtyServer).
  # curl / other: direct SpawnRegistry.spawn (the only allowlisted call
  #             site for `entity://agent/` URIs per the invariant test
  #             `agent_create_single_path_test.exs`).
  def handle_create_agent(args, ctx) when is_map(args) do
    raw_workspace_uri = Map.get(ctx, :self_uri)
    session_templates = ctx[:read].(:session_templates, %{})

    with {:ok, flavor, name, cwd, with_pty?, from_uri} <- coerce_create_args(args),
         :ok <- validate_flavor(flavor),
         :ok <- validate_name(name),
         :ok <- validate_cwd_for_flavor(flavor, with_pty?, cwd),
         :ok <- validate_from_for_flavor(flavor, from_uri),
         {:ok, workspace_uri} <- require_workspace_uri(raw_workspace_uri),
         workspace_name = workspace_uri.host,
         {:ok, agent_uri} <- compose_agent_uri(flavor, name, workspace_name),
         :ok <- refuse_if_exists(agent_uri),
         {:ok, source_config_dir} <- resolve_source_config_dir(from_uri, ctx) do
      do_create_agent(flavor, agent_uri, session_templates, %{
        cwd: cwd,
        with_pty?: with_pty?,
        workspace_name: workspace_name,
        workspace_uri: workspace_uri,
        source_config_dir: source_config_dir,
        # Allen 2026-05-26 (codex HIGH-1 closure) — thread the caller
        # URI through so the SpawnRegistry direct-spawn catch-all can
        # record lineage (`Ezagent.AgentLineage.record/2`) for the
        # newly-created agent.
        caller: Map.get(ctx, :caller)
      })
    end
  end

  # --- create_session (unified CLI/LV session provisioning) -----------
  #
  # SPEC `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  # Gap C. Wraps `EzagentDomainChat.create_session/3` so the CLI and LV
  # share one entry. Translates the facade's 3-tuple meta map into a
  # handler return shape with the orchestrator URI/status surfaced for
  # the caller (CLI human-readable formatter; LV flash).
  #
  # The facade call is a SYNCHRONOUS function call (not a dispatch
  # effect) because the handler needs the returned session URI to
  # build the action's return value. A `{:dispatch, %Cmd{}}` effect
  # cannot return a value to the handler — effects run AFTER the
  # handler returns. The cross-domain dispatch under test is the chat
  # plugin's own `create_session/3` machinery, which itself fires
  # downstream `:dispatch` calls to set up session participants;
  # `workspace_migration_parity_test.exs` covers that round-trip.
  #
  # Workspace authority: the action runs in the Workspace Kind, so
  # `ctx.self_uri` is the workspace URI — passed as `:workspace_uri` to
  # the facade. The caller URI is the session creator (becomes the
  # session owner_uri + receives the OrchestratorAdmin :restart cap).
  def handle_create_session(args, ctx) when is_map(args) do
    workspace_uri = Map.get(ctx, :self_uri)
    caller = Map.get(ctx, :caller)

    with {:ok, short_name, template_name} <- coerce_create_session_args(args),
         {:ok, %URI{} = workspace_uri} <- require_session_workspace_uri(workspace_uri),
         {:ok, %URI{} = caller} <- require_caller(caller),
         {:ok, facade} <- resolve_session_facade() do
      case facade.create_session(short_name, caller,
             workspace_uri: workspace_uri,
             template_name: template_name
           ) do
        {:ok, %URI{} = session_uri, meta} when is_map(meta) ->
          {:ok,
           %{
             session_uri: session_uri,
             orchestrator_uri: Map.get(meta, :orchestrator_uri),
             orchestrator_status: Map.get(meta, :orchestrator_status),
             orchestrator_error: format_orchestrator_error(Map.get(meta, :orchestrator_error))
           }, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap C — DI
  # provider lookup for the session-creation facade. `ezagent_domain_chat`
  # depends on `ezagent_domain_workspace` (workspace boots first), so a
  # compile-time alias would invert the dep graph and create a cycle.
  # Instead the facade module is looked up at runtime via the
  # application env key (default: `EzagentDomainChat`). Tests can
  # override via `Application.put_env(:ezagent_domain_workspace,
  # :session_facade, FakeFacade)` to drive `:create_session` without
  # the full chat domain.
  defp resolve_session_facade do
    facade =
      Application.get_env(:ezagent_domain_workspace, :session_facade, EzagentDomainChat)

    if Code.ensure_loaded?(facade) and function_exported?(facade, :create_session, 3) do
      {:ok, facade}
    else
      {:error, {:session_facade_unavailable, facade}}
    end
  end

  defp coerce_create_session_args(args) do
    short_name = Map.get(args, :short_name) || Map.get(args, :name)
    template_name = Map.get(args, :template_name) || Map.get(args, :template)

    cond do
      not is_binary(short_name) or short_name == "" ->
        {:error, :short_name_required}

      not is_binary(template_name) or template_name == "" ->
        {:error, :template_name_required}

      true ->
        {:ok, String.trim(short_name), String.trim(template_name)}
    end
  end

  defp require_session_workspace_uri(%URI{scheme: "workspace", host: host} = uri)
       when is_binary(host) and host != "",
       do: {:ok, uri}

  defp require_session_workspace_uri(other),
    do: {:error, {:bad_workspace_uri, other}}

  defp require_caller(%URI{} = caller), do: {:ok, caller}
  defp require_caller(other), do: {:error, {:bad_caller, other}}

  # Format the orchestrator_error term for the CLI/LV consumers.
  # `nil` (happy path) stays `nil`; non-nil gets stringified so the
  # auto-derived CLI formatter doesn't trip on opaque tuples.
  defp format_orchestrator_error(nil), do: nil
  defp format_orchestrator_error(err), do: inspect(err)

  # --- instantiate (the north-star action) -----------------------------

  def handle_instantiate(_args, ctx) do
    # Phase 4-completion: emit both member spawns and template
    # instantiations. Loader walks each child tuple and dispatches to
    # SpawnRegistry (members) or TemplateRegistry (templates).
    # Members ordered first so any Session-Template member dependencies
    # are already alive when chat/join fires.
    members = ctx[:read].(:members, MapSet.new())
    session_templates = ctx[:read].(:session_templates, %{})

    member_children =
      members
      |> Enum.map(fn %URI{} = uri -> {:member, uri} end)

    template_children =
      session_templates
      |> Enum.map(fn {tmpl_name, tmpl_data} ->
        {:template, tmpl_name, tmpl_data}
      end)

    {:ok, %{children: member_children ++ template_children}, []}
  end

  # =================================================================
  # `:create_agent` helpers (SPEC 2026-05-25-agent-create-cli-gui-parity)
  # =================================================================
  # These mirror what was previously in
  # `EzagentPluginLiveview.AgentNewLive` so the CLI and LV share one
  # code path.

  # CLI builds atom-keyed maps. The current dispatch path (local-
  # in-process for the mix task + LV) preserves atom keys end-to-end.
  defp coerce_create_args(args) do
    flavor = Map.get(args, :flavor)
    name = Map.get(args, :name)
    cwd = Map.get(args, :cwd, "")
    with_pty = Map.get(args, :with_pty, false)
    from = Map.get(args, :from)

    cond do
      not is_binary(flavor) ->
        {:error, :flavor_required}

      not is_binary(name) ->
        {:error, :name_required}

      not is_binary(cwd) ->
        {:error, {:bad_cwd, cwd}}

      not is_boolean(with_pty) ->
        {:error, {:bad_with_pty, with_pty}}

      not valid_from?(from) ->
        {:error, {:bad_from, from}}

      true ->
        {:ok, String.trim(flavor), String.trim(name), String.trim(cwd), with_pty, from}
    end
  end

  defp valid_from?(nil), do: true

  defp valid_from?(%URI{scheme: "entity", host: "agent", path: "/" <> _}), do: true

  defp valid_from?(_), do: false

  defp require_workspace_uri(%URI{scheme: "workspace", host: host} = uri)
       when is_binary(host) and host != "",
       do: {:ok, uri}

  defp require_workspace_uri(other), do: {:error, {:bad_workspace_uri, other}}

  # Flavor validation: must be registered in AgentFlavorRegistry. Empty
  # registry (test bootstrap) falls back to the well-known names so a
  # unit test that doesn't boot plugins can still drive the handler.
  defp validate_flavor(""), do: {:error, :flavor_required}

  defp validate_flavor(flavor) when is_binary(flavor) do
    case Ezagent.AgentFlavorRegistry.list_all() do
      [] ->
        if flavor in ~w(cc echo curl np codex),
          do: :ok,
          else: {:error, {:bad_flavor, flavor}}

      entries ->
        names = Enum.map(entries, fn {f, _} -> f end)

        if flavor in names,
          do: :ok,
          else: {:error, {:bad_flavor, flavor}}
    end
  end

  defp validate_name(""), do: {:error, :name_required}

  defp validate_name(name) when is_binary(name) do
    # Same regex as the LV's `validate_name/1`: alnum start, then
    # alnum + dash + underscore (URI-path-safe).
    if name =~ ~r/\A[A-Za-z0-9][A-Za-z0-9_\-]*\z/ do
      :ok
    else
      {:error, {:bad_name, name}}
    end
  end

  # cwd is required for cc, and for echo when `with_pty: true`.
  # curl + echo-without-PTY tolerate an empty cwd.
  defp validate_cwd_for_flavor("cc", _with_pty?, ""), do: {:error, :cwd_required_for_cc}
  defp validate_cwd_for_flavor("cc", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  defp validate_cwd_for_flavor("echo", true, ""), do: {:error, :cwd_required_for_echo_with_pty}
  defp validate_cwd_for_flavor("echo", true, cwd), do: validate_cwd_dir(cwd)
  defp validate_cwd_for_flavor("echo", false, _cwd), do: :ok

  defp validate_cwd_for_flavor("codex", _with_pty?, ""),
    do: {:error, :cwd_required_for_codex}

  defp validate_cwd_for_flavor("codex", _with_pty?, cwd), do: validate_cwd_dir(cwd)

  defp validate_cwd_for_flavor("curl", _with_pty?, _cwd), do: :ok
  defp validate_cwd_for_flavor(_, _, _), do: :ok

  defp validate_cwd_dir(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)

    if File.dir?(expanded) do
      :ok
    else
      {:error, {:cwd_not_a_dir, cwd}}
    end
  end

  # `--from` only meaningful for flavors that have a per-agent
  # config_dir to clone. Today that's `cc` only — echo/curl/np have no
  # CLAUDE_CONFIG_DIR concept.
  defp validate_from_for_flavor(_flavor, nil), do: :ok
  defp validate_from_for_flavor("cc", %URI{}), do: :ok

  defp validate_from_for_flavor(other_flavor, %URI{}),
    do: {:error, {:from_unsupported_for_flavor, other_flavor}}

  # Resolve the source agent's per-agent config_dir by dispatching
  # `sandbox.read` on the source URI WITH THE CALLER'S CAPS. This:
  #
  #  - Enforces `sandbox.read` on source via standard CapBAC (no new
  #    cap subject, no parallel auth path).
  #  - Returns `{:error, :source_not_found}` when the source Agent
  #    Kind isn't alive (ReadyGate :no_such_actor).
  #  - On success returns the source's `config_dir_path` (or nil if
  #    the source has no per-agent dir — e.g. an echo agent).
  #
  # ORDER MATTERS — this step is in the main `with` chain BEFORE
  # `do_create_agent`. A `{:error, _}` here short-circuits BEFORE any
  # template registration, Store write, or filesystem op.
  #
  # NOTE: this is a SYNCHRONOUS sub-dispatch — the handler's `with`
  # chain needs the return value to map per-flavor error atoms
  # (`:source_not_found`, `:source_not_readable`, etc.) BEFORE
  # `do_create_agent/4` runs. The `:dispatch_returning` effect
  # (SPEC `2026-05-29-dispatch-returning-effect.md`) binds a value
  # for DOWNSTREAM EFFECT references — it does NOT push the value
  # back into the handler's `with` chain (effects run AFTER the
  # handler returns).
  #
  # So we use `Ezagent.Router.dispatch/1` (the modern sanctioned
  # entry-point) instead of the legacy Invocation entry-point.
  # The §11 Gate 3 grep gate fires on the legacy Invocation dispatch
  # in plugin Behaviors specifically; `Router.dispatch` is the
  # public author-facing surface and is fine for this sub-dispatch
  # pattern.
  defp resolve_source_config_dir(nil, _ctx), do: {:ok, nil}

  defp resolve_source_config_dir(%URI{} = source_uri, ctx) do
    caller = Map.fetch!(ctx, :caller)
    caps = Map.fetch!(ctx, :caps)

    cmd =
      Ezagent.Cmd.new(
        source_uri,
        :read,
        %{},
        %{caller: caller, caps: caps, reply: {:caller_inbox, self()}}
      )

    case Ezagent.Router.dispatch(cmd) do
      {:ok, %{config_dir_path: path}} when is_binary(path) and path != "" ->
        {:ok, path}

      {:ok, %{config_dir_path: nil}} ->
        {:error, :source_has_no_config_dir}

      {:ok, other} ->
        {:error, {:source_read_unexpected_shape, other}}

      {:error, :unauthorized} ->
        {:error, :source_not_readable}

      {:error, :no_such_actor} ->
        {:error, :source_not_found}

      {:error, reason} ->
        {:error, {:source_read_failed, reason}}
    end
  end

  # Per SPEC v3 §3 / Phase 9 PR-2 — entity URI is
  # `entity://agent/<workspace>/<flavor>_<name>`.
  defp compose_agent_uri(flavor, name, workspace_name)
       when is_binary(flavor) and is_binary(name) and is_binary(workspace_name) do
    full = "entity://agent/#{workspace_name}/#{flavor}_#{name}"

    try do
      {:ok, Ezagent.URI.parse!(full)}
    rescue
      ArgumentError -> {:error, {:bad_uri, full}}
    end
  end

  defp refuse_if_exists(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> {:error, {:already_exists, URI.to_string(uri)}}
    end
  end

  # cc / echo / codex → register a Workspace-scoped template + persist + invoke.
  defp do_create_agent("cc", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri,
      source_config_dir: source_config_dir
    } = params

    tmpl_name = "cc.agent." <> agent_name(agent_uri)

    tmpl =
      %{
        "class" => "cc.agent",
        "agent_uri" => URI.to_string(agent_uri),
        "cwd" => Path.expand(cwd)
      }
      |> maybe_put_clone_source(source_config_dir)

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri
    )
  end

  defp do_create_agent("echo", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      with_pty?: with_pty?,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "echo.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "echo.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "with_pty" => with_pty?,
      "cwd" => if(with_pty?, do: Path.expand(cwd), else: cwd)
    }

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri
    )
  end

  defp do_create_agent("codex", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "codex.agent." <> agent_name(agent_uri)

    tmpl = %{
      "class" => "codex.agent",
      "agent_uri" => URI.to_string(agent_uri),
      "cwd" => Path.expand(cwd)
    }

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri
    )
  end

  # Any other flavor (curl / np / future) — direct SpawnRegistry.spawn.
  defp do_create_agent(_other_flavor, agent_uri, _session_templates, params) do
    case Ezagent.SpawnRegistry.spawn(agent_uri) do
      {:ok, _pid} ->
        record_creator_lineage(agent_uri, params)
        # No slice mutation (no template registered for curl/np).
        {:ok, %{agent_uri: agent_uri, template_name: nil}, []}

      {:error, {:already_started, _pid}} ->
        # Idempotent re-create — do NOT re-record lineage.
        {:ok, %{agent_uri: agent_uri, template_name: nil}, []}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  # Allen 2026-05-26 (codex HIGH-1 closure) — record `agent_uri → caller`
  # in `Ezagent.AgentLineage`. Best-effort: a missing caller (system-internal
  # spawn) leaves no lineage row.
  defp record_creator_lineage(agent_uri, params) do
    case Map.get(params, :caller) do
      %URI{} = caller ->
        Ezagent.AgentLineage.record(agent_uri, caller)

      _ ->
        :ok
    end
  end

  # `--from` cloning works by overriding the cc Template Class's
  # `claude_config_dir` field with the SOURCE agent's per-agent dir.
  defp maybe_put_clone_source(tmpl, nil), do: tmpl

  defp maybe_put_clone_source(tmpl, source_config_dir)
       when is_binary(source_config_dir) do
    Map.put(tmpl, "claude_config_dir", source_config_dir)
  end

  # Register the template in the Workspace's session_templates slice +
  # persist via Store, then call Loader.invoke_template to bring the
  # Agent Kind (+ sidecars) live.
  #
  # Codex PR #330 r1 HIGH-1 fix: if invoke_template_now fails, roll
  # back the Store write so the DB doesn't carry a template the caller
  # was told failed. Without rollback, the next boot's
  # Loader.load_all/0 would silently instantiate the failed template
  # (no CapBAC re-check, no operator visibility).
  defp register_and_invoke_template(
         session_templates,
         workspace_name,
         workspace_uri,
         tmpl_name,
         tmpl,
         agent_uri
       ) do
    new_templates = Map.put(session_templates, tmpl_name, tmpl)

    with :ok <- validate_template_class(tmpl),
         {:ok, _decoded} <-
           Ezagent.Workspace.Store.update_templates(workspace_name, new_templates),
         :ok <-
           invoke_or_rollback(
             workspace_uri,
             workspace_name,
             tmpl_name,
             session_templates
           ) do
      # On success: emit slice mutation as a `:set` effect and return
      # the template + agent URIs to the caller.
      {:ok, %{agent_uri: agent_uri, template_name: tmpl_name},
       [{:set, :session_templates, new_templates}]}
    end
  end

  # Codex PR #330 r1 HIGH-1 — call invoke_template_now; on failure,
  # roll back the Store.update_templates write so the DB matches the
  # (uncommitted) starting state.
  defp invoke_or_rollback(workspace_uri, workspace_name, tmpl_name, original_templates) do
    case invoke_template_now(workspace_uri, tmpl_name) do
      :ok ->
        :ok

      {:error, _} = err ->
        rollback_store_templates(workspace_name, original_templates, tmpl_name, err)
        err
    end
  end

  defp rollback_store_templates(workspace_name, original_templates, tmpl_name, original_err) do
    case Ezagent.Workspace.Store.update_templates(workspace_name, original_templates) do
      {:ok, _} ->
        :ok

      {:error, rollback_reason} ->
        require Logger

        Logger.error(
          "Behavior.Workspace.:create_agent: Store rollback failed for " <>
            "workspace=#{workspace_name} tmpl=#{tmpl_name}: " <>
            "#{inspect(rollback_reason)} (original error: #{inspect(original_err)})"
        )
    end
  end

  # Same validator pattern as `Ezagent.Workspace.add_template/3` uses
  # — defer to the Template Class's `validate/1` if defined.
  defp validate_template_class(tmpl) do
    case extract_class_name(tmpl) do
      nil ->
        {:error, :missing_class_field}

      class_name ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          :error ->
            {:error, {:no_template_class, class_name}}

          {:ok, class_module} ->
            if function_exported?(class_module, :validate, 1) do
              class_module.validate(tmpl)
            else
              :ok
            end
        end
    end
  end

  defp extract_class_name(%{"class" => name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(%{class: name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(_), do: nil

  defp invoke_template_now(%URI{} = workspace_uri, tmpl_name) do
    case Ezagent.Workspace.Loader.invoke_template(workspace_uri, tmpl_name) do
      {:ok, _uris} -> :ok
      # Idempotent — already running.
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end

  # Per SPEC v3 §3, entity URI path is `/<workspace>/<entity_name>`.
  defp agent_name(%URI{path: "/" <> rest}) do
    case String.split(rest, "/", parts: 2) do
      [_workspace, entity_name] -> entity_name
      [name] -> name
    end
  end

  # codex PR #408 review round-2 MED-2 — grant the workspace
  # `:create_session` cap to a newly-added user member via a
  # `{:dispatch, %Cmd{}}` effect (runs AFTER the `:set :members`
  # effect commits per apply_effects order). Skipped for agent
  # members (agents don't drive create_session).
  #
  # The effect dispatches `identity.grant_cap` against the member's
  # User Kind, carrying the `:create_session` Capability struct as
  # the cap to grant. The Cmd's ctx.reply is `:ignore`, which
  # Router.derive_mode interprets as `:cast` — the User Kind
  # buffers via `PendingDelivery` if its `ReadyGate` is still
  # `:not_ready` (the empirical Allen-observed bug; task #46's
  # actual cause). The grant lands automatically when the User
  # Kind transitions to `:ready`.
  #
  # Allen 2026-05-28 migration note: in the legacy contract this
  # was a synchronous `Invocation.dispatch/1` call inside the
  # action body, with a try/rescue + warning log around it. In the
  # new contract the dispatch is an EFFECT — apply_effects already
  # has the dispatch-failure logging path (see runtime.ex
  # `execute_dispatches/2`), so the per-call rescue + telemetry
  # would duplicate observability. Behavioural equivalent:
  # `execute_dispatches/2` aborts subsequent effects on dispatch
  # error and logs a warning, which matches the previous "log + ok"
  # semantics minus the explicit `:telemetry.execute` for the
  # `member_create_session_grant_failed` event. The telemetry
  # event remained the only test fixture flagging this branch
  # (no production consumer); if needed it can be re-added by
  # the runtime as a generic `[:ezagent, :effect_dispatch, :failed]`
  # event in a follow-up.
  #
  # KNOWN OVER-GRANT (codex PR #408 round-3 HIGH; see
  # `docs/futures/todo.md` for the full discussion + planned fix).
  defp grant_member_create_session_cap_effects(
         %URI{scheme: "workspace"} = workspace_uri,
         %URI{scheme: "entity", host: "user"} = member_uri
       ) do
    cap = %Ezagent.Capability{
      kind: :workspace,
      behavior: __MODULE__,
      action: :create_session,
      instance: workspace_uri,
      workspace_uri: workspace_uri,
      granted_by: Ezagent.SystemPrincipal.uri("template-materialize"),
      granted_at: DateTime.utc_now()
    }

    cmd = %Ezagent.Cmd{
      target: member_uri,
      action: :grant_cap,
      args: %{cap: cap},
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("template-materialize"),
        caps: Ezagent.SystemPrincipal.caps("system://template-materialize"),
        reply: :ignore
      }
    }

    [{:dispatch, cmd}]
  end

  # Non-user member (agent) or missing workspace URI — no grant.
  defp grant_member_create_session_cap_effects(_workspace_uri, _member_uri), do: []
end

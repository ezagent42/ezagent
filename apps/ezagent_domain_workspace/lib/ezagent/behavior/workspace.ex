defmodule Ezagent.ActionSet.Workspace do
  @moduledoc """
  Workspace Behavior — declarative cluster-shape state for the
  Workspace Kind (Phase 4 D3/D5).

  ## SPEC 2026-05-28 (PR #445) Router/Behavior/Kind migration

  This Behavior is migrated to the new `use Ezagent.ActionSet` per-action
  declarative contract (Phase 2-c). The semantic surface (action names,
  args/returns, slice shape, cap subjects, cross-domain dispatch) is
  identical to the pre-migration legacy `@behaviour Ezagent.ActionSet`
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
        (e.g. `EzagentDomainInstanceMessage.SessionCreator.create_session/3`
        in `:create_session`),
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
  - `:assign_role` / `:unassign_role` — cap-gated workspace responsibility
    holder validation; durable assignment + cap binding live in the facade.
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

  ## Lifecycle migration (Phase B, SPEC 2026-05-29 §5 + §9 OQ-8 — the
  ## EXTERNAL-SoT case: state reconciled from a foreign source of truth)

  Converted from `use Ezagent.ActionSet` to `use Ezagent.Lifecycle` (the
  two-container `%{state, transients}` developer API). The Workspace Kind
  is `persistence :ephemeral` (`Ezagent.Entity.Workspace`) — the
  `kind_snapshots` BLOB is NEVER the source of truth. The `workspaces`
  Postgres table (via `Ezagent.Workspace.Store`) is the SoT; the
  `Ezagent.Workspace.Loader` reads it at boot and seeds the spawn args.
  This is the legacy `:external` persistence strategy in
  `references/slice-and-snapshot.md` ("Kind's `init_slice/1` reads from a
  foreign system on every spawn").

  The natural Lifecycle split:

  - **STATE (the cluster shape):** `members`, `session_templates`,
    `routing_rules`. Built by `create/1` from the Loader-supplied args
    (the SoT, decoded from the `workspaces` row). Because the Kind is
    `:ephemeral`, no snapshot row is ever written, so the durable
    ever-created marker is never set and `create/1` runs on EVERY spawn —
    exactly the legacy "load from SoT on every spawn" semantics, preserved
    byte-for-byte from the old `init_slice/1`.
  - **TRANSIENT:** none. A Workspace holds no PID / ref / port / ETS
    handle in its slice — `:instantiate` returns child tuples as DATA for
    the Loader to spawn (plugin isolation), it does not hold child pids.

  ### SoT load happens in `create/1`, NOT a separate `activate` reconcile

  > **Deliberate deviation from SPEC §9 OQ-8 — surfaced per the
  > `ezagent-developer` "code wins, surface the discrepancy" rule.**
  > OQ-8 prescribes "reconcile from SoT in `activate`", with the stated
  > rationale "`activate` doing DB I/O on every start is acceptable — it
  > already did via `reconcile_after_load`." That rationale does NOT hold
  > for Workspace: this Kind is `:ephemeral` and NEVER had
  > `reconcile_after_load/2` — it has no snapshot to merge, so there was no
  > prior `activate`-time DB read to inherit. Its SoT load has ALWAYS been
  > `init_slice/1`-from-args, where `Ezagent.Workspace.Loader` decodes the
  > `workspaces` row and threads it into the spawn args.

  Under Lifecycle that maps cleanly to `create/1`-from-args:

  1. `create/1` loads the cluster shape from the Loader-threaded args on
     EVERY spawn. An OTP crash-restart re-threads the SAME args via the
     child spec (`Ezagent.Kind.spawn/2` stores `{kind_module, params}` and
     the Workspace Kind is a `:permanent` child of a `:one_for_one`
     DynamicSupervisor), so `create/1` rebuilds the same SoT-derived state
     on a brutal restart too. The SoT is therefore ALREADY loaded at
     `:ready` — there is nothing for a separate reconcile to add.
  2. A separate post-create reconcile would be actively HARMFUL: the
     Workspace accepts runtime mutations (`:add_member`, `:add_template`,
     `:set_routing_rules`) that write to the live slice but persist to the
     SoT via the Store on their own path. A reconcile re-reading the Store
     races those runtime dispatches and would CLOBBER a just-applied
     mutation with a stale row (a `feedback_register_lookup_key_parity`-class
     overwrite). Per `feedback_let_it_crash_no_workarounds` we do NOT add a
     clobber-prone reconcile shim — `create/1`-from-args is the single,
     correct SoT-load site.

  So Workspace is the NO-TRANSIENTS, create-from-args case (like Pty /
  example A): `create/1` builds `state` from args, `activate/2` is the
  macro-injected no-op default (omitted — nothing process-bound to rebuild,
  no reconcile to run).

  The auto-derived `state_slice/0` (last module segment `Workspace` →
  `:workspace`) equals the historical snapshot key, so NO `state_slice:`
  override is needed (SPEC §5 step 2 / §7 OQ-7).

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.ActionSet.Workspace` — a
  domain module (`apps/ezagent_domain_workspace`) naming its own domain
  concept (`Workspace`), whose actions (`list_members` / `add_member` /
  `create_session` / …) track the cluster-shape intent directly. NO
  violation; kept as-is (a rename would touch the `:workspace` snapshot
  slice key + every cap grant + every integration test reading `:workspace`
  by name for no clarity gain).
  """

  use Ezagent.Lifecycle

  alias Ezagent.ActionSet.Workspace.Members

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

  action(:list_members,
    args: %{},
    returns: %{members: {:list, :uri}},
    caps: [:list_members],
    modes: [:call],
    description: "list members (user URIs) of this workspace"
  )

  action(:add_member,
    args: %{member: :uri},
    returns: %{},
    caps: [:add_member],
    modes: [:cast, :call],
    description: "add a user URI to this workspace's member set"
  )

  action(:remove_member,
    args: %{member: :uri},
    returns: %{},
    caps: [:remove_member],
    modes: [:cast, :call],
    description: "remove a user URI from this workspace's member set"
  )

  action(:assign_role,
    args: %{responsibility: :string, holder: :uri},
    returns: %{},
    caps: [:assign_role],
    modes: [:call],
    description: "assign a principal to a workspace responsibility"
  )

  action(:unassign_role,
    args: %{responsibility: :string, holder: :uri},
    returns: %{},
    caps: [:unassign_role],
    modes: [:call],
    description: "remove a principal from a workspace responsibility"
  )

  action(:list_templates,
    args: %{},
    returns: %{templates: :map},
    caps: [:list_templates],
    modes: [:call],
    description: "list templates (SessionTemplate / AgentTemplate) bound to this workspace"
  )

  action(:list_agent_templates,
    args: %{},
    returns: %{templates: {:list, :uri}},
    caps: [:list_agent_templates],
    modes: [:call],
    description: "list AgentTemplate instances visible in this workspace"
  )

  action(:list_session_templates,
    args: %{},
    returns: %{templates: {:list, :uri}},
    caps: [:list_session_templates],
    modes: [:call],
    description: "list SessionTemplate instances visible in this workspace"
  )

  action(:write_session_templates,
    args: %{},
    returns: %{},
    caps: [:write_session_templates],
    modes: [:call],
    description: "authorize creation or publication of SessionTemplate versions in this workspace"
  )

  action(:add_template,
    args: %{name: :string, template: :map},
    returns: %{},
    caps: [:add_template],
    modes: [:cast, :call],
    description: "bind a template version to this workspace"
  )

  action(:remove_template,
    args: %{name: :string},
    returns: %{},
    caps: [:remove_template],
    modes: [:cast, :call],
    description: "unbind a template from this workspace"
  )

  action(:list_routing_rules,
    args: %{},
    returns: %{rules: {:list, :map}},
    caps: [:list_routing_rules],
    modes: [:call],
    description: "list workspace-scoped routing rules"
  )

  action(:set_routing_rules,
    args: %{rules: {:list, :map}},
    returns: %{},
    caps: [:set_routing_rules],
    modes: [:cast, :call],
    description: "replace the workspace's routing rule set"
  )

  action(:instantiate,
    args: %{},
    returns: %{children: {:list, :tuple}},
    caps: [:instantiate],
    modes: [:call],
    description: "instantiate a fresh workspace from a workspace template"
  )

  action(:create_agent,
    args: %{
      flavor: :string,
      name: :string,
      cwd: :string,
      with_pty: :boolean,
      from: {:option, :uri},
      flavor_config: {:option, :map}
    },
    returns: %{agent_uri: :uri, template_name: :string},
    caps: [:create_agent],
    modes: [:call],
    description:
      "create a new agent in this workspace (registers Template Class, " <>
        "spawns Agent Kind, starts PTY for cc / echo-with-PTY)"
  )

  action(:create_session,
    args: %{
      short_name: :string,
      template_name: :string,
      template_options: {:option, :map}
    },
    returns: %{session_uri: :uri},
    caps: [:create_session],
    modes: [:call],
    description:
      "create a new session in this workspace + auto-spawn the " <>
        "orchestrator agent owned by the caller (SPEC " <>
        "2026-05-26-session-create-orchestrator-unified Gap C)"
  )

  action(:remove_cross_prefix_members,
    args: %{},
    returns: %{removed: {:list, :uri}, kept_count: :integer},
    caps: [:remove_cross_prefix_members],
    modes: [:call],
    description:
      "atomically strip members whose URI workspace segment doesn't " <>
        "match this workspace (task #55 codex r2 HIGH-2 cleanup)"
  )

  # ---------------------------------------------------------------
  # State slice machinery (unchanged from legacy contract — the macro
  # does not redeclare these)
  # ---------------------------------------------------------------

  # The auto-derived slice key for `Ezagent.ActionSet.Workspace` is the
  # underscored last segment `Workspace` → `:workspace`, which is EXACTLY
  # the pre-Lifecycle `state_slice/0`. Snapshot-compat key preserved with
  # no explicit override (SPEC §3 / §7 OQ-7).

  # `init_slice/1` → `create/1` (SPEC §3 mapping). Build the durable
  # cluster-shape `state` from the Loader-supplied args (the decoded
  # `workspaces` SoT row). Byte-identical to the pre-Lifecycle
  # `init_slice/1` body; the macro wraps it in the two-container
  # `%{state: ..., transients: %{}}` shape. Because the Workspace Kind is
  # `:ephemeral`, the ever-created marker is never set, so `create/1` runs
  # on EVERY spawn — preserving the legacy "load from SoT on every spawn"
  # semantics.
  @impl Ezagent.Lifecycle
  def create(args) do
    {:ok,
     %{
       members: Members.read_members(args),
       session_templates: Map.get(args, :session_templates, %{}),
       routing_rules: Map.get(args, :routing_rules, [])
     }}
  end

  # NO `activate/2` override — Workspace holds no transient and its SoT
  # load lives in `create/1`-from-args (see moduledoc "SoT load happens in
  # create/1"). The macro-injected no-op `activate/2` default applies.

  # PR-OWN-4 (caps-data-ownership SPEC #306 §6): workspace-scoped
  # Behavior — workspace admin grants. `:any` return signals
  # "class-wide cap, grantable by workspace admin via §5.2 admin branch".
  @doc "`:any` for all subjects (PR-OWN-4): workspace Behavior caps are class-wide, grantable by the workspace admin via the CapBAC admin branch — not tied to a per-entity owner."
  def data_owner(_), do: :any

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Workspace is registered on the Workspace Kind only — kind axis is
  # `:workspace`. The `use Ezagent.ActionSet` engine macro (emitted under
  # `use Ezagent.Lifecycle`) derives a legacy `required_caps/0` from
  # `action :name, caps: [...]` decls, but its derivation always emits the
  # `:any` kind axis (the macro cannot know the Behavior's intended Kind
  # binding from the action declaration alone). We override it here to
  # preserve the `:workspace` kind axis the dispatch tests + caps catalogue
  # expect. Passes through the Lifecycle macro unchanged (SPEC §3 mapping
  # table). Phase 2-c migration parity.
  #
  # workspace_scoped? defaults to true (intra-workspace admin); the
  # structural ws-cap-set on `workspace://system` members bypasses
  # isolation via step 5.6.
  @doc "Cap map for every Workspace action (list/add/remove member · session-template CRUD · routing-rule list/set · instantiate · create_agent · create_session · remove_cross_prefix_members), all pinned to the `:workspace` kind axis (overriding the macro's `:any` default — Workspace registers only on the Workspace Kind)."
  def required_caps do
    %{
      list_members: Ezagent.Capability.cap(:workspace, __MODULE__, :list_members),
      add_member: Ezagent.Capability.cap(:workspace, __MODULE__, :add_member),
      remove_member: Ezagent.Capability.cap(:workspace, __MODULE__, :remove_member),
      assign_role: Ezagent.Capability.cap(:workspace, __MODULE__, :assign_role),
      unassign_role: Ezagent.Capability.cap(:workspace, __MODULE__, :unassign_role),
      list_templates: Ezagent.Capability.cap(:workspace, __MODULE__, :list_templates),
      list_agent_templates: Ezagent.Capability.cap(:workspace, __MODULE__, :list_agent_templates),
      list_session_templates:
        Ezagent.Capability.cap(:workspace, __MODULE__, :list_session_templates),
      write_session_templates:
        Ezagent.Capability.cap(:workspace, __MODULE__, :write_session_templates),
      add_template: Ezagent.Capability.cap(:workspace, __MODULE__, :add_template),
      remove_template: Ezagent.Capability.cap(:workspace, __MODULE__, :remove_template),
      list_routing_rules: Ezagent.Capability.cap(:workspace, __MODULE__, :list_routing_rules),
      set_routing_rules: Ezagent.Capability.cap(:workspace, __MODULE__, :set_routing_rules),
      instantiate: Ezagent.Capability.cap(:workspace, __MODULE__, :instantiate),
      create_agent: Ezagent.Capability.cap(:workspace, __MODULE__, :create_agent),
      # SPEC `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
      # Gap C — workspace-scoped session creation. Invariant #2: cap
      # subject uses MODULE reference (`__MODULE__`), not atom shorthand.
      create_session: Ezagent.Capability.cap(:workspace, __MODULE__, :create_session),
      # Task #55 round-2 codex HIGH-2 — admin-only cleanup. The facade
      # dispatches this under the workspace's OWN instance-scoped
      # `cap(:workspace, Workspace, :remove_cross_prefix_members)` self-authority
      # (#154 elimination of `system://workspace-loader`); no operator-facing
      # entry point holds it.
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

  @doc "List the workspace's member URIs (from the `:members` slice)."
  def handle_list_members(_args, ctx) do
    members = ctx[:read].(:members, MapSet.new())
    {:ok, %{members: MapSet.to_list(members)}, []}
  end

  @doc "Add `member` to the workspace: enforce the workspace-prefix invariant (the member's URI workspace segment must match), ensure its Kind is spawned, persist the new member set, then grant it a workspace-scoped `:create_session` cap. Rejects a cross-prefix URI before any persistence."
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

    with :ok <- Members.validate_member_prefix(uri, workspace_uri),
         :ok <- Members.ensure_member_kind_spawned(uri) do
      new_members = MapSet.put(members, uri)

      effects =
        [{:set, :members, new_members}] ++
          grant_member_create_session_cap_effects(workspace_uri, uri)

      {:ok, %{}, effects}
    end
  end

  @doc "Remove `member` from the workspace and symmetrically revoke the workspace-scoped `:create_session` cap that `add_member` granted it (matched by identity-key, so caps in other workspaces are untouched)."
  def handle_remove_member(%{member: %URI{} = uri}, ctx) do
    # SPEC §7 Part B (cap-lifecycle sweep): `:add_member` grants the
    # member a `:create_session` cap scoped to THIS workspace; pre-fix,
    # `:remove_member` left it dangling (a user demoted from
    # `workspace://system` kept create_session there). The symmetric
    # `revoke_cap` effect sweeps EXACTLY that cap — matched by 4-tuple
    # identity_key, so caps in other workspaces / unrelated caps are
    # untouched.
    workspace_uri = Map.get(ctx, :self_uri)
    members = ctx[:read].(:members, MapSet.new())

    effects =
      [{:set, :members, MapSet.delete(members, uri)}] ++
        revoke_member_create_session_cap_effects(workspace_uri, uri)

    {:ok, %{}, effects}
  end

  @doc "Validate a workspace responsibility assignment. The facade persists it and binds caps after this cap-gated action succeeds."
  def handle_assign_role(%{responsibility: responsibility, holder: %URI{} = holder}, ctx)
      when is_binary(responsibility) do
    with :ok <- validate_responsibility_name(responsibility),
         :ok <- Members.validate_member_prefix(holder, Map.get(ctx, :self_uri)) do
      {:ok, %{}, []}
    end
  end

  @doc "Validate a workspace responsibility unassignment. The facade removes durable state and revokes bundled caps after this cap-gated action succeeds."
  def handle_unassign_role(%{responsibility: responsibility, holder: %URI{} = holder}, ctx)
      when is_binary(responsibility) do
    with :ok <- validate_responsibility_name(responsibility),
         :ok <- Members.validate_member_prefix(holder, Map.get(ctx, :self_uri)) do
      {:ok, %{}, []}
    end
  end

  defp validate_responsibility_name(name) when is_binary(name) do
    if String.trim(name) == "", do: {:error, :empty_responsibility}, else: :ok
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
  @doc "Admin-only cleanup: atomically remove every member whose URI violates the workspace-prefix invariant (classified the same way `add_member` validates), keeping the rest. One serialized action (not per-violator dispatches) so it can't interleave with concurrent `add_member`. Returns the removed URIs + kept count."
  def handle_remove_cross_prefix_members(_args, ctx) do
    workspace_uri = Map.get(ctx, :self_uri)
    members = ctx[:read].(:members, MapSet.new())

    case workspace_uri do
      %URI{scheme: "workspace"} = workspace_uri ->
        workspace_name = Ezagent.URI.name!(workspace_uri)

        {violators, kept} =
          members
          |> MapSet.to_list()
          |> Enum.split_with(&Members.cross_prefix_violator?(&1, workspace_name))

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

  # --- session templates ----------------------------------------------

  @doc "List the workspace's session templates (the `:session_templates` name→template map)."
  def handle_list_templates(_args, ctx) do
    {:ok, %{templates: ctx[:read].(:session_templates, %{})}, []}
  end

  @doc false
  def handle_list_agent_templates(_args, ctx),
    do: list_template_instances(ctx, "agent_template", :agent)

  @doc false
  def handle_list_session_templates(_args, ctx),
    do: list_template_instances(ctx, "session_template", :session)

  @doc false
  def handle_write_session_templates(_args, _ctx), do: {:ok, %{}, []}

  defp list_template_instances(ctx, kind_type, uri_type) do
    workspace_uri = Map.fetch!(ctx, :self_uri)

    templates =
      workspace_uri
      |> Ezagent.Ecto.KindSnapshot.list_in_workspace()
      |> Enum.filter(&(&1.kind_type == kind_type))
      |> Enum.map(&Ezagent.URI.new!(&1.uri))
      |> Enum.filter(&Ezagent.URI.type?(&1, uri_type))
      |> Enum.sort_by(&Ezagent.URI.stable_key/1)

    {:ok, %{templates: templates}, []}
  end

  @doc "Add (or overwrite) the session template `tmpl` under `name` in the workspace's `:session_templates` map."
  def handle_add_template(%{name: name, template: tmpl}, ctx)
      when is_binary(name) and is_map(tmpl) do
    templates = ctx[:read].(:session_templates, %{})
    {:ok, %{}, [{:set, :session_templates, Map.put(templates, name, tmpl)}]}
  end

  @doc "Remove the session template named `name` from the workspace's `:session_templates` map."
  def handle_remove_template(%{name: name}, ctx) when is_binary(name) do
    templates = ctx[:read].(:session_templates, %{})
    {:ok, %{}, [{:set, :session_templates, Map.delete(templates, name)}]}
  end

  # --- routing rules ---------------------------------------------------

  @doc "List the workspace's stored routing rules (the `:routing_rules` slice)."
  def handle_list_routing_rules(_args, ctx) do
    {:ok, %{rules: ctx[:read].(:routing_rules, [])}, []}
  end

  @doc "Replace the workspace's `:routing_rules` slice wholesale with `rules`."
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
  # PR-3V (gt_1000 burn-down): the `:create_agent` provisioning machinery
  # was extracted VERBATIM to `Ezagent.ActionSet.Workspace.AgentCreate`
  # (a separate concern from the #685 member-CapBAC handlers). This engine
  # callback stays here (the runtime dispatches by module) and delegates the
  # full `with` chain body to `AgentCreate.handle_create_agent/2`.
  @doc "Provision an agent in the workspace (unified CLI/LV path): coerce/validate args, optionally read a `--from` source agent's config, and per-flavor either register a Template Class (cc/echo/codex) or directly `SpawnRegistry.spawn` (curl/np/other). Delegates the full chain to `Ezagent.ActionSet.Workspace.AgentCreate`."
  defdelegate handle_create_agent(args, ctx), to: Ezagent.ActionSet.Workspace.AgentCreate

  # --- create_session (unified CLI/LV session provisioning) -----------
  @doc "Create a session in this workspace (unified CLI/LV path): validate name/template, call the runtime-resolved session facade's `create_session/3` (synchronously, to return the session URI), and grant the caller the creator manage-cap. The caller becomes the session owner."
  def handle_create_session(args, ctx) when is_map(args) do
    workspace_uri = Map.get(ctx, :self_uri)
    caller = Map.get(ctx, :caller)

    with {:ok, short_name, template_name, template_options} <-
           coerce_create_session_args(args),
         {:ok, %URI{} = workspace_uri} <- require_session_workspace_uri(workspace_uri),
         {:ok, %URI{} = caller} <- require_caller(caller) do
      case resolve_session_class(template_name) do
        {:ok, class_name, class_module} ->
          create_session_via_class(
            class_name,
            class_module,
            short_name,
            template_options,
            workspace_uri,
            caller
          )

        :none ->
          create_session_via_facade(short_name, template_name, workspace_uri, caller)
      end
    end
  end

  # Registered `session.*` Template Classes instantiate directly; bare names
  # also try the `session.` prefix. Resolution stays runtime-only to avoid a
  # workspace -> session/plugin compile dependency.
  defp resolve_session_class(template_name) do
    [template_name, "session." <> template_name]
    |> Enum.uniq()
    |> Enum.find_value(:none, fn name ->
      if String.starts_with?(name, "session.") do
        case Ezagent.TemplateRegistry.lookup(name) do
          {:ok, module} -> {:ok, name, module}
          :error -> false
        end
      else
        false
      end
    end)
  end

  defp create_session_via_class(
         class_name,
         class_module,
         short_name,
         template_options,
         workspace_uri,
         caller
       ) do
    tmpl =
      template_options
      |> Map.drop([:class, "class", :session_name, "session_name"])
      |> Map.merge(%{"class" => class_name, "session_name" => short_name})

    # hello-A — a Template Class that exports `instantiate/4` receives the
    # dispatch CALLER (`caller: caller`) so the created session's owner is the
    # caller principal ("the caller becomes the session owner"), not a
    # hard-coded admin. Classes exporting only `instantiate/3` are unchanged.
    result =
      if function_exported?(class_module, :instantiate, 4) do
        class_module.instantiate(class_name, tmpl, workspace_uri, caller: caller)
      else
        class_module.instantiate(class_name, tmpl, workspace_uri)
      end

    case result do
      {:ok, [%URI{} = session_uri | _]} ->
        finish_class_session(session_uri, workspace_uri, caller)

      {:ok, [%URI{} = session_uri | _], meta} when is_map(meta) ->
        finish_class_session(session_uri, workspace_uri, caller)

      {:ok, _non_session} ->
        {:error, {:class_instantiated_no_session, class_name}}

      {:ok, _non_session, _meta} ->
        {:error, {:class_instantiated_no_session, class_name}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp finish_class_session(%URI{} = session_uri, %URI{} = workspace_uri, %URI{} = caller) do
    with :ok <- join_class_session_creator(session_uri, caller),
         :ok <-
           Ezagent.Workspace.grant_creator_manage_cap(
             :session,
             session_uri,
             workspace_uri,
             caller
           ),
         :ok <- trigger_socialware_install(session_uri, caller) do
      # Meta shape matches `create_session_via_facade/4`. The retired
      # `orchestrator_status: :ready` was already a misrepresentation once the
      # team materialized asynchronously, and the facade path never carried the
      # `orchestrator_*` keys at all (`create_session_dispatch_test` asserts their
      # ABSENCE) — the two create paths must not disagree on their return shape.
      {:ok, %{session_uri: session_uri}, []}
    end
  end

  defp join_class_session_creator(%URI{} = session_uri, %URI{} = caller) do
    case resolve_session_facade() do
      {:ok, facade} ->
        if function_exported?(facade, :join_session_members, 2) and
             function_exported?(facade, :grant_session_owner_membership, 2) do
          with :ok <- facade.grant_session_owner_membership(session_uri, caller) do
            facade.join_session_members(session_uri, [caller])
          end
        else
          {:error, {:session_facade_join_unavailable, facade}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp create_session_via_facade(short_name, template_name, workspace_uri, caller) do
    with {:ok, facade} <- resolve_session_facade() do
      case facade.create_session(short_name, caller,
             workspace_uri: workspace_uri,
             template_name: template_name
           ) do
        {:ok, %URI{} = session_uri, meta} when is_map(meta) ->
          with :ok <-
                 Ezagent.Workspace.grant_creator_manage_cap(
                   :session,
                   session_uri,
                   workspace_uri,
                   caller
                 ),
               :ok <- trigger_socialware_install(session_uri, caller) do
            # rev6 / #912 — the session is now durable and owner-only. Its
            # declared agent role slots are an AGENT transaction: fire it off
            # under its own supervisor and return immediately. The enqueue call
            # must first persist the recovery obligation; agent startup itself
            # remains asynchronous and never rolls the session back.
            {:ok, %{session_uri: session_uri}, []}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The session is already durable. Persisting its install obligation is part of
  # the create success boundary; executing that obligation remains asynchronous.
  defp trigger_socialware_install(%URI{} = session_uri, %URI{} = actor_uri) do
    with {:ok, facade} <- resolve_session_facade(),
         true <- function_exported?(facade, :install_session_socialware_async, 1) do
      case facade.install_session_socialware_async({session_uri, actor_uri}) do
        :ok -> :ok
        {:error, _reason} = error -> error
        other -> {:error, {:unexpected_socialware_install_enqueue_result, other}}
      end
    else
      other ->
        require Logger

        Logger.error(
          "post-create socialware install NOT fired for #{URI.to_string(session_uri)}: " <>
            "#{inspect(other)} — the session is alive but owner-only; its declared role " <>
            "members will never materialize."
        )

        :telemetry.execute(
          [:ezagent, :session, :socialware_install, :not_fired],
          %{count: 1},
          %{session_uri: session_uri, reason: other}
        )

        {:error, {:socialware_install_not_persisted, other}}
    end
  end

  # Runtime DI avoids reversing the workspace <- session dependency.
  defp resolve_session_facade do
    facade =
      Application.get_env(
        :ezagent_domain_workspace,
        :session_facade,
        EzagentDomainInstanceMessage.SessionCreator
      )

    if Code.ensure_loaded?(facade) and function_exported?(facade, :create_session, 3) do
      {:ok, facade}
    else
      {:error, {:session_facade_unavailable, facade}}
    end
  end

  defp coerce_create_session_args(args) do
    short_name = Map.get(args, :short_name) || Map.get(args, :name)
    template_name = Map.get(args, :template_name) || Map.get(args, :template)
    template_options = Map.get(args, :template_options) || %{}

    cond do
      not is_binary(short_name) or short_name == "" ->
        {:error, :short_name_required}

      not is_binary(template_name) or template_name == "" ->
        {:error, :template_name_required}

      not is_map(template_options) ->
        {:error, :template_options_must_be_map}

      true ->
        {:ok, String.trim(short_name), String.trim(template_name), template_options}
    end
  end

  defp require_session_workspace_uri(%URI{scheme: "workspace"} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, _name} -> {:ok, uri}
      :error -> {:error, {:bad_workspace_uri, uri}}
    end
  end

  defp require_session_workspace_uri(other),
    do: {:error, {:bad_workspace_uri, other}}

  defp require_caller(%URI{} = caller), do: {:ok, caller}
  defp require_caller(other), do: {:error, {:bad_caller, other}}

  # --- instantiate (the north-star action) -----------------------------

  @doc "Emit the workspace's children for the Loader to bring up: `{:member, uri}` for each member (ordered FIRST so Session-Template member deps are alive) then `{:template, name, data}` for each session template. Returns the child list; the Loader dispatches each to SpawnRegistry / TemplateRegistry."
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

  # PR-3V (gt_1000 burn-down) — test-only accessors into the extracted
  # `:create_agent` machinery. The provisioning helpers moved VERBATIM to
  # `Ezagent.ActionSet.Workspace.AgentCreate`; these `@doc false` delegates
  # preserve the public `Ezagent.ActionSet.Workspace.__*_for_test__` surface
  # the cc unified-create cascade test calls (no test ref change needed).
  @doc false
  defdelegate __file_flavor_template_for_test__(flavor, class_name, agent_uri, cwd),
    to: Ezagent.ActionSet.Workspace.AgentCreate

  @doc false
  defdelegate __cascade_content_for_test__(tmpl), to: Ezagent.ActionSet.Workspace.AgentCreate

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
         %URI{scheme: "entity"} = member_uri
       ) do
    unless Ezagent.URI.type?(member_uri, :user) do
      []
    else
      # Grant chokepoint (SPEC 2026-06-17 §3.5 site #4 — the BLOCKER-3
      # variable-action builder is GONE; grant + revoke now call distinct
      # chokepoint wrappers). The async `{:dispatch, %Cmd{}}` grant.
      [
        Ezagent.Identity.Grant.grant_cap_effect(
          member_uri,
          member_create_session_cap(workspace_uri),
          member_create_session_authorization()
        )
      ]
    end
  end

  # Non-user member (agent) or missing workspace URI — no grant.
  defp grant_member_create_session_cap_effects(_workspace_uri, _member_uri), do: []

  # SPEC §7 Part B — symmetric sweep of the cap `:add_member` granted.
  # codex review HIGH: a SECURITY revoke must be synchronous +
  # failure-propagating (NOT the grant's buffered cast).
  # `:dispatch_returning` runs `:revoke_cap` inline and short-circuits
  # `handle_remove_member/2` on error, so the slice mutation (and the
  # facade's `Store.update_members/2`) does NOT commit while the cap is
  # still live. The member's User Kind is already alive at remove time,
  # so the `:call` reply can't stall on a not-ready gate.
  defp revoke_member_create_session_cap_effects(
         %URI{scheme: "workspace"} = workspace_uri,
         %URI{scheme: "entity"} = member_uri
       ) do
    if Ezagent.URI.type?(member_uri, :user) do
      # Grant chokepoint (SPEC 2026-06-17 §3.5 site #4) — the synchronous,
      # failure-propagating `{:dispatch_returning, %Cmd{}, bind_as:}` revoke.
      [
        Ezagent.Identity.Grant.revoke_cap_returning_effect(
          member_uri,
          member_create_session_cap(workspace_uri),
          member_create_session_authorization(),
          :member_create_session_revoke
        )
      ]
    else
      []
    end
  end

  defp revoke_member_create_session_cap_effects(_workspace_uri, _member_uri), do: []

  # Shared cap shape for the add/remove pair: the workspace-scoped
  # `:create_session` grant. `granted_by`/`granted_at` are OVERWRITTEN by
  # the chokepoint (`Ezagent.Identity.Grant.prepare/4`) per the
  # authorization tag, so the placeholder values here are inert (revoke
  # matches by identity_key, which excludes `granted_at`/`granted_by`).
  defp member_create_session_cap(%URI{scheme: "workspace"} = workspace_uri) do
    %Ezagent.Capability{
      kind: :workspace,
      behavior: __MODULE__,
      action: :create_session,
      instance: workspace_uri,
      workspace_uri: workspace_uri,
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  # Authorization tag (SPEC 2026-06-17 §4 PR-2, site #4). The cap is
  # `workspace/Workspace/:create_session/<concrete workspace URI>` —
  # concrete kind + behavior, concrete `%URI{}` instance, concrete action
  # `:create_session` — so `IdentityAdmin.rule_cap_bounded?/1` is true →
  # the `{:rule, …}` branch authorizes it (Decision #154).
  # `template-materialize` is no longer the authorizer. No workspace-owner
  # field is threaded to this Behavior handler, so the configurer (and
  # entity `granted_by`) is the documented Decision #154 extreme-case
  # fallback `entity://system/user/admin` — the accountable entity for the
  # workspace-membership rule. (KNOWN OVER-GRANT note above unchanged.)
  defp member_create_session_authorization do
    {:admin, Ezagent.Entity.User.admin_uri()}
  end
end

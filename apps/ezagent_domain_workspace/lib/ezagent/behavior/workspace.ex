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

  Converted from `use Ezagent.Behavior` to `use Ezagent.Lifecycle` (the
  two-container `%{state, transients}` developer API). The Workspace Kind
  is `persistence :ephemeral` (`Ezagent.Entity.Workspace`) — the
  `kind_snapshots` BLOB is NEVER the source of truth. The `workspaces`
  SQLite table (via `Ezagent.Workspace.Store`) is the SoT; the
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

  Naming (§11 NP-1/NP-2/NP-3 audit): `Ezagent.Behavior.Workspace` — a
  domain module (`apps/ezagent_domain_workspace`) naming its own domain
  concept (`Workspace`), whose actions (`list_members` / `add_member` /
  `create_session` / …) track the cluster-shape intent directly. NO
  violation; kept as-is (a rename would touch the `:workspace` snapshot
  slice key + every cap grant + every integration test reading `:workspace`
  by name for no clarity gain).
  """

  use Ezagent.Lifecycle

  alias Ezagent.Behavior.Workspace.Members

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

  action(:list_templates,
    args: %{},
    returns: %{templates: :map},
    caps: [:list_templates],
    modes: [:call],
    description: "list templates (SessionTemplate / AgentTemplate) bound to this workspace"
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
      from: {:option, :uri}
    },
    returns: %{agent_uri: :uri, template_name: :string},
    caps: [:create_agent],
    modes: [:call],
    description:
      "create a new agent in this workspace (registers Template Class, " <>
        "spawns Agent Kind, starts PTY for cc / echo-with-PTY)"
  )

  action(:create_session,
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

  # The auto-derived slice key for `Ezagent.Behavior.Workspace` is the
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
  def data_owner(_), do: :any

  # SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §2.
  # Workspace is registered on the Workspace Kind only — kind axis is
  # `:workspace`. The `use Ezagent.Behavior` engine macro (emitted under
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
  def required_caps do
    %{
      list_members: Ezagent.Capability.cap(:workspace, __MODULE__, :list_members),
      add_member: Ezagent.Capability.cap(:workspace, __MODULE__, :add_member),
      remove_member: Ezagent.Capability.cap(:workspace, __MODULE__, :remove_member),
      list_templates: Ezagent.Capability.cap(:workspace, __MODULE__, :list_templates),
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

    with :ok <- Members.validate_member_prefix(uri, workspace_uri),
         :ok <- Members.ensure_member_kind_spawned(uri) do
      new_members = MapSet.put(members, uri)

      effects =
        [{:set, :members, new_members}] ++
          grant_member_create_session_cap_effects(workspace_uri, uri)

      {:ok, %{}, effects}
    end
  end

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
        caller: Map.get(ctx, :caller),
        # 2026-06-07 file-flavor-create-cascade — the caller's caps + the
        # `--from` source URI are threaded to the #17 cascade chokepoint
        # (`Agent.spawn_from_template_content/5`) for grant-mint authorization
        # (`caps`) and to preserve single-reference clone semantics under the
        # cascade (`from_uri` → `explicit_source`).
        caps: Map.get(ctx, :caps),
        from_uri: from_uri
      })
    end
  end

  # --- create_session (unified CLI/LV session provisioning) -----------
  #
  # SPEC `docs/superpowers/specs/2026-05-26-session-create-orchestrator-unified.md`
  # Gap C. Wraps `EzagentDomainInstanceMessage.SessionCreator.create_session/3` so the CLI and LV
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
          with :ok <-
                 Ezagent.Workspace.grant_creator_manage_cap(
                   :session,
                   session_uri,
                   workspace_uri,
                   caller
                 ) do
            {:ok,
             %{
               session_uri: session_uri,
               orchestrator_uri: Map.get(meta, :orchestrator_uri),
               orchestrator_status: Map.get(meta, :orchestrator_status),
               orchestrator_error: format_orchestrator_error(Map.get(meta, :orchestrator_error))
             }, []}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # SPEC `2026-05-26-session-create-orchestrator-unified` Gap C — DI
  # provider lookup for the session-creation facade. `ezagent_domain_instance_message`
  # depends on `ezagent_domain_workspace` (workspace boots first), so a
  # compile-time alias would invert the dep graph and create a cycle.
  # Instead the facade module is looked up at runtime via the
  # application env key (default: `EzagentDomainInstanceMessage.SessionCreator`). Tests can
  # override via `Application.put_env(:ezagent_domain_workspace,
  # :session_facade, FakeFacade)` to drive `:create_session` without
  # the full chat domain.
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

    cond do
      not is_binary(short_name) or short_name == "" ->
        {:error, :short_name_required}

      not is_binary(template_name) or template_name == "" ->
        {:error, :template_name_required}

      true ->
        {:ok, String.trim(short_name), String.trim(template_name)}
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

  defp valid_from?(%URI{scheme: "entity"} = uri) do
    Ezagent.URI.type?(uri, :agent) and match?({:ok, _name}, Ezagent.URI.name(uri))
  end

  defp valid_from?(_), do: false

  defp require_workspace_uri(%URI{scheme: "workspace"} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, _name} -> {:ok, uri}
      :error -> {:error, {:bad_workspace_uri, uri}}
    end
  end

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

  # Agent flavor is stored template metadata, not part of the stable URI.
  defp compose_agent_uri(_flavor, name, workspace_name)
       when is_binary(name) and is_binary(workspace_name) do
    try do
      {:ok, Ezagent.URI.agent(workspace_name, name)}
    rescue
      ArgumentError -> {:error, {:bad_uri, {workspace_name, name}}}
    end
  end

  defp refuse_if_exists(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      :error -> :ok
      {:ok, _pid} -> {:error, {:already_exists, URI.to_string(uri)}}
    end
  end

  # cc / echo / codex → register a Workspace-scoped template + persist + invoke.
  #
  # cc / codex are FILE-FLAVORS (their Template Class implements
  # `Ezagent.Agent.CredentialAdapter`). 2026-06-07 file-flavor-create-cascade
  # fix (design note `docs/superpowers/notes/2026-06-07-file-flavor-create-cascade-fix.md`):
  # the persisted template is the AgentTemplate CONTENT schema
  # (`flavor` + `project_cwd` + an ALWAYS-present `config_dir` reference),
  # not the bare Template-Class DATA schema. `register_and_invoke_template/7`
  # detects a credentialled flavor and routes the instantiate through the
  # #17 credential-cascade chokepoint (`Agent.spawn_from_template_content/5`),
  # so a unified-create cc/codex agent gets (1) an isolated per-agent
  # config_dir (never the operator's shared `~/.claude`) and (2) the #17
  # user-default credential cascade — exactly like the orchestrator/fork
  # path. `--from` is threaded as `explicit_source` so a configured
  # user-default does NOT silently override the requested clone source.
  defp do_create_agent("cc", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "cc.agent." <> agent_name(agent_uri)

    tmpl = file_flavor_template("cc", "cc.agent", agent_uri, cwd)

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri,
      Map.get(params, :caller),
      Map.get(params, :caps),
      Map.get(params, :from_uri)
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
      "agent_uri" => agent_uri_string(agent_uri),
      "with_pty" => with_pty?,
      "cwd" => if(with_pty?, do: Path.expand(cwd), else: cwd)
    }

    # echo is NOT a file-flavor (no CredentialAdapter, no config home) —
    # nil caps/from keep it on the existing non-cascade Loader path.
    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri,
      Map.get(params, :caller),
      nil,
      nil
    )
  end

  defp do_create_agent("codex", agent_uri, session_templates, params) do
    %{
      cwd: cwd,
      workspace_name: workspace_name,
      workspace_uri: workspace_uri
    } = params

    tmpl_name = "codex.agent." <> agent_name(agent_uri)

    tmpl = file_flavor_template("codex", "codex.agent", agent_uri, cwd)

    register_and_invoke_template(
      session_templates,
      workspace_name,
      workspace_uri,
      tmpl_name,
      tmpl,
      agent_uri,
      Map.get(params, :caller),
      Map.get(params, :caps),
      Map.get(params, :from_uri)
    )
  end

  # Any other flavor (curl / np / future) — direct Kind spawn via the
  # stored flavor declaration. URI names are opaque; do not recover the
  # flavor from the agent URI.
  defp do_create_agent(other_flavor, agent_uri, _session_templates, params) do
    case direct_spawn_flavor_agent(other_flavor, agent_uri) do
      {:ok, _pid} ->
        record_creator_lineage(agent_uri, params)

        with :ok <-
               grant_agent_creator_manage_cap(agent_uri, Map.get(params, :workspace_uri), params) do
          # No slice mutation (no template registered for curl/np).
          {:ok, %{agent_uri: agent_uri, template_name: nil}, []}
        end

      {:error, {:already_started, _pid}} ->
        # Idempotent re-create — do NOT re-record lineage.
        {:ok, %{agent_uri: agent_uri, template_name: nil}, []}

      {:error, reason} ->
        {:error, {:spawn_failed, reason}}
    end
  end

  defp direct_spawn_flavor_agent(flavor, agent_uri) when is_binary(flavor) do
    with {:ok, %{kind: kind_module}} <- Ezagent.AgentFlavorRegistry.lookup(flavor),
         :ok <- Ezagent.AgentFlavorAttributes.put(agent_uri, flavor) do
      Ezagent.Kind.spawn(kind_module, %{uri: agent_uri})
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

  # 2026-06-07 file-flavor-create-cascade — build the persisted template for a
  # FILE-FLAVOR (cc/codex) in the AgentTemplate CONTENT schema
  # (`flavor` + `project_cwd` + an ALWAYS-present per-agent `config_dir`
  # reference), PLUS the `"class"` key the boot Loader's `extract_class_name`
  # + `TemplateRegistry.lookup` + `validate_template_class` require. The
  # instantiate routes this content through `Agent.spawn_from_template_content/5`
  # (the #17 cascade chokepoint), which runs it through
  # `Ezagent.Entity.AgentTemplate.to_template_data/2` to emit the Template-Class
  # DATA shape (`cwd`/`agent_uri`/…) the plugin `instantiate/3` consumes.
  #
  # `config_dir` is ALWAYS present (was `--from`-only): the per-agent TARGET
  # derived from the agent URI + the class namespace — the same dir
  # `Ezagent.Sandbox.ConfigDir.allocate/2` / `CcAgent.resolve_config_home/2`
  # clause 3 would derive. Unconditional presence (a) makes config_dir
  # allocation unconditional for file-flavors (never the operator's shared
  # `~/.claude`) and (b) satisfies `default_cascade_configured?(:file, content, _)`
  # via the content branch so the cascade fires with no `source_template_uri`.
  @doc false
  # Test-only accessor — the persisted file-flavor template ALWAYS carries a
  # config_dir reference (the no-silent-fallback structural guarantee).
  def __file_flavor_template_for_test__(flavor, class_name, agent_uri, cwd),
    do: file_flavor_template(flavor, class_name, agent_uri, cwd)

  @doc false
  # Test-only accessor — the cascade-content builder's no-silent-fallback
  # guard (a file-flavor content missing config_dir is rejected, never spawned).
  def __cascade_content_for_test__(tmpl), do: to_cascade_content(tmpl)

  defp file_flavor_template(flavor, class_name, agent_uri, cwd)
       when is_binary(flavor) and is_binary(class_name) do
    %{
      "class" => class_name,
      "flavor" => flavor,
      "agent_uri" => agent_uri_string(agent_uri),
      "project_cwd" => Path.expand(cwd),
      "config_dir" => per_agent_config_dir(class_name, agent_uri)
    }
  end

  # The per-agent config_dir TARGET — core authority (`Ezagent.Sandbox.ConfigDir`),
  # keyed by the agent URI + the class's namespace. NOT a plugin path builder.
  defp per_agent_config_dir(class_name, %URI{} = agent_uri) do
    {:ok, class_module} = Ezagent.TemplateRegistry.lookup(class_name)
    Ezagent.Sandbox.ConfigDir.path(agent_uri, Ezagent.Kind.Template.namespace_of(class_module))
  end

  # Register the template in the Workspace's session_templates slice +
  # persist via Store, then instantiate to bring the Agent Kind (+ sidecars)
  # live.
  #
  # FILE-FLAVOR routing (2026-06-07): a credentialled flavor (its Template
  # Class implements `Ezagent.Agent.CredentialAdapter`) instantiates via
  # `Agent.spawn_from_template_content/5` (the #17 cascade chokepoint) so the
  # agent gets an isolated config_dir AND the #17 user-default cascade. A
  # non-credentialled flavor (echo) keeps the existing
  # `Loader.invoke_template` path. The Store write + rollback wrapper is
  # IDENTICAL for both — only the instantiate call differs (convergence, not
  # a forked spawn path).
  #
  # Codex PR #330 r1 HIGH-1 fix: if the instantiate fails, roll back the
  # Store write so the DB doesn't carry a template the caller was told failed.
  # Without rollback, the next boot's Loader.load_all/0 would silently
  # instantiate the failed template (no CapBAC re-check, no operator visibility).
  defp register_and_invoke_template(
         session_templates,
         workspace_name,
         workspace_uri,
         tmpl_name,
         tmpl,
         agent_uri,
         creator_uri,
         caller_caps,
         from_uri
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
             tmpl,
             agent_uri,
             session_templates,
             %{caller: creator_uri, caps: caller_caps, from_uri: from_uri}
           ) do
      with :ok <-
             grant_agent_creator_manage_cap(agent_uri, workspace_uri, %{caller: creator_uri}) do
        # On success: emit slice mutation as a `:set` effect and return
        # the template + agent URIs to the caller.
        {:ok, %{agent_uri: agent_uri, template_name: tmpl_name},
         [{:set, :session_templates, new_templates}]}
      end
    end
  end

  defp grant_agent_creator_manage_cap(%URI{} = agent_uri, %URI{} = workspace_uri, %{
         caller: %URI{} = creator_uri
       }) do
    Ezagent.Workspace.grant_creator_manage_cap(:agent, agent_uri, workspace_uri, creator_uri)
  end

  defp grant_agent_creator_manage_cap(_agent_uri, _workspace_uri, _params), do: :ok

  # Codex PR #330 r1 HIGH-1 — call the instantiate; on failure, roll back
  # the Store.update_templates write so the DB matches the (uncommitted)
  # starting state.
  defp invoke_or_rollback(
         workspace_uri,
         workspace_name,
         tmpl_name,
         tmpl,
         agent_uri,
         original_templates,
         spawn_opts
       ) do
    case instantiate_template_now(workspace_uri, tmpl_name, tmpl, agent_uri, spawn_opts) do
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
  #
  # 2026-06-07 file-flavor-create-cascade — a file-flavor template is the
  # AgentTemplate CONTENT schema (`project_cwd`, not the `cwd` DATA key the
  # plugin `validate/1` checks). The cascade path validates the DATA shape
  # via `AgentTemplate.to_template_data/2`'s `validate_for_flavor`, so we
  # skip the plugin's DATA-shape `validate/1` here for credentialled flavors
  # (calling it would spuriously fail `:missing_cwd`). We still verify the
  # class is registered.
  defp validate_template_class(tmpl) do
    case extract_class_name(tmpl) do
      nil ->
        {:error, :missing_class_field}

      class_name ->
        case Ezagent.TemplateRegistry.lookup(class_name) do
          :error ->
            {:error, {:no_template_class, class_name}}

          {:ok, class_module} ->
            cond do
              file_flavor_class?(class_module) ->
                # Content-schema template — validated downstream in the
                # cascade path (`to_template_data` → `validate_for_flavor`).
                :ok

              function_exported?(class_module, :validate, 1) ->
                class_module.validate(tmpl)

              true ->
                :ok
            end
        end
    end
  end

  # A flavor whose Template Class implements `Ezagent.Agent.CredentialAdapter`
  # (cc/codex) — it has a per-agent credential home, so unified-create routes
  # it through the #17 cascade chokepoint.
  defp file_flavor_class?(class_module) when is_atom(class_module) do
    Ezagent.Agent.CredentialAdapter.credentialled?(class_module)
  end

  defp extract_class_name(%{"class" => name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(%{class: name}) when is_binary(name) and name != "", do: name
  defp extract_class_name(_), do: nil

  # Instantiate the just-registered template. A FILE-FLAVOR (credentialled)
  # template routes through `Agent.spawn_from_template_content/5` (the #17
  # cascade chokepoint) so the agent gets an isolated config_dir + the #17
  # user-default credential cascade; a non-credentialled flavor (echo) keeps
  # the existing `Loader.invoke_template` path.
  defp instantiate_template_now(%URI{} = workspace_uri, tmpl_name, tmpl, agent_uri, spawn_opts) do
    case Ezagent.TemplateRegistry.lookup(extract_class_name(tmpl)) do
      {:ok, class_module} ->
        if file_flavor_class?(class_module) do
          spawn_file_flavor_via_cascade(workspace_uri, tmpl, agent_uri, spawn_opts)
        else
          invoke_template_now(workspace_uri, tmpl_name)
        end

      :error ->
        {:error, {:no_template_class, extract_class_name(tmpl)}}
    end
  end

  defp invoke_template_now(%URI{} = workspace_uri, tmpl_name) do
    case Ezagent.Workspace.Loader.invoke_template(workspace_uri, tmpl_name) do
      {:ok, _uris} -> :ok
      # Idempotent — already running.
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} = err -> err
    end
  end

  # Route a file-flavor (cc/codex) create through the #17 credential-cascade
  # chokepoint `Agent.spawn_from_template_content/5` — the SOLE site that runs
  # `resolve_cascade_content` (isolated config_dir allocation + #17 user-default
  # resolution + grant mint + Sandbox-slice `cascade_resolution` persistence
  # for cold-restart re-resolution). Reached via runtime DI because
  # `ezagent_domain_workspace` cannot compile-time depend on
  # `ezagent_domain_instance_message` (which depends on workspace; boots later).
  #
  # `source_template_uri` is the per-agent template URI (its content carries a
  # `config_dir` reference, so the cascade's source_template_uri branch also
  # resolves); the content branch is the primary trigger.
  # `explicit_source` carries `--from` so a configured user-default does NOT
  # silently override the requested clone source.
  defp spawn_file_flavor_via_cascade(%URI{} = workspace_uri, tmpl, %URI{} = agent_uri, spawn_opts) do
    with {:ok, caller} <- require_spawn_caller(spawn_opts),
         {:ok, spawner} <- resolve_agent_spawn_facade(),
         {:ok, content} <- to_cascade_content(tmpl),
         caps <- Map.get(spawn_opts, :caps),
         opts <- build_spawn_opts(caller, caps, spawn_opts) do
      case spawner.spawn_from_template_content(content, agent_uri, caller, workspace_uri, opts) do
        {:ok, %{fresh?: true}} ->
          :ok

        # codex r5 HIGH-1 — `fresh?: false` means the spawn ADOPTED a pre-existing
        # live worker (a concurrent create won the race past `refuse_if_exists/1`).
        # This call did NOT create the agent, so it must NOT proceed to persist the
        # template or grant creator-manage caps for a worker owned by the other
        # creator. Surface `:already_exists` → `invoke_or_rollback` rolls back this
        # call's Store write.
        #
        # codex r7 HIGH — the cascade may have MINTED a grant for `agent_uri` before
        # adopting. Because UNIFIED CREATE rejects the adoption (unlike the
        # orchestrator, which accepts `fresh?: false`), the grant this call minted
        # for an agent it refuses to own must be cleaned up here (caller-specific —
        # the shared `spawn_from_template_content` cannot know the create rejects
        # adoption). HARD-delete frees the unique key for the real owner / a retry.
        {:ok, %{fresh?: false}} ->
          _ = Ezagent.Credential.GrantRow.delete(URI.to_string(agent_uri))
          {:error, {:already_exists, URI.to_string(agent_uri)}}

        {:error, {:already_started, _}} ->
          {:error, {:already_exists, URI.to_string(agent_uri)}}

        {:error, reason} ->
          {:error, {:cascade_spawn_failed, reason}}
      end
    end
  end

  # Build the CONTENT map the cascade consumes. `flavor`/`project_cwd`/`config_dir`
  # come straight from the persisted template. The #17 cascade fires via the
  # DEFAULT branch (`maybe_resolve_default_cascade_content`), triggered by the
  # content's `config_dir` satisfying `default_cascade_configured?(:file, content,
  # _)` — NO `source_template_uri` is needed (the unified-create path has no
  # shared workspace base template). The default branch correctly SKIPS
  # materializing a `cascade` when no credential source resolves
  # (`put_default_cascade_if_source_present` — single-reference path), and
  # resolves + mints a grant when a user-default / workspace-shared source IS
  # present.
  #
  # No-silent-fallback: a file-flavor whose template lacks a `config_dir`
  # reference FAILS LOUD here rather than spawning with `CLAUDE_CONFIG_DIR`
  # unset (which would silently share the operator's `~/.claude`).
  defp to_cascade_content(tmpl) when is_map(tmpl) do
    flavor = Map.get(tmpl, "flavor") || Map.get(tmpl, :flavor)
    project_cwd = Map.get(tmpl, "project_cwd") || Map.get(tmpl, :project_cwd)
    config_dir = Map.get(tmpl, "config_dir") || Map.get(tmpl, :config_dir)

    cond do
      not (is_binary(flavor) and flavor != "") ->
        {:error, :missing_flavor}

      not (is_binary(project_cwd) and project_cwd != "") ->
        {:error, :missing_project_cwd}

      not (is_binary(config_dir) and config_dir != "") ->
        {:error, :missing_config_dir}

      true ->
        {:ok, %{flavor: flavor, project_cwd: project_cwd, config_dir: config_dir}}
    end
  end

  defp require_spawn_caller(spawn_opts) do
    case Map.get(spawn_opts, :caller) do
      %URI{} = caller -> {:ok, caller}
      _ -> {:error, :missing_caller_for_cascade_spawn}
    end
  end

  # `--from` → `explicit_source` so a configured user-default does NOT silently
  # override the requested clone source (codex Finding 3).
  defp build_spawn_opts(caller, caps, spawn_opts) do
    base = [caller: caller, caps: caps]

    case Map.get(spawn_opts, :from_uri) do
      %URI{} = from -> Keyword.put(base, :explicit_source, from)
      _ -> base
    end
  end

  # Runtime DI for the agent-spawn facade (mirrors `resolve_session_facade/0`).
  # `ezagent_domain_instance_message` owns `Ezagent.Entity.Agent.spawn_from_template_content/5`
  # and boots AFTER workspace, so a compile-time alias would invert the dep
  # graph. Tests can override via
  # `Application.put_env(:ezagent_domain_workspace, :agent_spawn_facade, Fake)`.
  defp resolve_agent_spawn_facade do
    facade =
      Application.get_env(
        :ezagent_domain_workspace,
        :agent_spawn_facade,
        Ezagent.Entity.Agent
      )

    if Code.ensure_loaded?(facade) and
         function_exported?(facade, :spawn_from_template_content, 5) do
      {:ok, facade}
    else
      {:error, {:agent_spawn_facade_unavailable, facade}}
    end
  end

  defp agent_uri_string(%URI{} = uri), do: URI.to_string(uri)

  # Entity URI names are opaque; this accessor is the only local reader.
  defp agent_name(%URI{} = uri) do
    case Ezagent.URI.name(uri) do
      {:ok, name} -> name
      :error -> URI.to_string(uri)
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
         %URI{scheme: "entity"} = member_uri
       ) do
    unless Ezagent.URI.type?(member_uri, :user) do
      []
    else
      [{:dispatch, member_create_session_cap_cmd(:grant_cap, workspace_uri, member_uri)}]
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
      cmd = member_create_session_cap_cmd(:revoke_cap, workspace_uri, member_uri, :sync)
      [{:dispatch_returning, cmd, bind_as: :member_create_session_revoke}]
    else
      []
    end
  end

  defp revoke_member_create_session_cap_effects(_workspace_uri, _member_uri), do: []

  # Shared cap shape + dispatch envelope for the add/remove pair. The
  # cap is the workspace-scoped `:create_session` grant; `granted_at`
  # is only load-bearing on the grant (revoke matches by identity_key,
  # which excludes `granted_at`/`granted_by`). `reply_mode` is `:async`
  # (buffered cast — the add-time grant, member Kind may be not-ready) or
  # `:sync` (call — the remove-time revoke, member Kind is live).
  defp member_create_session_cap_cmd(action, workspace_uri, member_uri, reply_mode \\ :async)
       when action in [:grant_cap, :revoke_cap] do
    cap = %Ezagent.Capability{
      kind: :workspace,
      behavior: __MODULE__,
      action: :create_session,
      instance: workspace_uri,
      workspace_uri: workspace_uri,
      granted_by: Ezagent.SystemPrincipal.uri("template-materialize"),
      granted_at: DateTime.utc_now()
    }

    reply =
      case reply_mode do
        :sync -> {:caller_inbox, self()}
        :async -> :ignore
      end

    %Ezagent.Cmd{
      target: member_uri,
      action: action,
      args: %{cap: cap},
      ctx: %{
        caller: Ezagent.SystemPrincipal.uri("template-materialize"),
        caps:
          "template-materialize"
          |> Ezagent.SystemPrincipal.uri()
          |> Ezagent.SystemPrincipal.caps(),
        reply: reply
      }
    }
  end
end

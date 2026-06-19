defmodule Ezagent.SystemPrincipal.Catalog do
  @moduledoc """
  The closed allowlist of system principal URIs and their permitted caps.

  Any `system://` URI used as a dispatch principal MUST appear here.
  `:ezagent_plugin_check` enforces this at compile time (Issue 3);
  the runtime `SystemPrincipal.ensure/1` enforces it at boot;
  invariant test `no_admin_caps_fallback_test.exs` is the test-time gate.

  Adding a principal requires:
  1. Add row here.
  2. Update SPEC `2026-05-25-caps-cleanup-v1.md` §4.1 catalog table.
  3. Ship in a separate PR (review surface = "are we adding ambient authority?").

  (no-unowned-caps PR-1 deleted `system://feishu-binding-policy` — the last
  grant-minter — so the set is shrinking toward the north-star single
  genesis primitive; see capbac.md §7.)

  Per `feedback_let_it_crash_no_workarounds` — every entry is closed;
  there is no fallback path that mints an ad-hoc principal.

  ## Cap structs (PR-CC-2-v2)

  The catalog records `%Ezagent.Capability{}` struct values. Pre-PR-CC-2-v2
  (PR-CC-1's window) the catalog held string-cap lists and PR-CC-1's
  `SystemPrincipal.caps/1` bridge minted ONE wildcard cap per non-empty
  entry — a coarse-grained authorization slip until the struct-shape
  conversion landed.

  PR-CC-2-v2 (SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md`
  §5) closes that gap. Each entry's struct(s) precisely encode the
  Behavior's actual `required_caps/0` shape, so dispatch step 5.5's
  `holds_cap?/2` consults a structurally narrowed cap set instead of
  a uniform wildcard. The full-wildcard caps are held by the genesis
  root `system://bootstrap` (the all-caps invariant per Decision #81 +
  SPEC v3 §4.4) and the two open-plugin chat fan-out principals
  `system://chat-router` / `system://chat-reply` (structural — they
  dispatch `chat.receive`/`chat.send` across the OPEN plugin Behavior
  set, which the Catalog cannot enumerate). All others are narrowed.
  (`system://mix-task` formerly retained a wildcard "operator = admin"
  authority; it was ELIMINATED 2026-06-19 — the operator now routes
  through the real `entity://system/user/admin` entity, see its removal
  NOTE below.)

  ## Deviations from SPEC §5 provisional table

  The PR-CC-2-v2 implementing subagent verified each action atom
  against the actual `Behavior.<Module>.actions/0` on main and corrected
  the SPEC's provisional atoms:

  - `system://chat-router` originally had `session.chat.system_message` —
    `:system_message` is NOT an action on `Behavior.Session` (the action
    list is `[:send, :receive, :join, :leave, :set_working_copy]`); the
    string was a dead cap. The struct entry KEEPS only `:send` — the
    only chat-router action that actually fires in dispatch.
  - `system://chat-reply` originally had `session.chat.reaction` —
    same situation; `:reaction` is not an action. KEEPS only `:send`.
  - `system://template-materialize` originally had `workspace.template.*` —
    `workspace.template.*` doesn't structurally map (Template Behavior
    lives on AgentTemplate/SessionTemplate Kinds, not Workspace). The
    intent was "template materialization across all template actions
    + spawning sessions"; mapped to a `Behavior.Template :any-action`
    cap on the `:any`-Kind axis (template:// is cross-cutting; SPEC §2b
    Template.workspace_scoped? = false) + the session-spawning cap.
  - `system://session-internal` originally had `workspace.workspace.read` —
    Workspace has no `:read` action (its read actions are `:list_members`,
    `:list_templates`, etc.). Mapped to a `Behavior.Workspace :any-action`
    cap so session-internal can call any read-shaped workspace action;
    if narrowed later, this becomes the explicit list.

  Refinement on the `:any-action` shape: the cap struct doesn't carry
  an `:action` field (per SPEC §4 footnote — action is the map key in
  `required_caps/0`). When a system principal needs authority across
  multiple actions of one Behavior, we hold ONE cap with the matching
  `kind` + `behavior` axis; `Capability.matches?/2` ignores action
  axis (since it's not on the struct), so the cap matches every action
  on that Behavior. This is structurally equivalent to "behavior wildcard"
  while keeping the per-Kind narrowing.
  """

  alias Ezagent.Capability

  # Aliases for the Behavior modules referenced below. Inline-aliased
  # for readability; lazy-loaded at compile time so behavior modules
  # from non-loaded apps (e.g. plugin Behaviors during a core-only
  # build) don't break.
  #
  # Allen 2026-05-26 — `alias Ezagent.Behavior.ApiKeys` removed (and
  # the `cap(:user, ApiKeys, :get_api_key)` Catalog entry it served):
  # post ApiKeys-to-Agent flip CurlAgent reads its own `:api_keys`
  # slice in-process via `ctx[:sibling_slices]`, so no system principal
  # dispatches `identity.get_api_key` anymore.
  alias Ezagent.Behavior.Session
  # `alias Ezagent.Behavior.ExternalMirror` removed — its last consumer
  # (`boot-reconciler`/`adapter-install` ExternalMirror caps) was eliminated.
  # System-principal elimination — `alias Ezagent.Behavior.ExternalMirrorWorker`
  # removed with the `system://worker-publish` entry (its only consumer).
  alias Ezagent.Behavior.Identity
  # no-unowned-caps PR-1: `alias Ezagent.Behavior.IdentityAdmin` removed —
  # its only use was `feishu-binding-policy`'s now-deleted
  # `cap(:user, IdentityAdmin, :grant_cap)` (the last grant-minter).
  # System-principal elimination — `alias Ezagent.Behavior.Publisher.SessionImpl,
  # as: PublisherSI` removed with the `system://worker-publish` entry (its only
  # consumer). The ExternalMirrorWorker now carries its own inline
  # `(:session, PublisherSI, :subscribe_from)` authorizer cap.
  # System-principal elimination (#154, 2026-06-19) — `alias
  # Ezagent.Behavior.Sandbox` removed with the `system://agent-internal` entry
  # (its only consumer, `cap(:agent, Sandbox, :write_path)`). The agent now
  # carries its own inline `sandbox.write_path` self-authority cap at the
  # `Agent.TemplateSpawn` dispatch site.
  alias Ezagent.Behavior.Template
  alias Ezagent.Behavior.Workspace

  # The bootstrap structural sentinel — granted_by/granted_at on the
  # generated wildcard cap so `admin_invariant?/1` recognises it.
  @bootstrap_granted_at ~U[2026-01-01 00:00:00Z]

  defp bootstrap_wildcard do
    %Capability{
      kind: :any,
      behavior: :any,
      # SPEC 2026-05-27 capability-action-axis — bootstrap admin
      # invariant is FIVE-axis wildcard. The admin_invariant?/1
      # predicate matches this exact shape.
      action: :any,
      instance: :any,
      workspace_uri: :any,
      granted_by: Ezagent.URI.system(:bootstrap, :default),
      granted_at: @bootstrap_granted_at
    }
  end

  @doc """
  The closed allowlist mapped from principal URI →
  `[%Capability{}]` cap list. (#17 cascade PR-0 added
  `system://credential-materializer` — an empty-cap audit identity.)

  Implemented as a function (not a module attribute) so the bootstrap
  wildcard's granted_by/granted_at can use `@bootstrap_granted_by` +
  `@bootstrap_granted_at` directly without compile-time DateTime
  literal limitations.

  Use `caps_for!/1` and `member?/1` for the public API; this is exported
  so the no-wildcard invariant test (`no_wildcard_system_principals_test.exs`,
  SPEC §5) can iterate entries directly.
  """
  @spec entries() :: [{String.t(), [%Ezagent.Capability{}]}]
  def entries do
    [
      {principal(:bootstrap), [bootstrap_wildcard()]},
      # System-principal elimination (north star): `boot-reconciler` DELETED — it
      # was a DEAD principal (zero live consumers; grep found only docstrings +
      # this entry). The external-mirror boot reconcile is now IN-PROCESS
      # (`ExternalMirror.reconcile_bindings/2` in `activate/2`, not a dispatch);
      # the spawned workers publish/subscribe under their OWN self-authority
      # (#826). Nothing dispatches under this principal.
      # System-principal elimination (north star): `adapter-install` DELETED —
      # it was a DEAD principal (zero live consumers; grep across apps/**/*.ex
      # found no `SystemPrincipal.uri("adapter-install")` / dispatch under it).
      # Its documented `session.<flavor>.bind` flow is served by
      # `boot-reconciler` (above) + the live adapter wiring; this orphan entry
      # held a `cap(:session, ExternalMirror, :bind)` nothing dispatched under.
      {principal("chat-router"),
       [
         # `cap(:any, Session, :any)` covers Session-registered receivers
         # (Session, User). But chat fan-out also dispatches
         # `chat.receive` to Agent Kinds whose BehaviorRegistry routes
         # `:receive` to a PLUGIN-DEFINED Behavior (e.g. Echo's
         # `Behavior.Echo` for `entity://agent/<ws>/echo_X`). Each
         # plugin declares its own `required_caps[:receive]`; the
         # catalog cannot enumerate them across the open plugin set.
         # The wildcard cap is therefore STRUCTURAL — chat-router
         # legitimately needs admin authority for the `:receive` fan-out.
         # This is the smallest deviation from the bootstrap-wildcard
         # bridge that preserves the open-plugin chat-router semantic;
         # the SPEC §5 narrowing applies to single-Behavior principals
         # (session-internal, orchestrator-tools, …) which have a closed
         # cap set.
         bootstrap_wildcard()
       ]},
      {principal("chat-reply"),
       [
         # Same rationale as chat-router — Plugin CC's channel
         # dispatches `chat.send` AND `chat.receive` across plugin
         # Behaviors (Echo, NpAgent, …). Wildcard is the structural
         # right shape for an open-plugin fan-out principal.
         bootstrap_wildcard()
       ]},
      # System-principal elimination (north star / Decision #154) — the
      # `system://worker-publish` principal is DELETED. It held two caps —
      # `(:external_mirror_worker, ExternalMirrorWorker, :publish)` and
      # `(:session, PublisherSI, :subscribe_from)` — that authorized the
      # ExternalMirrorWorker's two internal self-dispatches (the `:publish`
      # self-dispatch + the `publisher.subscribe_from` to its bound session).
      # The Worker is a real entity Kind (`entity://worker/...`); both
      # dispatches already used `caller: self_uri`. They now carry the worker's
      # OWN inline caps in `ctx.caps` (the step-5.5 authorizer) instead of
      # borrowing this ambient principal — see
      # `Ezagent.Behavior.ExternalMirrorWorker.worker_publish_caps/1` +
      # `worker_subscribe_caps/0`. The publish cap's `granted_by` is the worker
      # itself (genuine self-authority); the subscribe cap's is
      # `entity://system/user/admin` (authority over the session — the formal
      # `{:within_session}` Cap 3 delegation stays PR-EM-3 future work). The
      # inline caps are authorizers only (never granted/persisted), so this is
      # no Decision #154 grant regression. With the principal gone the
      # elimination ratchet drops to 12 remaining.
      {principal("template-materialize"),
       [
         # 2026-06-17 (Decision #154 "no unowned permissions", PR-2 of the
         # CapBAC no-unowned-caps program) — the TWO grant-minting caps
         # `cap(:user, IdentityAdmin, :grant_cap)` + `:revoke_cap` AND the
         # grant-path-only `cap(:workspace, Workspace, :any)` are DROPPED.
         # Every template-materialization GRANT now routes through the
         # `Ezagent.Identity.Grant` chokepoint under a real-entity tag:
         #   * rule-bounded caps (`Template/{:within_workspace}`,
         #     orchestrator-admin `:restart`, member create-session) →
         #     `{:rule, :template_materialize | :workspace_membership, owner}`
         #     — authorized by `IdentityAdmin.check_grant_authorized`'s rule
         #     branch (`rule_cap_bounded?/1`), made reachable by the step-5.5
         #     `authorization_rule` honoring (`Kind.Runtime`);
         #   * `behavior: :any` orchestrator scoped caps #1/#2 (rule-ineligible
         #     by §3.3) → `{:system, bootstrap, owner}` (genesis authority,
         #     same shape as `grant_owner_orchestrator_manage_cap`).
         # The `granted_by` is the real configurer ENTITY (the session/template
         # OWNER) in every case — never this abstract principal. With its
         # grant caps gone, template-materialize is a NON-minter → category A
         # in the no_unowned gate (the gate's tooth-3 "neuter" path, mirroring
         # the 2026-06-16 agent-internal grant_cap drop).
         #
         # The principal STAYS in the Catalog because it is still a live
         # NON-grant authorizer for template materialization READS/WRITES
         # (NOT a Decision #154 / grant concern): `Template` covers
         # `template.read` (Orchestrator.read_template_content) +
         # `template.write` (cc orchestrator seed); `Session` covers the
         # `session.join` / session-spawn during materialization
         # (advisor + generic_session templates, SessionTemplate.system_ctx).
         # Migrating those ambient-authority readers off the principal is a
         # separate, non-#154 program (out of PR-2 scope).
         Capability.cap(:any, Template, :any),
         Capability.cap(:session, Session, :any)
       ]},
      {principal("orchestrator-tools"),
       [
         # `session.*` → Session behavior on Session (orchestrator tools
         # write into the session's chat slice).
         Capability.cap(:session, Session, :any),
         # `agent.identity.list_caps` — the MCP McpServer loads the
         # orchestrator AGENT's OWN four delegated caps from its
         # `:identity` slice under this principal
         # (`McpServer.load_orchestrator_caps/1` dispatches
         # `identity.list_caps` against the agent URI). Identity is hosted
         # on the Agent Kind, so the principal needs an agent-scoped
         # list_caps cap; without it the cap load returns empty and every
         # orchestrator tool runs cap-less → unauthorized.
         Capability.cap(:agent, Identity, :list_caps)
       ]},
      {principal("session-internal"),
       [
         # Deviation: original `workspace.workspace.read` mapped to a
         # Workspace Behavior wildcard cap so session-internal can read
         # any workspace state. Original `session.chat.*` widened to
         # `:any`-Kind Session — session-internal dispatches `chat.receive`
         # on User AND Agent Kinds during fan-out, so the Kind axis must
         # cross those (same multi-Kind pattern as chat-router).
         Capability.cap(:any, Session, :any),
         Capability.cap(:workspace, Workspace, :any)
       ]},
      # ELIMINATED 2026-06-19 (#154 north star, per-class collapse "actor-self")
      # — `system://agent-internal` is DELETED. Its ONLY live authority was
      # `cap(:agent, Sandbox, :write_path)`, used by
      # `Agent.TemplateSpawn.do_record_sandbox_state/4` to write the freshly-
      # spawned worker's OWN `:sandbox` slice. That is the AGENT acting on
      # ITSELF → genuine self-authority (capbac.md §7): the dispatch now carries
      # the agent's own instance-scoped `sandbox.write_path` cap INLINE in
      # `ctx.caps` (`TemplateSpawn.sandbox_write_path_self_cap/1`, `caller =
      # worker_uri`) — same play as the eliminated `system://worker-publish`.
      # The vestigial `grant_cap` (no live caller) was already dropped 2026-06-16;
      # the cross-entity `Sandbox:read` (#607 self-evolve) became agent-owned
      # in-process (`Ezagent.Behavior.ConfigEvolve`, 2026-06-11); the
      # `ApiKeys:get_api_key` cap moved to the agent's own slice (ApiKeys-to-Agent
      # flip, 2026-05-26). With its last cap re-attributed to the agent, the
      # principal has no remaining authority and leaves the closed Catalog.
      # `Ezagent.Credential.Resolver`'s former `internal_principal?` guard (which
      # special-cased this principal) was generalized to reject ANY `system://`
      # caller (`system_principal_caller?/1`), so no live code references it.
      # ELIMINATED 2026-06-19 (#154 north star, per-class collapse "actor-self")
      # — `system://workspace-loader` is DELETED. Its ONLY authority was
      # `cap(:workspace, Workspace, :any)`, used by the `Ezagent.Workspace`
      # facade + `Workspace.Loader` to dispatch the workspace's OWN
      # self-maintenance actions (`add_member`/`remove_member`/`add_template`/
      # `remove_template`/`set_routing_rules` programmatic mutations, plus
      # `remove_cross_prefix_members`/`list_members`/`instantiate` at boot) on
      # ITS OWN slice. That is the WORKSPACE acting on ITSELF → genuine
      # self-authority (capbac.md §7): each dispatch now carries the workspace's
      # own instance-scoped, per-action `cap(:workspace, Workspace, <action>)`
      # INLINE in `ctx.caps` (`Ezagent.Workspace.workspace_self_cap/2` +
      # `Workspace.Loader.workspace_instantiate_self_ctx/1`, `caller =
      # workspace_uri`) — same play as the eliminated `system://worker-publish`
      # and `system://agent-internal`. With its last cap re-attributed to the
      # workspace, the principal has no remaining authority and leaves the
      # closed Catalog.
      # ELIMINATED 2026-06-19 (#154 north star, "operator → admin entity"
      # re-attribution) — `system://mix-task` is DELETED. It held
      # `bootstrap_wildcard()` and was borrowed by the OPERATOR CLI mix tasks
      # (create_session / agent.create / credential.adopt / stress / the cc demo
      # seeders) as an ambient "operator has shell = admin authority" principal
      # (in-VM trust model §10.5). The operator's authority is now routed through
      # the REAL genesis admin entity `entity://system/user/admin`
      # (`Ezagent.Entity.User.admin_uri/0`, seeded with the bootstrap wildcard by
      # `User.initial_caps_for_spawn/1`): each operator task dispatches with
      # `caller = admin_uri()` carrying an INLINE per-action admin-authority cap
      # in `ctx.caps` (the step-5.5 authorizer) — same play as the eliminated
      # `system://worker-publish` / `agent-internal` / `workspace-loader`. The
      # `granted_by` on those inline caps is `admin_uri()` (a real accountable
      # entity, #154-compliant); they are authorizers only, never granted/
      # persisted through `Ezagent.Identity.Grant`. The one GRANT sub-path
      # (`agent.create --caps` → `Workspace.grant_initial_caps`) routes through
      # the chokepoint as `{:held_by, admin_uri()}`, which reads the admin
      # entity's REAL held wildcard caps — no inline cap involved. With its last
      # consumer re-attributed, the principal leaves the closed Catalog.
      # no-unowned-caps PR-1 (Decision #154 / capbac.md §7) — the
      # `feishu-binding-policy` principal is DELETED. It was the LAST
      # grant-minter (held `cap(:user, IdentityAdmin, :grant_cap)` +
      # `cap(:workspace, Workspace, :any)`) — used ONLY by
      # `EzagentPluginFeishu.BindingPolicy` to re-grant a bound user the
      # broad workspace-wide session baseline — which was REDUNDANT: a bound user
      # already holds that baseline via `User.default_caps/1` (applied at spawn by
      # `Ezagent.Entity.User.initial_caps_for_spawn/1`). So `BindingPolicy.apply/2`
      # no longer grants anything (no behavior change), and with its only consumer
      # removed the principal leaves the Catalog → `no_unowned` reaches 0 live
      # grant-minters. (Narrowing `default_caps` itself to a per-session model is a
      # separate, deferred refactor — not done here.)
      {principal("lv-anon-mount"), []},
      # System-principal elimination (north star): `credential-materializer` is
      # DELETED. It was an empty-cap AUDIT label used only as the `caller` of the
      # curl-agent api-key materialization (`CurlAgent.put_target_api_key/3`); the
      # real authority is the narrow inline `put_api_key` cap. That dispatch now
      # runs under the AGENT's own entity URI (self-authority over its own
      # `:api_keys` slice) — a real accountable entity. The per-grant source-read
      # authority remains the narrow `Ezagent.Credential.GrantCap` cap (no standing
      # principal cap was ever needed).
      # #51 external-user anonymous access (§3.4 GC) — the in-app GC sweeper
      # (`Ezagent.Socialware.AnonUser.Sweeper`) reaps abandoned anon-Users: it
      # `chat.leave`s each from its session under THIS principal. Narrowed to
      # exactly Session `:leave` — the `users` row + binding row deletes are
      # direct context fns (`Users.delete/1` + `AnonBinding.claim_for_reaping/3` /
      # `delete/1`), NOT dispatches, so they need no cap. The anon-User holds an EMPTY
      # caps_json and cannot self-leave (spec §3.3), so the system sweeper needs
      # this grant (Allen 2026-06-15 — Option A: a dedicated closed-catalog GC
      # principal, not ambient/per-session authority).
      {principal("socialware-gc"), [Capability.cap(:session, Session, :leave)]}
      # NOTE (#51 §4.1 / Decision #154): the anonymous public-view access path
      # does NOT use a system principal. `Ezagent.Socialware.AnonUser.mint_for_public_session/1`
      # mints the anon holding its OWN narrow `session.join` cap (granted_by the
      # session owner), so the controller joins the anon AS ITSELF — no ambient
      # `system://` join authority. See `EzagentWeb.Socialware.ChatFeedController`.
    ]
  end

  @doc "Is this URI a registered system principal?"
  @spec member?(URI.t() | String.t()) :: boolean()
  def member?(uri) do
    key = normalize(uri)
    Enum.any?(entries(), fn {entry_uri, _caps} -> entry_uri == key end)
  end

  @doc """
  Permitted caps for this principal. Raises if not in catalog.

  Per `feedback_let_it_crash_no_workarounds` — bad URI is a programmer
  error, not a degradable runtime state.

  Returns `[%Ezagent.Capability{}]` (struct shape, post-PR-CC-2-v2).
  """
  @spec caps_for!(URI.t() | String.t()) :: [%Ezagent.Capability{}]
  def caps_for!(uri) do
    key = normalize(uri)

    case Enum.find(entries(), fn {entry_uri, _caps} -> entry_uri == key end) do
      {_uri, caps} ->
        caps

      nil ->
        raise ArgumentError,
              "#{key} is not in Ezagent.SystemPrincipal.Catalog " <>
                "(SPEC caps-cleanup-v1 §4.1). " <>
                "Add the row to Catalog + SPEC + open a separate PR."
    end
  end

  @doc "List every catalog URI (for invariant test §9.5)."
  @spec uris() :: [String.t()]
  def uris, do: Enum.map(entries(), fn {uri, _caps} -> uri end)

  defp principal(name), do: name |> Ezagent.URI.system_principal() |> URI.to_string()

  defp normalize(%URI{} = u), do: URI.to_string(u)
  defp normalize(s) when is_binary(s), do: s
end

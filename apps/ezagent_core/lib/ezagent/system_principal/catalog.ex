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
  a uniform wildcard. The ONLY full-wildcard cap is now held by the
  genesis root `system://bootstrap` (the all-caps invariant per Decision
  #81 + SPEC v3 §4.4). All others are narrowed.
  (`system://chat-router`, the former open-plugin chat fan-out wildcard,
  was ELIMINATED 2026-06-20, 甲-4 — the receive fan-out now mints a
  per-recipient inline `:receive` cap from the recipient's own URI, so no
  central enumeration of the open plugin Behavior set is needed; see its
  removal NOTE below.)
  (`system://chat-reply` was ELIMINATED 2026-06-20, 甲-3 — each agent
  bridge now presents its OWN inline narrow `session.send` cap; see its
  removal NOTE below.)
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
  # `alias Ezagent.Behavior.Session` removed 2026-06-20 — its last use
  # (the `session-internal` Catalog cap `cap(:any, Session, :any)`) was
  # eliminated (#154); only `system://bootstrap` genesis remains.
  # `alias Ezagent.Behavior.ExternalMirror` removed — its last consumer
  # (`boot-reconciler`/`adapter-install` ExternalMirror caps) was eliminated.
  # System-principal elimination — `alias Ezagent.Behavior.ExternalMirrorWorker`
  # removed with the `system://worker-publish` entry (its only consumer); and
  # `alias Ezagent.Behavior.Identity` removed 2026-06-19 with `orchestrator-tools`
  # (its only use was that principal's `cap(:agent, Identity, :list_caps)`).
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
  # `alias Ezagent.Behavior.Template` removed 2026-06-20 — its last use
  # (the `template-materialize` Catalog cap) was eliminated (#154).
  # `alias Ezagent.Behavior.Workspace` removed 2026-06-20 — its last use
  # (the `session-internal` Catalog cap `cap(:workspace, Workspace, :any)`)
  # was eliminated (#154).

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
      # System-principal elimination (north star / Decision #154, 甲-4) — the
      # `system://chat-router` principal is DELETED. It held the
      # `bootstrap_wildcard()` cap (the last non-genesis wildcard holder),
      # borrowed by the session delivery fan-out for three dispatches, each
      # now re-attributed to a real entity that presents its OWN inline narrow
      # cap (the step-5.5 authorizer `granted_via_ctx_caps?`, never persisted):
      #   1. `dispatch_receive_call` (delivery.ex) — the `<entity>.receive`
      #      fan-out now presents the RECIPIENT's own `:receive` cap on its
      #      OWN instance (`granted_by: recipient_uri`, the member's
      #      self-consent at join). `behavior: :any` avoids a literal ref to
      #      the cross-app `Behavior.Agent.Receive` (undeclared-umbrella-dep
      #      gate); `kind`/`action`/`instance` keep it least-privilege.
      #   2. `dispatch_cross_session_call` (delivery.ex) — a Decision-#97
      #      cross-session forward now presents `session.send` on the concrete
      #      target (`granted_by: source_session`), GUARDED to same-workspace
      #      forwards only (cross-ws forward has no designed use case).
      #   3. `sync_result_effect` (agent/receive.ex) — the agent's own
      #      `:sync_result` self-dispatch presents an inline self-cap
      #      (`granted_by: self_uri`).
      # The wildcard was previously called "STRUCTURAL — the catalog cannot
      # enumerate the open plugin `:receive` Behaviors". That is sidestepped
      # entirely: the inline cap is minted PER-RECIPIENT at dispatch time from
      # the recipient's own URI, so no central enumeration is needed and the
      # ambient admin authority is gone. With the principal removed the
      # elimination ratchet drops to 4 remaining (+ genesis); only
      # `system://bootstrap` remains a wildcard holder.
      # System-principal elimination (north star / Decision #154, 甲-3) — the
      # `system://chat-reply` principal is DELETED. It held the
      # `bootstrap_wildcard()` cap, borrowed by the 5 agent/plugin bridge
      # adapters (curl_agent, plugin_codex, plugin_cc, echo, np_agent) so they
      # could dispatch `session.send` into the originating session. Each agent
      # is a real entity (`entity://agent/...`) and its reply dispatch already
      # used `caller: self_uri`/`caller: agent_uri`. Each now presents its OWN
      # inline narrow `session.send` cap on the concrete reply session
      # (`granted_by: <agent_uri>`, genuine self-authority, least privilege) as
      # the step-5.5 authorizer (`granted_via_ctx_caps?`) instead of borrowing
      # this ambient wildcard. The inline caps are authorizers only (never
      # granted/persisted), so this is no Decision #154 grant regression. With
      # the principal gone the elimination ratchet drops to 5 remaining
      # (+ genesis).
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
      # ELIMINATED 2026-06-20, template-materialize (#154 north star) — the last
      # non-grant authorizer for template materialization READS/WRITES/JOINS. Its
      # grant-minting caps were already dropped 2026-06-17 (PR-2, → non-minter);
      # the remaining `cap(:any, Template, :any)` + `cap(:session, Session, :any)`
      # were borrowed by 5 materialization dispatch sites (cc_orchestrator_seed
      # template.write, advisor_session/generic_session session.join,
      # session_template system_ctx template.write/read, orchestrator
      # read_template_content template.read). Materialization is system-mediated,
      # so each site now dispatches under the genesis admin entity
      # `entity://system/user/admin` with an INLINE narrow per-action cap
      # (granted_by: admin_uri — a real accountable entity; the step-5.5
      # authorizer, never routed through Grant), exactly as mix-task #833 /
      # socialware-gc (甲-6) route. #533 creation-unification will later refine
      # admin authority to per-creator. With its last consumer re-attributed, the
      # principal leaves the closed Catalog.
      # ELIMINATED 2026-06-19 (#154 north star, per-class collapse "dead caller")
      # — `system://orchestrator-tools` is DELETED. It had NO live dispatch
      # caller: (1) the orchestrator's tools run AS the orchestrator AGENT with
      # ITS OWN reconstructed caps — `SessionManager.opts/3` sets
      # `caller: binding.orchestrator_uri` + `caps: load_orchestrator_caps/1`,
      # where `load_orchestrator_caps` calls `Ezagent.Identity.list_caps_for/1`
      # IN-PROCESS (no dispatch, no principal — the stale catalog comment claimed
      # `McpServer.load_orchestrator_caps` dispatched `identity.list_caps` under
      # this principal; it never did). So the `agent.Identity.list_caps` cap was
      # dead. (2) Its only other reference was the `Legends.@legends_trusted_principals`
      # allowlist, but no production path EVER sets `caller: orchestrator-tools`
      # for `set_legends` — the real system path dispatches under
      # `system://session-internal` (`Session.system_set_legends/2`), and the
      # orchestrator sets legends via its REAL `{:within_session, self}` delegated
      # cap (chat_legends_test "the session's orchestrator (within_session cap)"),
      # NOT this principal. The allowlist entry was redundant + unreachable; both
      # it and the `session.Session.:any` cap are removed.
      # ELIMINATED 2026-06-20, session-internal (#154 north star — the LAST
      # non-genesis principal). It held `cap(:any, Session, :any)` +
      # `cap(:workspace, Workspace, :any)`, borrowed at 6 dispatch sites, each
      # now re-attributed to a real entity:
      #   - config writes (set_working_copy / set_legends / set_prompt_templates,
      #     `ConfigActions` + `Legends`) = SESSION SELF-authority: the session
      #     writes its OWN slice (`caller == self_uri`, inline cap granted_by the
      #     session; `legends_write_authorized?` recognizes `caller == self_uri`,
      #     `set_working_copy` keeps its `system_internal` handler gate). The
      #     workspace-loader #832 "acts on its own slice" pattern.
      #   - member joins during MATERIALIZATION (`session_creator/materializer` +
      #     `template_team`) = genesis admin entity + inline `session.join` cap
      #     (system-mediated; same as template-materialize; #533 → per-creator).
      #   - the wizard echo-join (`home_live`) = the operator's OWN authority
      #     (caller = operator, inline `session.join` cap granted_by operator —
      #     it just created the session, so it is the owner).
      # With its last consumer re-attributed, ONLY `system://bootstrap` (genesis)
      # remains — the elimination ratchet reaches 0 + genesis.
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
      # ELIMINATED 2026-06-20, 甲-6 (#154 north star): `system://lv-anon-mount` —
      # an EMPTY-caps placeholder used as the `caller` for unauthenticated LV
      # mounts (agent_detail/extensions/new/terminal_live). It granted NO
      # authority; it existed only to be a non-nil caller. The LV anon paths now
      # pass `caller: nil` + an EMPTY cap set directly — identical authz behavior
      # (every cap check fails the same way), no placeholder principal needed.
      # System-principal elimination (north star): `credential-materializer` is
      # DELETED. It was an empty-cap AUDIT label used only as the `caller` of the
      # curl-agent api-key materialization (`CurlAgent.put_target_api_key/3`); the
      # real authority is the narrow inline `put_api_key` cap. That dispatch now
      # runs under the AGENT's own entity URI (self-authority over its own
      # `:api_keys` slice) — a real accountable entity. The per-grant source-read
      # authority remains the narrow `Ezagent.Credential.GrantCap` cap (no standing
      # principal cap was ever needed).
      # ELIMINATED 2026-06-20, 甲-6 (#154 north star): `system://socialware-gc` —
      # the in-app GC sweeper (`Ezagent.Socialware.AnonUser.Sweeper`) reaps
      # abandoned anon-Users by `session.leave`-ing each from its session. The
      # anon holds no `:leave` cap (甲-2 mounts unconfirmed members only
      # `subscribe_from`) and cannot self-leave, so reaping is SYSTEM MAINTENANCE:
      # the sweeper now dispatches under the genesis admin entity
      # `entity://system/user/admin` with an INLINE narrow `session.leave` cap
      # (`granted_by: admin_uri`, a real accountable entity — same play as the
      # eliminated `system://mix-task`; see `GC.leave_session/2`). With its last
      # cap re-attributed, the principal leaves the closed Catalog.
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

# Durable TODO — items deferred to future PRs

> Per `feedback_durable_todo_list` (Allen 2026-05-22): the in-memory
> TaskCreate is session-scoped; this file is the source of truth for
> in-flight + future work that crosses sessions.

> **2026-06-08 verification pass** (`chore/cleanup-todo-refresh`): every
> OPEN item below was re-checked against `origin/main` @ `88d608f2`
> (cleanup-4 #678). Items proven resolved are marked `RESOLVED 2026-06-08
> (evidence: …)` inline + summarized in **"## Resolved 2026-06-08
> verification batch"** at the bottom. Items still open carry an updated
> one-line status. Conservative rule applied: RESOLVED only with concrete
> code/PR/test evidence; otherwise left open.

## 2026-07-09 — admin/business decoupling follow-up

- **Rename `Ezagent.Identity.admin?/1` → `genesis_admin?/1`** — the predicate
  recognizes ONLY the genesis bootstrap singleton (`Entity.User.admin_uri/0`);
  the honest name prevents it from ever being mistaken for a business
  superuser check again. Deferred from the gate PR (fix/admin-business-
  decoupling) to keep it bounded: the rename touches the definition + 5 config
  call sites (live_auth, error_html — incl. `function_exported?` atoms —,
  host_login_adopt, identity_data) + identity/chokepoint tests + the p13 probe
  allowlist comments. The scope contract is documented on the predicate's
  @doc and enforced by the `business_context_admin_checks` arch counter.

## 2026-07-09 plan input — 官网 session 重建 (Allen 2026-07-08)

- **官网 hello session 重建** — the live golive hello sessions are stale
  instances of the OLD hello Definition (created 2026-07-06, before #1243's
  front-desk relay + curl-llm delegation + `requires: ["orchestrator"]`).
  After #1243 lands: delete/archive the old website sessions → re-run hello
  `ensure_app`/instantiate from the new Definition → verify greeter +
  curl-llm reply E2E on the deployed channel. Owner: zhaomato (官网 full-loop
  track). MUST appear in the 2026-07-09 together plan.

## 2026-07-05 — #161 A2 deferrals (membership-cap receive/read/removal cutover)

A2 (receive/read/removal held-cap cutover) landed the load-bearing security
property (§14.5 step-5: revoke ⇒ immediate receive-deny, no reconcile — green).
Three refinements are DEFERRED with rationale; none is a security hole:

- **Fail-closed at-join member-cap grant (§16 risk-4).** A1's at-join grant stays
  `:async` best-effort. A sync/confirmed grant from inside `handle_join`
  DEADLOCKS session creation (EMPIRICALLY VERIFIED — 5s `GenServer.call` timeout in
  `Materializer.join_session_members`; the deadlock is materialization-confined —
  an inline-sync REVOKE from `handle_remove_participant` on an ESTABLISHED member
  does NOT hang). The only deadlock-free CONFIRMED grant is CALLER-SIDE (session
  Kind not blocked — proven by `mount_participation_caps` + the established-member
  revoke), which scatters across ~8 add-site chokepoints. R1.1 makes a failed/
  missing grant SECURE (no cap ⇒ receive denied — the §14.5 gate proves it) and
  self-healing (reconcile_after_load + `mix ezagent.migrate.member_caps`).
  **Recommended:** a shared caller-side confirmed grant helper invoked at the add
  sites (World LV, orchestrator participants, anon admission, SessionCreator),
  abort/compensate on failure.
  **Also covers C.2 approve (codex 2026-07-05 MED):** `approve_admission/3` re-runs
  `do_join/5`, so its member-cap grant is the SAME async best-effort call — a post-cast
  async-grant failure can drop `:pending_members` + mount without the cap. Fails CLOSED
  (R1.1: no cap ⇒ no receive ⇒ no credential spend; reconcile heals the stale roster
  entry), so it is NOT a credential-spend hole — but the approve path only becomes
  fully R3.1 "never half-mount" once this shared confirmed-grant helper lands. The
  overstated "R3.1 abort-safe" claim in `approve_admission/3`'s @doc has been corrected
  to reflect the async-grant scope.
- **Post-commit replay/notify (R3.2 / A2.5).** JOIN's `Delivery.replay_messages_since`
  + `Ezagent.Notifications.notify` still run inline pre-commit in `do_join_apply`.
  R1.1 already defangs the leak (a replayed receive to an uncommitted-join member
  holds no member-cap ⇒ denied). Moving the multi-dispatch replay + the notify off
  the inline path needs new effect plumbing (`dispatch_after_commit` is a single
  fire-and-forget Cmd) on the join hot path. Cleanliness refinement, not the
  security property. (The anon member-cap half of A2.5 is DONE by A1's universal
  grant — `member_cap_join_test` test 3.)
- **R3.1 destructive-teardown-after-revoke.** On REMOVE's `:worker` branch the
  destructive `sandbox.destroy` still runs BEFORE the checked revoke (the teardown
  fuses authority + destruction). A post-revoke-failure worker-dead+cap-held is a
  RESOURCE leak (reconciled), NOT a security regression (§14.5 asserts revoke⇒deny,
  never worker-destroyed). Fully splitting the authority preflight from destruction
  needs a chokepoint-compatible authority query (cap-check outside the destroy
  dispatch).

## 2026-07-03 plan — 官网上线剩余缺口 (Allen 2026-07-02 eve, AFK)

website-journey launch gaps (grep-confirmed zero code on main), Allen: "看起来是 orchestrator 机制", defer to 0703:
- **导游 agent (guide/greeter)** — default-joins EVERY user-created session, greets + explains features. Lives at SessionTemplate default layer (global default, NOT socialware-scoped). Configure at session creation.
- **客服 agent fallback** — website session: unanswered user messages backstopped by a 客服 recipe. = website socialware's routing rule + a 客服 recipe. After T2 lands = `Definition.agents` declaration on the website socialware. VERIFY first whether #1134's concierge already covers fallback routing (avoid dup).
- **team members → website session** — one-time seed/ops: add team.md roster to the website session.
- These three are the "configure guide/support agent at session creation" question → orchestrator mechanism (导游=SessionTemplate default, 客服=Definition.agents). Design 0703.
- **DONE 0702**: SessionTemplate fork user-flow ("一键复制 session 配置建新会话", journey segment 5) — subagent on `feat/session-template-fork`.

## Active follow-ups (post-2026-05-24 batch)

### Role-materialization + kanban-as-role (2026-06-25, Allen "do it right")

- **Role-materialization foundation (#54 follow-on)** — the role×flavor spawn
  path does not exist yet (verified 2026-06-25): `Workspace.AgentCreate` ignores
  Role; `Role.Compose.materialize` is only called by `OrchestratorRole` for cc's
  CLAUDE.md content (not a spawn); no `template://<ws>/recipe/<name>` resolver
  branch + no RoleTemplate Kind. Build: role Template subtype + `template://role`
  resolver branch + role-driven agent create + `Role.CapMint` integration into
  create. Prerequisite for kanban-as-role AND for orchestrator (which is also
  waiting on it). This is the "do it right" path Allen chose (2026-06-25).
- **kanban-as-role (depends on the role foundation above)** — convert kanban
  from a `resource://` live Kind (Plan-B) to an agent: role `kanban-manager` ×
  flavor `native`, board persists via Kind snapshot (NOT a file), `resource://`
  stays pure FS, delete Plan-B (`resource_kinds/0` + `ResourceKindRegistry` +
  workspace resource-dispatcher), world UI reused (only backend dispatch target
  changes; the read-model must move from list-by-Kind-type to list-by-role).
  Rebased #964 + the spec live on `origin/integration/kanban` (spec:
  `docs/together/2026-06-25/specs/kanban-as-role-spec.md`). Codex-review
  corrections to apply when resumed: drop the board.json idea (snapshot already
  works), native flavor needs no bridge, the world read-model change is in-scope
  (not "UI unchanged").

### Arch-debt deferred tracks (2026-06-23 close, Allen "clean all cleanable")

> Cleaned at close: `oversized_modules_gt_1000` 3→0 (#919). The items below are
> the remaining caps, with the honest reason each is NOT a quick sweep (full
> accounting: `docs/together/2026-06-23/review.md` §5).

- **#55 `undocumented_public_defs` 392 burn-down** — reducible but a mass @doc
  sweep ships unverified claims (violates `feedback_doc_why_must_be_code_verified`).
  Needs a deliberate, codex-reviewed, batched campaign.
- **`python` program-agent flavor** (Allen 2026-06-25) — `echo` is currently a
  deterministic no-LLM test fixture (folded onto `Entity.Agent` as flavor `echo`
  in the A consolidation). Future: add a real `python` agent flavor (its own
  flavor plugin) that loads + runs a py script to produce replies. echo serves as
  the template/exemplar. Do this as a NEW flavor plugin (zero core edit, per the
  AgentFlavorRegistry contract) — NOT by mutating echo. Rename echo→python only
  if that flavor subsumes echo's test-fixture role.
- **Plugin-owned resource-type registration** on `Resource.FsResolver` (currently
  core-compile-time-only `boot_registrations/0`, no plugin self-registration) →
  then migrate world `LayoutManager.layout_dir/0` off raw `Home.path` behind a
  `resource://`-style seam, ratcheting `raw_home_path_outside_core` 2→1. The codex
  SUN_LEN socket (the other entry) is genuinely un-migratable (D2). Spec-worthy.
- **`cross_file_duplicate_fn_groups` 32 audit** — enumerate annotated-sanctioned
  mirrors vs. genuinely-dedupable BEFORE any dedup (not yet audited; do not assume).
- **`cc_codex_template_class_combined_loc` 1684** — a GROWTH CEILING, not a too-big
  file (cc_agent 930 + codex_agent 754, both <1000 individually). Reducing the
  combined cap = fragmenting cohesive flavor logic to chase a number; leave as the
  ceiling. Revisit only if either file individually nears 1000.

### i18n: widen the anti-CJK gate scope + translate the rest of the umbrella — OPEN (#91 follow-up, 2026-06-23)

> Landed at the dev-together close (#91): `EzagentPluginHello.Generator`
> builder narration now goes through the plugin-owned `EzagentPluginHello.Gettext`
> backend (English msgids + `priv/gettext/zh_CN`), and a target-zero arch gate
> (`apps/ezagent_core/test/architecture/cjk_literal_gate_test.exs`,
> `Ezagent.Architecture.CjkLiteralGateTest`) fails the build on any hardcoded Han
> string literal — **scoped to `apps/ezagent_plugin_hello/lib` for now** (Allen's
> ask was "至少覆盖 hello 叙述串").
>
> **Follow-up:** widen `@scanned_globs` in that gate to the rest of the umbrella
> (the broader ~20-file sweep of hardcoded-CJK user-facing copy outside hello —
> world/socialware LV chrome, agent-console labels, etc.), wrapping each in the
> owning app's gettext backend as the gate is widened. The scanner is already
> scope-agnostic; widening = code fixes + one `@scanned_globs` line per app.
> Owner: i18n. Tracking: extends #91.

### #154 genesis-collapse hardening — RESOLVED 2026-06-20 (Allen: VM-internal-trust, formalized)

> **RESOLVED.** Allen's decision (2026-06-20): adopt VM-internal trust as the
> explicit model, delete the A-class dormant checks, and rename the `:system`
> caller marker to `:vm_internal` + remove the implicit `%Cmd` caller default.
> Shipped in three steps:
> - **(1) PR #858** — deleted the A-class dormant cap-checks in `Presence`/
>   `Notifications` (the `matches?` branch never ran in prod; sole callers were
>   internal `:system`-bypass). `Behavior.Presence`/`Behavior.Notifications` cap
>   subjects are now dead config (eligible for a later sweep — see below).
> - **(2a)** — renamed the caller-axis trust marker `:system` → `:vm_internal`
>   (self-explaining; disambiguates from the `system` workspace / admin entity /
>   System Kind). Producer + consumers flipped in lockstep; static audit = zero
>   caller-axis `:system` in lib.
> - **(2b)** — removed the implicit `%Cmd` caller default; `Cmd.new/4` now RAISES
>   on a missing caller (let-it-crash; the permanent gate against regression).
>   Test-first probe proved ALL implicit-default reliance was test-only — every
>   prod `Cmd.new` already passes an explicit caller.
>
> **Conceptual record (Allen asked "if no external caller, why authz at all?"):**
> authentication ≠ authorization. Server-populated caps at ingress = authentication
> (can't forge who you are); `matches?` = authorization (a real authenticated caller
> still needs a cap). The cap mechanism is load-bearing at the dispatch chokepoint
> because real authenticated callers exist there. `:vm_internal` is the explicit
> "trusted in-VM code, not an external entity" marker that bypasses the slice-held
> cap check at that chokepoint.
>
> **The ~6 secondary `matches?` sites = confirmed NON-GAPS (predicate-A sweep NOT
> done, by design):** A) dormant (deleted in step 1), B) unwired hardened API
> (`notification_subscriptions`, YAGNI), C) real caps but at/behind the
> step-5.5-predicate-A chokepoint (`external_mirror/gates`, `credential/resolver` —
> redundant pre-filters). Re-confirmed not externally reachable.
>
> **Dead cap-only behavior cleanup — RESOLVED 2026-06-20 (Allen: keep `Ezagent.Presence`,
> delete `Behavior.Presence`; narrow Notifications).** These were cap-only Behaviors
> (`dispatchable?: false`) whose sole job was to provide a `%Capability{behavior: …}`
> shape for runtime helpers to check. #858 reclassified presence + notify-push as
> VM-internal PubSub fan-outs and removed those checks, orphaning the cap subjects:
> - `Behavior.Presence` `:online` — truly dead (presence is VM-internal infra in
>   `Ezagent.Presence`, a thin Phoenix.Presence wrapper; nothing checked the cap, and
>   `subscribe/1` never even consulted the Behavior). **DELETED the whole module.**
> - `Behavior.Notifications` `:notify` — dead (push is VM-internal). **Action removed.**
> - `Behavior.Notifications` `:subscribe` — LIVE: `Ezagent.NotificationSubscriptions`
>   gates cross-entity subscribe/admin against it. **Kept** (the module survives).
>
> Decision rule applied: a thing is a Behavior only if it is dispatchable OR defines
> a cap that gates an externally-reachable op. Presence is neither → not a Behavior;
> Notifications `:subscribe` is a real cross-entity authz → stays a Behavior. Done in
> PR-presence-behavior-elimination: deleted module + parity test, removed `:notify`,
> fixed the `presence.ex` "no Presence Behavior registered" → "unsupported URI" guard
> message, updated the cap-only-marker exemplar comments (behavior.ex / capability_registry.ex
> / orchestrator_admin.ex / im application.ex / kind/runtime.ex) to cite Notifications,
> swapped the `role/materialize_test` fixture, ratcheted `undocumented_public_defs`
> 446→441. Full gate suite green (zero new failures vs the 3 pre-existing arch reds +
> sandbox-pollution flakes). Nature: hygiene (granted-but-never-checked cap = noise).

### `session_creator.ex` oversized + def-count refactor — OPEN (MED, two arch.scan reds on main)

> **OPEN, surfaced 2026-06-20 (甲-4 #849).** Two `mix ezagent.arch.scan` counters are
> RED on clean `main` (pre-existing, NOT from 甲-4 — identical on the parent commit):
> `oversized_modules_gt_1000` = **3** (cap 2) and `def_count_session_creator` = **35**
> (cap 30). Both root in `apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex`
> (**1071 lines / 35 defs**). The 3 oversized modules: `session_creator.ex` 1071,
> `ezagent_domain_pty/.../server.ex` 1027, `ezagent_core/.../kind.ex` 1013.
> **Why deferred:** SessionCreator is a critical create/rollback path → deserves a
> focused refactor PR + review, NOT mixed into a security PR. Fix = extract a helper
> module (e.g. the orchestrator-ensure / rollback steps) to drop session_creator
> under 1000 lines + ≤30 defs, then ratchet both caps down. **Caveat learned:** prior
> elimination PRs' "full gate" claims missed `arch.scan` (+ `im_session_agent_acyclic_test`,
> which 甲-3 broke and 甲-4 fixed) — the program's green claims need a one-time re-audit;
> run ALL gates (`arch.scan` + `check_invariants` + `doc.scan` + the invariant test dirs)
> going forward, per [[feedback_run_check_invariants_gate]].

### `behavior/session.ex` oversized (member-cap reconcile wiring) — OPEN (LOW, #161 A1)

> **OPEN, surfaced 2026-07-04 (#161 A1 gate reconcile).** `oversized_modules_gt_1000`
> was ratcheted **1 → 2** because `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex`
> crossed 1000 (was **998** on main — one line under) when A1.3 wired the member-cap
> `Session.Reconcile.reconcile_after_load/2` seed into the `activate/2` Lifecycle
> callback (now **1018**). The other A1 grower, `behavior/session/membership.ex`
> (912 → 1121), was NOT ratcheted — its at-join member-cap cluster was extracted into
> the sibling `Session.MemberCap` (941 now). **Fix =** lift the `activate/2` reconcile
> block into a small helper (or fold it into `Session.Reconcile`) to drop session.ex
> back under 1000, then ratchet `oversized_modules_gt_1000` 2 → 1. Low priority — it is
> a cohesive callback and 18 lines over.

### Fast domain-level regression test for the RouteProvisioner over-fire — OPEN (LOW, #161 C)

> **OPEN, 2026-07-05 (#161 C admission over-fire).** The admission gate over-fired on
> `RouteProvisioner.provision_declared_role/4` — a member DECLARED in the session's own
> template spec, lazily provisioned during routing, was joined under the TRIGGERING
> message-sender's caller (e.g. an anon participant), so the gate mis-classified the
> session realizing its own declared member as a cross-owner pull → PENDING. **Fixed**
> by running that member-`do_join` under system-mediated (admin) authority
> (`system_mediated_ctx/1`), identical to `Materializer.join_session_members` /
> `DefinitionAgents` at session-CREATE. **Regression guard TODAY =** the socialware P10
> E2E (`apps/ezagent_plugin_kb/test/e2e/socialware_p10_codex_gate_test.exs`) — it
> reproduces the exact flow (non-system ws, anon participant → declared bot via routing)
> and was verified fails-without-fix / passes-with-fix; it is in CI precommit. **Fix (if
> pursued) =** add a FAST domain-level test in `session_template_materialize_test.exs`
> driving `RouteProvisioner` with a non-managing sender. It MUST use a NON-SYSTEM
> workspace: in the `system` (admin) workspace `manages?/2` returns true for any caller,
> so a system-ws anon does NOT reproduce the pend (a system-ws attempt is a FALSE guard —
> it passes even without the fix). Needs the `relay_team_content`/`persist_template`
> harness re-pointed to a non-system ws + a non-system owner + a matching route rule.

### Verify protocol_api `join_agent` does not admission-over-fire — OPEN (LOW, #161 C audit)

> **OPEN, 2026-07-05 (#161 C sibling-site audit).** After fixing the RouteProvisioner
> over-fire, I audited all `session.join` dispatch sites for the same class (a member-join
> carrying a caller who does not manage the joined agent). All others are safe:
> `Materializer`/`DefinitionAgents` use `caller: admin` (system-mediated); `world_live.ex`
> + `conversation_actions.ex:836` are SELF-joins (`member == caller` → `same_entity?`
> exempt); orchestrator uses `{:spawned_by}`. **One to verify:**
> `chat_completions_plug.ex:185` (`ezagent_plugin_protocol_api`) joins `target_agent`
> with `caller: entity_uri` (the API key's principal) — its full-plug integration test is
> `@tag :skip`, so this path has NO CI coverage. In the fixtures + likely production model
> `entity_uri` is in the **system** workspace (`entity://system/agent/py_default`,
> `workspace://system`) → workspace-admin → `manages?` true → EXEMPT, no over-fire. **Risk
> only if** a real API key binds a NON-system `entity_uri` to a `target_agent` it does not
> manage → the admission gate would pend the agent-join and the OpenAI-compat endpoint
> would hang. **Verify =** un-skip the integration test with a non-system API key, or
> confirm API-key provisioning grants the principal manage-authority over its bound agent;
> if it over-fires, apply the same system-mediated-caller treatment or grant-at-provision.

### `behavior/session/membership.ex` oversized (admission cluster) — OPEN (LOW, #161 C)

> **OPEN, surfaced 2026-07-05 (#161 C admission gate).** `oversized_modules_gt_1000`
> was ratcheted **2 → 3** because `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex`
> crossed 1000 (was **966** on main after A1's MemberCap extraction) when C.1/C.2/C.3
> added the ~260-line owner-approval admission cluster — `admission_pending?`, the
> `caller_controls_member?` / `{:spawned_by, caller}` exemption chain, `record_pending_admission`,
> `notify_pending_managers`, and the public `approve_admission` / `deny_admission` /
> `withdraw_admission` handlers (now **1262**). **Not extracted (deliberately):** unlike
> A1's `Session.MemberCap` leaf, the cluster is MUTUALLY RECURSIVE with the join flow it
> guards — `do_join` calls `admission_pending?` + `record_pending_admission`, and
> `approve_admission` calls back `do_join` — so its natural home is next to `do_join`.
> **Fix (if pursued) =** extract a `Session.Admission` sibling holding the cluster
> (`same_entity?` is already cluster-local; only session.ex's 3 admission handlers + the
> `session_behavior_registration.ex` action list would repoint), accepting the
> bidirectional `Membership ↔ Admission` runtime coupling; then ratchet 3 → 2. Low
> priority — the coupling makes the split a judgement call, not a clear win.

### Routing explicit-URI receiver bypasses `valid_member?` — OPEN (LOW, pre-existing, audit)

> **OPEN, carried from 甲-4 adversarial review (2026-06-20).** `Routing.Resolver.expand_receiver/5`
> for an explicit-URI rule receiver (`resolver.ex:337`) does NOT pass through `valid_member?/2`,
> so a routing rule naming an explicit URI can fan a `:receive` to any URI. NOT weakened by 甲-4
> (before: chat-router wildcard authorized it; after: a per-recipient cap minted from that same URI
> authorizes the identical delivery) and operator-gated (requires authority to write the rule),
> structurally analogous to the `$session_members` "operator consciously asks for fan-out" token.
> Overlaps the 甲-3 reply-target-validation audit. Decide whether explicit-URI receivers should be
> membership-constrained or remain an intentional operator escape hatch.

### Frontend islands architecture (spec 乙) — IMPLEMENT after spec 甲 lands (Allen 2026-06-19)

> **OPEN — deferred until spec 甲 (membership-mount) is complete** (Allen 2026-06-19:
> "LV 岛化 dispatch subagent 去写[spec],并将实施加入计划列表,等完成当前任务后再进行").
> Spec: `docs/superpowers/specs/2026-06-19-frontend-islands-architecture-design.md` (#839).
> LV = front-of-backend shell + dispatch; React/`@json-render/*` islands = front-of-frontend
> via `phx-hook` → `Invocation.dispatch` (NOT `/api/v1` — keeps `lv_cli_parity`, no auth bridge).
> Phased: Phase 0 = swap the customer-surface renderer to `@json-render/*`; Phase 1 = de-risk
> spike of ONE mutating admin surface (routing add-rule / cap grant) as a json-render island
> beside the existing LV → decision gate before broader admin migration. Non-goals: SSR, runtime
> Node tier, big-bang LV rewrite. The anon-login UX consumes spec 甲's takeover mechanism (PR-甲-5).

### Autoservice / SW-UPD: customer-serving agent update mechanism — verify doc + tests (Allen 2026-06-09)

> **OPEN.** In the prior `autoservice` work, how does one **update the agent that
> serves a customer** (the SW-UPD / self-evolve loop — operator/agent revises the
> running customer-facing app)? Check: (1) is there documentation for this
> mechanism? (2) was it actually tested (E2E)? After the **socialware-substrate**
> task (#46) lands, review whether this mechanism's implementation is complete /
> sound on the new substrate. Likely relates to `Behavior.ConfigUpdate` +
> `set_working_copy` + template re-materialization; confirm against the
> autoservice/loom migration docs.

### ~~Capability struct lacks an action axis (codex PR #356 r1 CRIT)~~ — RESOLVED 2026-06-08

> **RESOLVED 2026-06-08** (evidence: SPEC `2026-05-27-capability-action-axis.md`
> implemented). `Ezagent.Capability` now carries an `:action` field
> (`atom() | :any`, defstruct default `:any`, NOT in `@enforce_keys`) and
> `matches?/2` checks the action dimension — confirmed in
> `apps/ezagent_core/lib/ezagent/capability.ex` (defstruct line ~40
> `action: :any`; moduledoc §"SPEC 2026-05-27 capability-action-axis"; the
> action grant-time enforcement rejecting `:any` grants from non-privileged
> principals). The multi-action-Behavior escalation surface this CRIT
> described is closed structurally. Residual UI-only follow-up
> (action-selector dropdown in the admin LV form) is tracked as its own
> OPEN item below ("Entity-caps LV grant form…").
>
> Original entry retained below for history.

- **Where:** `apps/ezagent_core/lib/ezagent/capability.ex:90` (struct
  has no `action` field; `cap/3` ignores its third arg);
  `apps/ezagent_core/lib/ezagent/capability.ex:192` (`matches?/2`
  checks kind+behavior+instance+workspace only).
- **Surfaced by:** PR #356 (HIGH-2 completion) codex r1 review of
  `Behavior.Workspace :create_user`. Folding the privileged
  `:create_user` into the same Behavior as `:add_member`/`:list_members`
  meant any holder of any Workspace cap could also create users.
  PR #356 worked around by carving `:create_user` into its OWN
  Behavior (`Ezagent.ActionSet.WorkspaceUserAdmin`) — but the underlying
  cap-shape limitation persists for every multi-action Behavior in
  the codebase (Routing, ApiKeys, UserTokens, Feishu UserBinding, …
  PR #355 Feishu UserBinding has the same flaw at lower stakes).
- **Fix shape (TBD):** add `action :: atom() | :any` as a fifth
  match dimension. SPEC-level change — touches struct, parser,
  matches?/2, every grant site, every test. Two staging strategies:
  (a) add field default `:any` (backwards-compatible — existing caps
  match all actions), then progressively narrow grants; (b) refuse
  `action: :any` grants and force per-action specification.
- **Priority:** HIGH — every multi-action Behavior is a latent
  escalation surface. Workaround (Behavior-per-privileged-action)
  works but pollutes module count.
- **Until then:** new privileged actions get their own Behavior
  module per the PR #356 carve-out pattern. Document this in
  ezagent-developer skill as a current-state pattern.
- **PR #408 surface (2026-05-27):** `Behavior.Workspace :create_session`
  was added in PR #408 (SPEC `2026-05-26-session-create-orchestrator-unified`
  Gap C) and grants the cap to workspace members on `add_member`
  (codex round-2 MED-2 fix). Because the cap shape is identical to
  every other Workspace cap, a member granted this cap also satisfies
  the cap-check for `add_member`, `remove_member`, `set_routing_rules`,
  `create_agent`, etc. **Not a regression** — the same over-grant
  exists for every multi-action Behavior cap in the umbrella; codex
  round-1 of PR #408 didn't flag it, codex round-3 caught it after
  the round-2 fix moved the helper into the Behavior layer (visibility
  not severity changed). **Mitigation in this PR:** documentation only;
  the proper fix is either (a) add `action` to the Capability struct
  (the SPEC change at top of this entry) OR (b) carve `:create_session`
  into its own Behavior module (e.g. `Behavior.WorkspaceSessions`)
  per the PR #356 carve-out pattern. Allen's call which lands first.
  Inline comments at the grant sites cross-reference this note:
  `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex` (facade
  `grant_member_create_session_cap/2`); same name in
  `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex`
  (Behavior helper, lifted from the facade in PR #408 round-2 fix).

### Entity-caps LV grant form needs action-selector dropdown (post action-axis PR) — STILL OPEN (MED)

> **Status 2026-06-08: STILL OPEN.** Verified the form still has no action
> selector — `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex:195-201`
> explicitly comments "the admin LV form does NOT yet expose an action
> selector; admins implicitly mint" and `build_cap/2` reads
> `Map.get(params, "action", "any")` (defaults to `:any`). The action-axis
> struct change landed, but this UI dropdown did not. Priority MED.

- **Trigger:** SPEC `2026-05-27-capability-action-axis.md` §3.6.1(b)
  runtime-check; r4 codex review HIGH-2; admin-role exemption is the
  bridge so the existing form (which silently defaults `action: :any`
  via `build_cap/2`) keeps working.
- **What's needed:** add an `<select>` populated from the target
  Behavior's `actions/0` (plus an `:any` option for admin-issued
  wildcard grants), wire it through `build_cap/2` so the grant
  carries the chosen action atom. Removes the admin-role exemption's
  necessity for narrow grants.
- **Where:** `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex:169-200`
- **Priority:** MED — admin-role exemption is fine in the short term;
  the proper fix is structural narrowing of admin-issued grants.

### Workspace dispatch∧persist atomicity (codex MEDIUM, feat/admin-promote-capbac) — OPEN (LOW, fail-safe)

- **What:** `Ezagent.Workspace.add_member/remove_member` dispatch the live
  Kind mutation (slice + cap grant/revoke effect) FIRST, then write the
  member set to `Store.update_members/2`. A crash between the two leaves a
  one-process-lifetime drift; Loader resyncs from the DB on next boot.
- **codex MEDIUM (remove path):** the Part B synchronous `revoke_cap`
  commits before the DB write — if the DB write fails, the member can
  reappear from the DB WITHOUT the create_session cap. This is the
  fail-SAFE direction (under-privilege, never over-privilege; the
  dangerous "cap survives without membership" case is what Part B
  closes). Documented inline at `workspace.ex` `do_remove_member`.
- **Fix shape:** Phase 5 cross-DB transaction / saga with compensation
  so the membership row + the cap state commit (or roll back) atomically.
- **Priority:** LOW — pre-existing drift class, fail-safe direction, needs
  the broader transactional persistence work.

### Admin promotion cap-lifecycle cleanup (pre-existing, codex PR #408 review surface) — DONE (PR feat/admin-promote-capbac, 2026-06-09)

> **Status 2026-06-09: DONE.** Closed in `feat/admin-promote-capbac`
> (title `feat(caps): close admin promote/revoke CapBAC bypass`).

- **Trigger:** SPEC `2026-05-27-capability-action-axis.md` §7;
  PR #408 codex r3 HIGH-C.
- **What:** `users_live.ex "Promote to system"` / `"Revoke"` called
  `Ezagent.Workspace.add_member/remove_member/2`, which dispatch under
  `system://workspace-loader` (NO caller cap-check). The
  `/identities/users` route is `:require_entity` (not `:require_admin`),
  so a non-admin LV user could promote/revoke without a CapBAC check —
  AND demotion did not sweep the cap `:add_member` granted.
- **Resolution (Part A — CapBAC bypass):** added cap-checked
  `Ezagent.Workspace.add_member/3` + `remove_member/3` (mirroring
  `create_user/3`) that dispatch the `Behavior.Workspace`
  `:add_member` / `:remove_member` actions carrying the logged-in
  caller's FRESH caps (`current_caller_caps/1`). Step 5.5 CapBAC now
  runs against the caller — identical to `mix ezagent.workspace.*`. The
  `/2` programmatic variants are UNCHANGED (legitimate `workspace-loader`
  use for in-VM CLI / mix-task / Loader callers; mix tasks +
  `workspace_detail_live.ex` keep using them).
- **Resolution (Part B — cap-lifecycle sweep):** system authority is
  membership-based (`Capability.cross_workspace?/2`), so promotion grants
  no system-wide cap rows — revoking membership removes that authority by
  construction. The one durable cap `:add_member` grants is the
  workspace-scoped `:create_session` cap; `handle_remove_member/2` now
  emits a symmetric `revoke_cap` effect (matched by 4-tuple
  `identity_key`, invariant #19), so a demoted member loses
  create_session authority in the workspace they were removed from —
  and only that cap (instance axis scopes it; caps in OTHER workspaces
  are untouched).
- **Tests:** under-privileged LV promote/revoke REJECTED (membership
  unchanged); admin succeeds; fresh-caps post-mount grant takes effect;
  add grants + remove sweeps the create_session cap. All TDD-confirmed
  to fail against the pre-fix code.

### Codex PR #356 r1 HIGH/MED deferred — PARTIALLY RESOLVED 2026-06-08

> **Status 2026-06-08:** HIGH-2 (combined-Behavior shared-cap-subject) is
> RESOLVED — the action-axis landed (see resolved entry at top), so
> mint/list/revoke on `UserTokens` are now distinguishable per-action.
> HIGH-1 (CLI integration test for User-Kind ops) and HIGH-4 (LV bypass for
> create/set_password) remain STILL OPEN — verified `users_live.ex:138` still
> calls `Ezagent.Users.create/3` and `:203` `Ezagent.Users.set_password/2`
> directly (no dispatch).

- **HIGH-1 (CLI scheme mismatch for non-bare URIs):** PR #356 fix
  partial — added a parsed-URI passthrough in
  `EzagentCli.Dispatch.build_target_uri/5` so callers can pass full
  `entity://...` URIs in `--user`. But CLI tests covering User-Kind
  ops (`grant_cap`, `set_password`, `mint_token`, etc.) don't exist
  yet — they would catch a regression. **Follow-up:** add a CLI
  integration test class for User-Kind actions (parallel to
  `cli_lv_same_server_invariant_test.exs` for Session).
- **HIGH-2 (UserTokens combined Behavior):** the same Behavior carries
  mint/list/revoke, so they share a cap subject (subsumed by the
  CRIT-1 axis issue above; cap split would require structural change).
  Until the action-axis SPEC lands, document the limitation in the
  Behavior moduledoc + audit cap grants accordingly.
- **HIGH-4 (LV bypass for create/set_password):** the GUI side
  (`EzagentPluginLiveview.UsersLive`) still calls
  `Ezagent.Users.create/3` + `set_password/2` directly. PR #356
  closed the CLI surface only. **Follow-up:** migrate the LV to
  dispatch via the same `Ezagent.Workspace.create_user/3` /
  `:set_password` dispatch paths CLI uses. Tracked separately
  because LV migration is a UX-touching change distinct from the
  CLI-side dispatch closure.



### AdapterRegistry / BindingRegistry `:public` ETS hardening (facade-audit r5 CRIT deferred)
- **Where:** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex` + `binding_registry.ex` (both `:public` ETS managed by `EzagentCore.EtsOwner`)
- **Surfaced by:** PR #334 (facade-audit IMPL) codex r5 — CRITICAL: in-VM caller can `:ets.insert(table, ...)` against either registry, spoofing an adapter/binding pair that the Plugin contract never validated → bypass Grill-5 + bypass `assert_required_callbacks!` + dispatch a fake `:bind` to a non-existent adapter module.
- **Fix shape (TBD):** convert `:public` → `:protected` (only GenServer owner writes); expose `register/1` API enforced by Plugin.boot only; update ~15 test sites that do direct `:ets.delete*` against these tables to use a sandbox-clear API instead.
- **Why deferred:** PR #334 was already at codex r5 + the fix touches PR-EM-1 + PR-EM-2 modules — out of facade-audit scope. Same systemic concern earlier flagged for OTHER `:public` ETS registries (Plugin/AgentFlavor/Behavior/Template) per docs/futures/todo "ETS-registries hardening" entry. Worth one combined SPEC + impl.
- **Priority:** MED — exploitable only by in-VM code (BEAM access already implies trust); production deployment posture treats BEAM access as trusted. Worth fixing pre-multi-tenant GA but not v1 blocker.

### Facade-auth-model security audit (deferred from PR-EM-3 codex iteration)

- **Where:** `apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror.ex` (facade) + `behavior/external_mirror.ex` (action body)
- **Pattern observed (2026-05-25):** PR-EM-3 hit 5 rounds of codex review (r1-r5);
  each round surfaced 2-3 new HIGH/CRIT findings related to the bind/unbind
  facade's auth-model enforcement: flag forgery (r3 CRIT), read-side cap
  bypass (r2 HIGH), spawn-error swallowing (r4 HIGH), ordering of cap-check
  vs target-ownership-check (r4 MED), and BootReconciler ordering (r4 HIGH).
  The pattern suggests structural under-specification in SPEC §4.2 not
  fully addressed by point fixes.
- **Recommendation:** post-Stream-2 standalone audit PR that
  (a) defines a single comprehensive invariant test exercising all 4
  enforcement gates (cap-1 / cap-2 / target-check / workspace-iso) +
  forgery resistance + ordering + failure modes;
  (b) reviews the facade vs action-body split per `feedback_let_it_crash_no_workarounds`;
  (c) adds a security-focused doc to `docs/superpowers/specs/` capturing
  the auth model formally.
- **Priority:** post-Stream-2 (PR-EM-FINAL or first follow-up). Each
  individual PR-EM-3 finding is fixed; the META-finding is the
  pattern of finding-them.
- **Concrete r5 starting points** (2026-05-25 codex r5 — `needs-attention`,
  2 HIGH on PRE-EXISTING code, NOT in r4 scope; both architectural per
  ship discipline so escalated rather than in-place-fixed):
  1. **AdapterInstall ordering vs BindingRegistry atomicity**
     (`apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_registry.ex:92-101`):
     `AdapterRegistry.register/1` triggers `AdapterInstall.install/1`
     (worker reconciliation) before the matching
     `BindingRegistry.register_module/2` runs in the normal plugin boot
     path. If the binding-registry insert later fails and rollback
     deletes the adapter row, already-spawned workers stay alive against
     a missing binding module → supervisor churn. Recommendation: split
     cap-subject registration from worker reconciliation; gate worker
     spawn on BOTH registries succeeding.
  2. **bind spawn-before-persist split-brain**
     (`apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex:333-340`):
     `:bind` action body spawns the worker FIRST, then
     `persist_binding_row/2`. If `Repo.insert/1` raises (DB outage,
     schema drift), the worker is alive but no row + no slice mutation.
     Also: changeset errors are mapped to `:ok` blanket — non-unique
     validation failures would silently drop the row while leaving
     slice + worker. Recommendation: make bind atomic — either persist
     first + terminate worker on failure, OR only treat
     verified-unique-constraint collisions as idempotent (return/raise
     all other Repo failures).

### `Ezagent.Invocation.dispatch/1` ReadyGate ↔ PendingDelivery TOCTOU — STILL OPEN (MED)

> **Status 2026-06-08: STILL OPEN.** No atomic `ReadyGate.status_and_buffer/1`
> exists; the two-read race is unaddressed. (NB: the separate `:not_ready`
> readiness regression from the lifecycle migration WAS fixed in #493 — that
> is a different bug. This microsecond TOCTOU window remains.) Priority MED.

- **Where:** `apps/ezagent_core/lib/ezagent/invocation.ex` `dispatch/1`
  reads `Ezagent.Kind.ReadyGate.status/1` then
  `Ezagent.Kind.PendingDelivery.buffer/...` as two non-atomic
  operations. A Kind that flips `not_ready → ready` between the two
  reads can have an invocation neither buffered nor delivered.
- **Surfaced by:** PR-EM-CORE (#312, 2026-05-24 / merged 2026-05-25) —
  widening the not-ready window during the new post-init continuation
  queue made the race more visible. Codex r4 of PR-EM-CORE flagged it.
- **Pre-existing:** YES — the race exists on `main` independent of
  PR-EM-CORE; PR-EM-CORE merged with the race documented as a
  framework-wide separate concern (per Allen's "round-2 cap" rule +
  autonomous merge authorization).
- **Fix shape (TBD):** likely either (a) atomic
  `ReadyGate.status_and_buffer/1` returning {:ready | {:buffered, _}}
  in one ETS read+write, or (b) buffer-then-check + drain on
  ready-flip. Needs a SPEC; not a quick patch.
- **Priority:** MED — race window is microseconds in practice and the
  drain-on-ready path picks up dropped invocations; no observed
  message loss in the test suite. Worth fixing before ExternalMirror
  GA but not blocking individual PR-EM-* merges.

### Marketplace install-from-source (PR3 cc.toggle_extension toggle-ON)
- **Where:** `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex` —
  `toggle_extension/3` returns `:install_from_source_not_implemented`
  for `enabled? = true`. Toggle-OFF works (`rm -rf` the bundle dir).
- **Why deferred:** needs a marketplace contract (source URL,
  signature, version pin, cache layout). Out of scope for PR3
  scaffolding.
- **Workaround for operators:** manually `cp -r` a Claude Code plugin
  bundle (with `.claude-plugin/plugin.json` manifest) into
  `<config_dir>/.claude/plugins/<name>/`. The LV picks it up on next
  refresh + can toggle-OFF.
- **Next step:** SPEC the marketplace registry. Likely a new Kind
  (`marketplace://<name>`) with `:install` / `:uninstall` /
  `:list_available` actions, dispatched by the cc plugin from
  `toggle_extension`.

### CLI ↔ GUI parity (audit findings #137 still partial)
From `docs/notes/2026-05-24-cli-gui-parity-audit.md` — 2 HIGH still
open after HIGH-1 (admin fallback hole) closed in PR #298:

- **HIGH-2** (16 of 17 legacy `mix ezagent.*` tasks bypass dispatch):
  needs a per-task migration sweep. Tasks call domain modules
  directly → no CapBAC, no audit, no cross-workspace check. Worst
  example: `mix ezagent.routing.add_rule`. Approach: write a
  migration template, hold an invariant test that `mix ezagent` is the
  ONLY task allowed to call domain modules outside of bootstrap.

  **Sweep progress (this PR — triage commit on
  `cli-sweep/deprecate-bypass-tasks`):**

  - ✅ `routing.add_rule` — already deprecated in PR #302 (Behavior
    `Ezagent.ActionSet.Routing` exists; `mix ezagent routing add_rule`
    dispatches against `system://routing/default`). **DELETED in
    cleanup-4 (2026-06-08)** — the deprecation stub was a pure
    `Mix.raise` no-op with no remaining function; its replacement has
    shipped, so the stub was retired.
  - ⏳ **deferred to follow-up PRs** — each below needs a real
    `Behavior` action reached via `Ezagent.Invocation.dispatch/1`
    (NOT a bare FacadeRegistry op) BEFORE its legacy task can be
    deprecated. **Codex PR #304 pre-merge review HIGH finding:** a
    FacadeRegistry op that calls a domain function directly
    reproduces the exact bypass HIGH-2 is supposed to retire —
    `EzagentCli.Dispatch.run_facade/3` invokes `fun.(parsed)` with
    no Invocation, no caller/caps, no audit. Each row below MUST
    land its corresponding Behavior action + cap subject FIRST;
    `mix ezagent` will then auto-derive the CLI from the Behavior's
    `interface/0`. Wiring a FacadeRegistry shortcut "to ship it
    faster" is the wrong fix — it would close HIGH-2 by closing
    the wrong problem.

    | Legacy task | Proposed `mix ezagent` | Status |
    |---|---|---|
    | `mix ezagent.feishu.bind` | `mix ezagent workspace bind --workspace <name> --open-id … --user-uri …` | ✅ **DONE in cli-lv-parity-high-2-3 branch.** `EzagentPluginFeishu.Behavior.UserBinding` registered on Workspace Kind with `:bind` action + cap. Legacy task kept as-is pending muscle-memory transition. |
    | `mix ezagent.feishu.unbind` | `mix ezagent workspace unbind --workspace <name> --open-id …` | ✅ **DONE.** Same Behavior, `:unbind` action. |
    | `mix ezagent.feishu.list` | `mix ezagent workspace list_feishu_bindings --workspace <name>` | ✅ **DONE.** Same Behavior, `:list_feishu_bindings` (read-only). |
    | ~~`mix ezagent.feishu.chat.bind`~~ | ~~`mix ezagent feishu chat_bind`~~ | **OBSOLETE.** Removed in PR-EM-6; chat→session bindings now go via `mix ezagent.external_mirror.bind <session-uri> feishu <chat_id>` (generic ExternalMirror Domain). |
    | ~~`mix ezagent.feishu.chat.unbind`~~ | ~~`mix ezagent feishu chat_unbind`~~ | **OBSOLETE.** Same as above; use `mix ezagent.external_mirror.unbind`. |
    | `mix ezagent.user.create` | `mix ezagent workspace create_user --workspace <name> --user-uri … --password … --caps …` | ✅ **DONE (2026-05-26).** `Ezagent.ActionSet.WorkspaceUserAdmin :create_user` registered on Workspace Kind. Body wraps `Ezagent.Users.create/3` + opportunistic `SpawnRegistry.spawn`. Adds a structural cross-workspace check on the new user URI that the legacy direct-call had no analog for. Facade `Ezagent.Workspace.create_user/3`. Legacy task retained for muscle memory with deprecation notice. **NOTE:** codex PR #356 r1 CRIT showed that co-locating `:create_user` with `Behavior.Workspace`'s 10 member/template/routing actions would share a cap subject (no action axis in Capability struct), so this carved out into its own Behavior. Underlying cap-action-axis limitation tracked above. |
    | `mix ezagent.user.set_password` | `mix ezagent user set_password --user <uri> --password …` | ✅ **DONE (2026-05-26).** New `Ezagent.ActionSet.UserCredentials :set_password` registered on User Kind. Separate from Identity per cap-shape carve-out (avoids conflating self-mutation rights with admin reset). Legacy task retained as admin-bootstrap carve-out (chicken-and-egg: first password must be set BEFORE admin has a token to authenticate `mix ezagent`). |
    | `mix ezagent.agent.create` | `mix ezagent workspace create_agent --workspace <name> --flavor … --name …` | ✅ **ACTION EXISTS** (PR #344 / `Behavior.Workspace :create_agent`); legacy task still calls the action body directly (single-path invariant test enforces). Auto-derived `mix ezagent workspace create_agent` already wired. |
    | `mix ezagent.user.token mint` | `mix ezagent user mint_token --user <uri> --label …` | ✅ **DONE (2026-05-26).** New `Ezagent.ActionSet.UserTokens :mint_token` registered on User Kind. Body wraps `Ezagent.Entity.Token.mint/2`. **Carve-out preserved:** the first-admin-bootstrap mint stays in the legacy task per codex PR #304 MED — the deprecation notice for `--mint` is gentler than for `--list`/`--revoke` to reflect this. |
    | `mix ezagent.user.token list` | `mix ezagent user list_tokens --user <uri>` | ✅ **DONE (2026-05-26).** Same Behavior, `:list_tokens` action. Returns id / label / timestamps only — NEVER plain (regression test asserts the response shape has no `:plain` or `:token_hash` keys). |
    | `mix ezagent.user.token revoke` | `mix ezagent user revoke_token --user <uri> --token-id …` | ✅ **DONE (2026-05-26).** Same Behavior, `:revoke_token` action. Idempotent (legacy `Token.revoke/1` returns `:ok` for unknown ids). |

    Rule of thumb for the implementer: if you're about to add a
    `FacadeRegistry.register/3` for one of these without a matching
    `Behavior` + cap subject + `Ezagent.Invocation.dispatch/1` call
    path, STOP — you're recreating HIGH-2.

  - ✅ **CLI-only by design (will NOT be migrated, audit-confirmed
    carve-outs):** `bootstrap`, `check_invariants`, `db.reset`,
    `home.adopt_db`, `home.init`, `plugin.install`, `snapshot.list`,
    `snapshot.dump`, `stress`, `user.token` (**bootstrap mint ONLY**
    — `list` + `revoke` move to deferred table above per codex MED
    finding; the legacy task keeps a narrow first-admin mint mode),
    `auth.magic_link` (operator-debug mirror of HTTP path),
    `demo.seed_cc_agent` / `demo.seed_cc_sandbox` (demo seeders,
    not operator ops). Each file now carries a "Category A" audit
    comment in its moduledoc.
  - ⚠️ **partial-dispatch carve-out:** `snapshot.clear` — destructive
    DB op that audit Finding 5 flags as "should arguably be a
    Behavior so caps gate it". Tracked separately; the wider
    `system://snapshots` Kind needs designing first.
- **HIGH-3** (~12 LV handle_events have no CLI equivalent):
  ✅ **enumerating invariant landed** as
  `apps/ezagent_core/test/invariants/lv_cli_parity_test.exs` in
  cli-lv-parity-high-2-3 branch. Walks every LV file, categorises every
  `handle_event/3` clause into `:cli | :ui_only | :pty_stream | :deferred`
  with explicit per-event row + reason. Currently 61 events tracked
  (27 CLI / 26 UI-only / 2 PTY-stream / 6 deferred).

  **Re-mapping after the invariant landed** (audit notes from
  2026-05-24 now stale; this is the current state):

  | Event | Status |
  |---|---|
  | `add_member`, `remove_member`, `add_template`, `remove_template`, `create_workspace` | ✅ `mix ezagent workspace ...` / `mix ezagent.workspace.*` (PR #344) |
  | `promote_to_system`, `revoke_system` | ✅ aliased to `workspace.add_member/remove_member system <uri>` |
  | `grant`, `revoke` (entity_caps) | ✅ auto-derived `mix ezagent user grant_cap/revoke_cap` via `Behavior.IdentityAdmin` |
  | `delete_rule`, `disable_rule`, `enable_rule` | ✅ auto-derived `mix ezagent workspace delete_rule/...` via `Behavior.Routing` |
  | `add_rule` | ✅ auto-derived `mix ezagent workspace add_rule` |
  | `routing_rule_add_session` | ✅ auto-derived `mix ezagent session add_rule` (Routing registered on Session Kind) |
  | `routing_rule_toggle` | ✅ aliased to `mix ezagent workspace enable_rule/disable_rule` per toggle direction |
  | `restart` (agent) | ✅ auto-derived `mix ezagent agent terminate` |
  | `toggle` (agent extensions) | ✅ auto-derived `mix ezagent template toggle_extension` |
  | `bind`, `unbind` (feishu) | ✅ auto-derived `mix ezagent workspace bind/unbind` (this PR — Behavior.UserBinding) |
  | `put`, `delete` (api_keys) | ✅ auto-derived `mix ezagent user put_api_key/delete_api_key` |
  | `dump`, `clear` (snapshots) | ✅ `mix ezagent.snapshot.*` |
  | `add_binding`, `unbind` (ext mirror) | ✅ `mix ezagent.external_mirror.*` |
  | `send_test_email` | ⚠️ semi-covered by `mix ezagent.auth.magic_link` (different intent — operator-debug) |
  | **`create_session`** | ✅ **DONE (PR-5 / 2026-06-04).** `Behavior.Workspace :create_session` is the user/operator entry; LV and E2E setup now call `Ezagent.Workspace.create_session/3`, while lower-level instance-message materialization is internal-only. |
  | **`create_user`** | ✅ **DONE (2026-05-26).** `Behavior.Workspace :create_user` (see HIGH-2 table). Auto-derived `mix ezagent workspace create_user`. |
  | **`set_password`** | ✅ **DONE (2026-05-26).** New `Behavior.UserCredentials :set_password` on User Kind (see HIGH-2 table). Auto-derived `mix ezagent user set_password`. |
  | **`save_display_name`** | ⏳ DEFERRED. Needs Behavior on User Kind for `:set_display_name` (Profile slice); LV uses `Ezagent.Entity.Profile.upsert/1` directly. |
  | **`save_smtp`** | ⏳ DEFERRED. Needs Behavior on App/SystemSettings Kind for `:save_smtp_config`; LV uses `Ezagent.AppSettings.put/2` directly. |
  | **`chat_compose`** | ⏳ DEFERRED. CLI is partial — text-only via `mix ezagent session send`; file attachments need a `resource://` upload primitive that doesn't exist yet (audit Finding row 1). |

  The remaining ⏳ DEFERRED rows are the residual gaps. Each is
  enumerated in the invariant test's `@event_to_cli` table with
  category `:deferred` and a `docs/futures/todo.md` citation.
  Post-2026-05-26 HIGH-2 completion: `create_user` + `set_password`
  closed; 3 deferred rows remain (`chat_compose`, `save_display_name`,
  `save_smtp`).

### ~~`/admin/uploads/:filename` controller route — scope mismatch~~ — RESOLVED 2026-05-25
Codex PR #305 round-4 HIGH (2026-05-24): the chat-compose-upload
download endpoint sat under the `/admin/*` URL prefix but was a
plain controller route, so the centralized `live_session
:require_admin` (PR #305) did NOT gate it. The controller was
misnamed — chat uploads are user-scope, not admin-scope.

**Fix landed (2026-05-25, PR fix/uploads-route-per-user-authz):**
1. ~~Move route from `/admin/uploads/:filename` →
   `/files/:filename`~~ — done in `router.ex`.
2. ~~`UploadsController.show/2` verifies caller is admin OR
   uploading-user OR session-participant; otherwise 403.~~ — done
   in `uploads_controller.ex`.
3. ~~Regression test pinning cross-user isolation.~~ — done in
   `apps/ezagent_web/test/ezagent_web/controllers/uploads_controller_test.exs`
   (9 tests, including the cross-user-guessing-yields-403 case).
4. ~~All remaining `/admin/*` routes are pure LiveView, gated by
   `live_session :require_admin` by inspection.~~ — comment added
   in `router.ex` near the admin scope documenting the
   invariant + an explicit anti-regression note.

### ~~Silent default workspace fallbacks (runtime form)~~ — RESOLVED 2026-05-26 (PR #362)

Allen 2026-05-26 09:31: "如果没有提供 workspace name，应该直接 crash. 现在
已经没有了默认 workspace 这个概念". PR #335 deleted the literal/static
default workspace; PR #362 closed the remaining 14 runtime-fallback
sites of shape `workspace_uri.host || "default"` + the residual
`workspace_name_from_caller(_), do: "system"` in `dispatch.ex`.

Sites fixed: `session.ex × 4`, `agent.ex × 1`, `behavior/template.ex × 2`,
`session_template.ex × 1`, `orchestrator/tools.ex × 2`, `cc_agent.ex × 2`,
`dispatch.ex × 1`. New invariant test
`no_silent_default_workspace_test.exs` locks the bug class out.

NB: `dispatch.ex` 144/147/150 `fill_caller_workspace("default", ...)`
intentionally NOT touched — `"default"` is the template-class segment
of `session://<class>/<workspace>/<name>`, not a workspace fallback.

### ~~Notifications consumer coverage~~ — RESOLVED 2026-05-26 (med-batch)
PR #300 wired AdminLive as the operator subscriber + added notify
calls to `Workspace.add/remove_member` and `Identity.grant/revoke_cap`.
~~Additional producers still silent~~ — all 3 wired in med-batch:
- ✅ `Chat.join` notifies joinee (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/chat.ex` `invoke(:join, …)` — `:session_member_joined`)
- ✅ `agent.terminate` notifies spawning principal via `AgentLineage.lookup/1` (`apps/ezagent_core/lib/ezagent/behavior/lifecycle.ex` `invoke(:terminate, …)` — `:agent_terminated`)
- ✅ `agent_template.fork` notifies fork-owner (`apps/ezagent_domain_instance_message/lib/ezagent/behavior/template.ex` `fork_agent_template/3` — `:agent_template_forked`)

All gated by `user_uri?/1`. Tests added to `chat_test.exs`,
`lifecycle_terminate_test.exs`, `template_fork_lineage_test.exs`.

### ~~PR5: `Agent.duplicate/clone` (cross-user agent copy)~~ — RESOLVED 2026-05-26 (via PR #338)

Per `feedback_agent_clone_not_via_template`: direct agent-to-agent
copy. **Landed in PR #338 (`9120952`)** via `--from <source-uri>` arg
on `Ezagent.Workspace.create_agent/3`. The clone primitive is
`Behavior.Workspace.:create_agent` with `from:` arg:

- **Source resolution** — `resolve_source_config_dir/2` in
  `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:469`
  dispatches `sandbox.read` against the source agent URI WITH THE
  CALLER'S CAPS (standard CapBAC, no parallel auth path), returns
  the source's `config_dir_path` from its `:sandbox` slice.

- **Copy + spawn** — `do_create_agent("cc", …)` at
  `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace.ex:526`
  builds a cc Template with `claude_config_dir` = source's per-agent
  dir; the cc Template Class's existing `create_agent_config_dir/2`
  does the `File.cp_r/2` deep copy at spawn (Allen 2026-05-24 PR3).
  Result: new agent has same `template_class` + own
  config_dir path (deep-copy independent from source).

- **CLI** — `mix ezagent.agent.create <uri> --from <source-uri>`
  already wires through the action (no separate `mix ezagent agent
  clone` subcommand; the operator surface uses
  `mix ezagent.agent.create` with the source as a flag).

- **Cross-workspace cap-bridge** — still deferred to v1.5. The
  current path requires the caller to hold `sandbox.read` on source
  AND `Behavior.Workspace.:create_agent` on destination workspace —
  same-workspace works structurally; cross-workspace caps need the
  bridge SPEC.

**Architectural rationale for NOT adding `Ezagent.Entity.Agent.clone/3`:**
Adding a parallel primitive on the Agent module would create dual
SoT (P3 violation) — the action body already lives on
`Behavior.Workspace.:create_agent` per Allen's 2026-05-25
simplification (closes #332). `feedback_agent_clone_not_via_template`'s
intent was "not via Template Registry" — Workspace IS the natural
parent Kind (per the `:create_agent` precedent), not a Template
Registry concern. Status documented per `feedback_dont_defer_what_is_solvable_now`:
v1.5 cross-workspace cap-bridge tracked separately when it lands.

### Audit gaps from notification-log audit
Still open after PR #300 + the batch fix that includes this todo:
- **DONE (low-doc-batch 2026-05-26)** — `EzagentWeb.Telemetry.metrics/0`
  defines 16 metrics; the original report claimed "no reporter attached"
  but `Phoenix.LiveDashboard` at `/dashboard` consumes `metrics:
  EzagentWeb.Telemetry` (verified at `apps/ezagent_web/lib/ezagent_web/
  router.ex:250` — `live_dashboard "/dashboard", metrics: EzagentWeb.
  Telemetry`). The moduledoc already documents this correction in the
  2026-05-24 cleanup batch. Single-node-ops setup needs no separate
  Prometheus reporter; adding `{TelemetryMetricsPrometheus, ...}` to
  `EzagentWeb.Telemetry.init/1`'s children is a one-line future change
  if multi-node alerting becomes a requirement (LiveDashboard would
  keep working in parallel because both reporters subscribe to the
  same telemetry events).
- **DONE (low-doc-batch 2026-05-26)** — SPEC for the notifications
  system at `docs/superpowers/specs/2026-05-24-notifications.md` is the stable-
  contract index pointing at the canonical v2 SPEC
  (`2026-05-24-notification-architecture-v2.md`). Expanded in this
  batch to include §1-§9 (Context / Goals / Architecture / Cap model /
  Producer list / Consumer LVs / Failure modes / Invariant tests /
  Out-of-scope). Bilingual `notifications.zh_cn.md` added.
- **DONE (low-doc-batch 2026-05-26)** — `ObservabilityLive` workspace
  filter landed earlier (see `apps/ezagent_plugin_liveview/lib/
  ezagent_plugin_liveview/observability_live.ex:30-65` —
  `workspace_filter_for/1` + scoped queries). This batch added the
  regression test
  (`apps/ezagent_plugin_liveview/test/observability_live_test.exs`)
  that fails when the filter is removed.

### ETS-registries hardening (deferred from PR-EM-1 codex r2 HIGH-1)

**Tracked**: PR #315 (PR-EM-1) added Ezagent.ExternalMirror.AdapterRegistry
+ BindingRegistry as `:public` ETS tables, matching the existing
EtsOwner pattern (PluginRegistry, AgentFlavorRegistry, BehaviorRegistry,
etc. are all `:public`). Codex round-2 HIGH-1 flagged that
any in-VM code can call `:ets.insert/2` against these registries
and bypass the validation in `register/1`.

This applies to the **entire EtsOwner pattern**, not just the new
ExternalMirror tables. Only `Ezagent.NotificationSubscriptions`
uses `:protected` + GenServer-serialised writes (per its PR-N1
codex round-2 HIGH-1), and that's because it gates cap-checked
writes specifically.

**SPEC question**: should every contract-enforced registry move
to `:protected` + owning GenServer write API? Or is the current
trust model (plugin code is treated as trusted; the
`:ezagent_plugin_check` compile-time gate prevents accidental
direct calls; the registry API enforces validation when called
properly) the right one?

**Owner**: TBD. Not blocking PR-EM-1; PR-EM-2 dispatch reads
the same tables. If the answer is "yes, harden", the migration
is SPEC + a sweep PR across every registry — out of scope for
the ExternalMirror PR sequence.

### ✅ Plugin-contributed resource types are DROPPED on a Registry restart — RESOLVED 2026-06-24 (Bug B, `fix/resolver-restart-replay`)

> **RESOLVED 2026-06-24 (Bug B).** Approach (a) init-time discovery-replay:
> `Registry.init/1` now rebuilds the **FULL** allowlist from source on EVERY start
> — core `boot_registrations/0` FIRST (claims its backends), then a runtime
> discovery-replay of every loaded plugin's `resource_types/0` via the SAME
> write-once `batch_register` (`replay_plugin_resource_types/0`). Plugin types now
> self-heal on a Registry restart; they no longer vanish until the plugin re-boots.
> This applies the `use Ezagent.Lifecycle` "rebuild-transient-from-source on every
> start" principle (which fixes the #110/#113/#114 cold-restart class) to a plain
> GenServer whose `init/1` IS its every-start hook. HIGH-1 preserved: core first +
> write-once-on-both-`<type>`-and-`backend_component` means a plugin can never
> shadow/alias a core type on either the first-boot or restart path; discovery is
> runtime (Application env + `apply/3`), per-plugin skip-on-error, so a bad plugin
> is logged + skipped, never crashing the Registry. Regression tests:
> restart-self-heal + idempotency + alias-attack-still-rejected in
> `fs_resolver_test.exs`. The sibling EtsOwner registries (Behavior/Template/
> AgentFlavor) still come back empty on an isolated EtsOwner restart — that is a
> separate, lower-severity item (they're start-critical singletons that fail loud),
> tracked below.
>
> ---
> **Original report (OPEN, surfaced 2026-06-24 (PR-2 plugin-resource-type-registration)).**
> `Ezagent.Resource.FsResolver.Registry` is a `:protected`-table-owning GenServer.
> Plugin-contributed resource types are written via `register_all/1` at each
> plugin's `Ezagent.Plugin.boot/2` Phase 2. On a Registry GenServer **restart**,
> `init/1` re-applies ONLY core `boot_registrations/0` (`cc-agents`,
> `codex-agents`, `uploads`) — **plugin types are NOT replayed** (the Registry
> moduledoc states this as an accepted trade-off). So after any Registry crash, a
> live release loses EVERY plugin-contributed resource type until those plugins
> re-boot (which they never do — they already booted). For the first adopter this
> means `world-layouts` resolution silently fails post-restart.
>
> **Verbatim evidence** (instrumented full umbrella `mix test`, 2026-06-24):
> `init/1` ran 4× (1 boot + 3 restarts triggered by `ezagent_core`'s
> restart-resilience tests). World registered once at boot
> (`register_all=[{"world-layouts", …}] -> :ok`), but by the world test phase the
> table held only `[cc-agents, uploads, codex-agents]` — `world-layouts` gone,
> while `world_started=true`. Same class for the sibling EtsOwner registries
> (Behavior/Template/AgentFlavor), which the moduledoc admits come back empty too.
>
> **Scope decision**: NOT fixed in PR-2 (the production boot flow is correct;
> only shared-BEAM test state is affected, and the affected suites were made
> self-contained via `Ezagent.World.ResourceTypeCase.ensure_world_layouts!/0` +
> the inline ensure in `EzagentWeb.WorldHostRoutingTest`). The wiring fix
> (replay plugin types on restart, OR prevent the restart, OR core re-publishes)
> must preserve HIGH-1 (a plugin can never shadow a core type / alias a core
> backend) and is therefore its own brainstorm → spec → codex-review PR.
> **Owner**: TBD (needs Allen 拍板 on the restart-replay mechanism).

### Architecture audit follow-ups
From `docs/notes/2026-05-24-architecture-audit-v1.md` (5 LOW):
1. **DONE** — `Capability.cross_workspace?/2` `apply/3` →
   `Workspace.Store` is documented in `feedback_let_it_crash_no_workarounds`-
   compliant style; layer_purity_test explicit allowlist update
   pending.
2. **DONE** — marketplace toggle deferred record (see top).
3. **DONE (med-batch 2026-05-26)** — `AgentExtensionsLive.authorized_to_toggle?/1`
   uses `Capability.cap_for_action/3` (file:line
   `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_extensions_live.ex:265-279`).
   Audit-time grep across operator scope finds zero remaining
   `%Capability{kind:` hand-constructed structs (one `needed`-map
   site in `session_external_mirror_live.ex:486` uses an
   adapter-supplied `behavior_module`, not `BehaviorRegistry.lookup` —
   different code shape, not a drift risk).
4. **DONE (med-batch 2026-05-26)** — `workspace_sot_test.exs`
   added at `apps/ezagent_core/test/invariants/workspace_sot_test.exs`.
   Greps `apps/ezagent_plugin_liveview/lib` + `apps/ezagent_web/lib`
   for `Workspace.list_persisted/0` / `Workspace.Store.list_all/0` —
   fails with zero allowlist entries.
5. **DONE** (PR-F #297) — `Registration.create_principal/3` "default"
   default arg removed.

### ✅ ExternalMirrorWorker dedupe drops retry-send with reused msg.id — RESOLVED 2026-06-01 (PR #516)

> Dedupe key changed to composite `{msg.id, send_cursor}`; codex also caught
> (HIGH) that the production Lifecycle `%{state: ...}` slice wasn't unwrapped —
> fixed so dedupe works in the real path, with a wrapped-slice regression test.

- **Where:** `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex:469-486`
  (`invoke(:publish)` dedupes by `event_msg_id == slice.last_published_message_id`).
- **Surfaced by:** PR #420 (task #49) codex r4 review of the r3 catchup
  fix. Adversarial check #2 ("can a replayed event share msg id with
  a fresh event?") uncovered a pre-existing dedupe bug ORTHOGONAL to
  CHECK C catchup.
- **Bug shape:** `Chat.invoke(:send)` deliberately bumps `:send_cursor`
  even when `msg.id` is reused (see `chat.ex:394` + `chat.ex:406-412`
  — MessageStore is idempotent on `(id, session_uri)`; the cursor
  delta is what makes `new_slice != slice` for retried sends). The
  Feishu adapter treats every send_cursor delta as a real publish
  (`feishu_adapter.ex:304,321`). But the worker's `event_msg_id ==
  last_published_message_id` short-circuit silently skips the retry
  send as a "duplicate" — even though the adapter contract says it
  should publish. End result: a legitimate retry-send to Feishu is
  dropped.
- **Why NOT fixed in PR #420:** out-of-scope for CHECK C (an
  empty-fanout WINDOW bug). The fix changes dedupe semantics from
  `msg.id` to composite key `(msg.id, send_cursor)` — touches the
  `last_published_message_id` slice field shape + every test that
  asserts on `:duplicate_skip` (currently `worker_publish_test.exs`
  exercises this code path with msg.id-only equality). Deserves its
  own PR with explicit dedupe-contract regression tests.
- **Fix shape (TBD):** rename `last_published_message_id` →
  `last_published_send_key` storing `{msg.id, send_cursor}` (or a
  hashed pair); update the cond at line 472 to compare composites.
  Reachable through replay too — same dedupe path. Need to confirm
  no chat-side flow re-emits the SAME `(msg.id, send_cursor)` pair
  legitimately (it shouldn't — send_cursor is monotonic per
  `Chat.invoke(:send)` invocation, and replay re-delivers the SAME
  event so the pair matches the prior publish exactly).
- **Priority:** MED — limited to chat-send retry path; default Feishu
  send is not retried at the chat layer in V1. Surfaces if/when a
  user clicks "resend" in LV chat UI or an upstream binding/adapter
  call retries on a transient failure.
- **Bonus follow-up (codex r4 LOW):** the regression test in
  `worker_resubscribe_catchup_test.exs` uses `chat.join` (slice-level
  mutation, no `msg.id` in payload), so `extract_event_message_id/1`
  returns nil and the dedupe never fires. Once dedupe is fixed,
  augment the catchup test (or write a sibling) to drive an actual
  `chat.send` through the window so the catchup + dedupe interact
  end-to-end.

---

## Post-lifecycle-migration full E2E findings (2026-05-30, Allen "e2e全量重跑")

> **RESOLVED 2026-05-31** — the migration-introduced (B) findings + the
> highest-stakes pre-existing (A) finding were closed by the remediation batch
> merged 2026-05-30/31, verified on `origin/main`:
> - `:not_ready` readiness regression (B, PRIMARY) → **#493** (`kind/server.ex`
>   `ReadyGate` + `PendingDelivery.flush` buffering present; full umbrella 169→0).
> - `Jason.Encoder not implemented for Ezagent.Capability` silently dropping
>   `cap_granted` from EventLog (A, HIGH) → **#493** (`defimpl Jason.Encoder,
>   for: Ezagent.Capability` in `capability.ex`).
> - destroy-gate + AgentLineage durability (B/C) → **#493** (+ prod migration
>   `20260616000000_agent_lineage_durable_backing`, see `pending-prod-migrations`).
> - cold-restart P6 determinism → **#498**; URI silent-address hardening → **#496**;
>   router facade `Invocation.dispatch`→`Router.dispatch` (#112) → **#494**;
>   home backup/restore CLI (#120) → **#497**.
> - Sandbox-isolation full-run flakiness (A) is **pre-existing test-infra**, NOT
>   migration-caused (deterministic-0 on fresh worktrees; double-digit counts
>   come from concurrent-suite contention / a bisect-churned worktree's drifted
>   test DB — see memory `feedback_fresh_worktree_for_test_measurement`).
>
> Still OPEN from below: the home-portability **durable** profile-relative path
> fix (CLI shipped in #497; structural fix deferred — see
> `docs/notes/home-portability-audit.md`). Findings retained verbatim below.
>
> **Re-verified 2026-06-08:** the (B) migration findings + Jason.Encoder (A)
> remain RESOLVED on `origin/main` — `defimpl Jason.Encoder, for:
> Ezagent.Capability` present in `capability.ex:494`; `ReadyGate` +
> `PendingDelivery.flush` present in `kind/server.ex`. The home-portability
> **durable** fix is STILL OPEN but now NARROWED: the per-agent FS-addressing
> bug class was largely closed by the resource-unification batch P0–P3
> (#658/#664/#665/#669/#670) — all runtime-app-code FS now routes through the
> `resource://` resolver / UriQuery seam (`Ezagent.Resource.FsResolver`),
> `raw_home_path_outside_core` ratcheted to **1**, and the
> `home_path_in_runtime_code` scan gate (#664) hard-fails NEW occurrences.
> The Sandbox slice's `config_dir_path` is, however, still stored ABSOLUTE
> (`apps/ezagent_core/lib/ezagent/behavior/sandbox.ex:31` — "absolute path")
> rather than profile-relative, so backup/restore still relies on the
> rewrite-on-restore path; the "approach 2" structural fix in
> `home-portability-audit.md` is NOT done. STILL OPEN (LOW — backup/restore
> CLI works; structural refinement).

Methodology: phx restarted on complete `d46bd2d2`; live agent-browser + full
umbrella `mix test` (407 files) + isolated chat re-runs + **pre-lifecycle
baseline worktree (`54df56c9`) chat run for apples-to-apples diff**.

### Verdict
- **Live product migration: VALIDATED.** phx boots clean; cold-restart rebuild
  works (7 cc agents respawn from snapshot, ExternalMirror BootReconciler
  reconciles, KindRegistry repopulated — agent-browser screenshot captured);
  `snapshot_restart_test` GATE 3/3 from umbrella root.
- **Automated suite: ~131 raw failures full-run, triaged:**

#### A. PRE-EXISTING (confirmed via baseline diff — NOT migration's fault)
- **Sandbox-isolation flakiness**: chat baseline = 23 failures, ~39
  `DBConnection.ConnectionError` (`owner exited / Client still using
  connection` — spawned Kind.Servers outlive the test that owns the sandbox
  connection). Present pre-lifecycle. Run files isolated/serial to confirm green.
- **`Jason.Encoder not implemented for Ezagent.Capability`** (HIGH, pre-existing):
  baseline 337 / migrated 332 raised `:emit` of `:cap_granted` EventLog rows
  (`identity.ex:361`). The emit is caught ("continuing") so cap_granted events
  are **silently dropped from EventLog**. Fix: `@derive {Jason.Encoder, ...}` on
  `Ezagent.Capability` (+ nested URI/MapSet/DateTime encoders) OR emit a plain
  map payload instead of the struct.
- URI fixture artifacts (`host: {:not,:a,:string}`, `String.Chars.URI`),
  feishu BindingPolicy retired-API, etc. — documented earlier.

#### B. MIGRATION-INTRODUCED (chat: baseline 23 → migrated 43 failures, +20)
- **`:not_ready` readiness regression (PRIMARY, ~6 direct + cascade)**:
  `join`/`subscribe_from` called synchronously right after a Session (re)spawn
  returns `{:error, :not_ready}` instead of buffering. Engine
  `kind/server.ex` ReadyGate/PendingDelivery path was touched by Phase A
  (#478); the documented contract ("dispatch during post-init buffers via
  PendingDelivery and runs after :ready") is NOT covered for the synchronous
  call path now that `activate/2` runs in post-init `handle_continue`,
  widening the not-ready window. Failing: `SessionSurvivesRestartTest — THE
  GATE`, `WorkspaceRegistry rebind on rehydrate`, `PublisherSessionTest
  no-ambient-caps`, etc. **These tests encode a real production invariant**
  (join-right-after-(re)spawn must not be rejected — exactly the cold-restart
  message-loss class the migration was meant to kill). FIX DIRECTION: restore
  buffering for synchronous dispatch during `:not_ready` at the engine level —
  do NOT paper over by making tests await-ready (would mask the regression).
  *Needs Allen's architectural steer (core-engine + behavior change).*
- **destroy-gate semantics change (SandboxDestroyTest, 2)**: after `:destroy`,
  `read`/`write_path` return `{:ok, %{...: nil}}` (empty two-container state)
  instead of `{:error, :destroyed}`. The process-dict `destroyed?` gate was
  intentionally removed in the Sandbox→Lifecycle conversion ("destroyed =
  absence of state"). Either re-add a destroyed sentinel or update the 2 tests
  — decision pending (is read-after-destroy-returns-empty acceptable?).
- two-container parity test-debt (Kind.SnapshotTest etc., few): tests assert
  old flat slice shape `%{identity: %{caps:}}`; product correctly returns
  `%{identity: %{state: %{caps:}}}`. Update the test assertions.
- **home portability (#120) — relativize Sandbox `config_dir_path`**: SHIPPED a
  working `mix ezagent.home.backup` + `ezagent.home.restore` (VACUUM-INTO
  consistent DB copy + rewrite-on-restore of the absolute `config_dir_path` /
  `respawn_template_data` paths buried in `kind_snapshots.state_binary`, e2e in
  `apps/ezagent_core/test/integration/home_migration_test.exs`). DEFERRED the
  durable structural fix: store the Sandbox slice path **profile-relative**
  (`cc-agents/<ws>/<name>`) and resolve against `Ezagent.Home` at read time in
  `activate/2`, so restore needs no rewrite at all. Invasive — touches the
  Sandbox slice contract, the cc Template Class, `:write_path` callers,
  `reconcile_after_load`, + a data migration of existing rows. See
  `docs/notes/home-portability-audit.md` §"Conclusion" approach 2.

- **cc-agent claude credential durability (2026-06-01)** — STILL OPEN (2026-06-08):
  the daily-OAuth-expiry → silent-mute problem persists; durable fix
  (api_key_helper / auto-refresh / spawn-time freshness preflight) not yet
  implemented. Related but DISTINCT from the #17 credential CASCADE (which
  materializes a source cred into the agent's isolated CLAUDE_CONFIG_DIR at
  CREATE time — landed via #592/#641); the EXPIRY/refresh lifecycle is the
  open gap. See also the §5.B follow-up at the bottom (Allen to co-handle).
  cc agents
  (orchestrators + workers) authenticate to Anthropic via the Claude Max
  OAuth token in `<CLAUDE_CONFIG_DIR>/.claude/.credentials.json`, which
  EXPIRES ~daily. When it expires, claude receives channel messages but
  every reply fails `401 Invalid authentication credentials · Please run
  /login` — the agent looks alive (bridge joined, mentions delivered) but
  silently never replies. Found while debugging the orchestrator-chain
  (`[[project_cc_channel_reply_unverified]]`): orch's token had expired
  ~8h prior; refreshed operationally by copying the operator's valid
  `~/.claude/.credentials.json`. DURABLE FIX options: (a) configure an
  `api_key_helper` / long-lived API key for spawned agents instead of the
  expiring OAuth token; (b) ensure the headless claude auto-refreshes via
  its refresh token on launch (it has one — confirm why it didn't); (c)
  a spawn-time credential-freshness preflight that fails loud (or
  refreshes) rather than letting the agent run with a dead token. Until
  fixed, long-lived agents go mute a day after the last login.

- **✅ RESOLVED (PR #517) — inbound feishu: disambiguate multi-session chat binding by @-mention (2026-06-01,
  Allen Q "为什么不能绑定多session")**: the `external_mirror_bindings` data model ALLOWS a
  chat→N-sessions (intended for OUTBOUND fan-out). But INBOUND
  (`InboundChatLookup.resolve/1`) fails closed with `:ambiguous_chat_binding` when a
  chat has 2+ bindings, because it can't decide which session an inbound message
  targets. Improvement: when the inbound message @-mentions a specific agent (e.g.
  `@cc_orchestrator-e2e-orch14`), route to the SESSION that agent is a member of —
  letting one Feishu group host multiple orchestrator sessions, disambiguated by who
  is @-mentioned. Until then, keep one binding per chat (delete stale rows when a
  bound session is destroyed — destroying a session should cascade-delete its
  `external_mirror_bindings` rows; today it doesn't, which is how the orch5/orch14
  ambiguity arose).

- **✅ RESOLVED (PR #508) — AgentTemplate.to_template_data/2 is cc-centric — blocks orchestrator-spawned
  curl/codex workers (2026-06-01, scenario 33 live)**: the mapping only propagates
  `class`/`agent_uri`/`cwd` + the cc-specific optional set
  (`claude_config_dir`/`operator_settings_path`/`operator_mcp_config_path`/
  `api_key_helper`/`role`). It does NOT carry curl's `provider`/`api_url`/`model`
  or codex's `model`/`approval_policy`/`sandbox`. So when the orchestrator's
  `add_agent_slot` spawns a curl/codex worker, the worker's flavor slice gets those
  fields as `nil` — verified live: an orch-spawned curl worker had `provider`/
  `api_url`/`model` all nil (DeepSeek key WAS set on its `:api_keys` slice and
  readable, but it couldn't call the API — didn't know the URL/model). cc workers
  work only because their needed field (`claude_config_dir`) happens to be in the cc
  allowlist. FIX (needs brainstorm + codex spec): make `to_template_data`
  flavor-generic — e.g. the flavor's Template Class declares which content keys to
  thread, or thread all non-reserved content keys. This is THE blocker for live
  multi-flavor full-star (scenario 33 live tier); the deterministic scenario_33 test
  uses synthetic no-PTY flavors so it doesn't exercise this mapping.
- **✅ RESOLVED (PR #509 — root cause: app-server unix socket path exceeded SUN_LEN) — codex worker bridge fails to connect (2026-06-01)**: an orch-spawned codex
  worker spawns + the codex `app-server` procs start, but `codex_bridge.py` logs
  `bridge connection fail` / `codex_thread_id_file_timeout` — the worker never
  becomes reachable. codex CLI 0.134.0 + `~/.codex/auth.json` present. Separate from
  the to_template_data gap; a codex-plugin bridge bug to debug (thread_id file
  handshake / timeout).
- **✅ RESOLVED (PR #518) — add_agent_slot is a synchronous 5s GenServer.call — too short for slow-spawning
  flavors (2026-06-01)**: spawning a codex worker (cold app-server start >5s) made
  `add_agent_slot` return `{:exit, {:timeout, GenServer.call}}` to the caller, even
  though the spawn continued async and the worker Kind was created. The slot-spawn
  should tolerate slow flavors (async spawn + readiness poll, or a longer/ configurable
  timeout) rather than surfacing a spurious timeout.

- **⚠️ PARTIALLY RESOLVED (PR #519 — observability landed) — remove_agent_slot silently drops routing rules that point only to that slot —
  no error, no recovery on re-add (2026-06-01, relay 传话游戏 debug; Allen flagged
  as "又是静默失败")**: `Orchestrator.Tools.remove_agent_slot` GC's every routing rule
  whose ONLY receiver is the removed slot (`RuleStore.delete(rule.id, force: true)`,
  tools.ex ~1095). Defensible as GC, BUT: (a) re-adding the SAME slot name does NOT
  recreate the rules, and nothing warns — so "remove + add" (the intuitive "restart
  this worker") silently loses all routing to it; (b) a subsequent message that then
  matches NO worker rule just falls through to the session default fan-out
  (`$session_users`/`$mentions`) and goes nowhere — no "unroutable to any worker"
  signal. Symptom seen: re-spawned a cc relay worker via remove+add, its `BATON->cc`
  rule was gone, kickoff messages silently went unanswered (looked like the cc worker
  was mute — it wasn't; it never received anything). Structural fixes (no workaround):
  re-add restores the slot's rules, OR remove emits a warning naming the rules it
  cascade-deletes, OR give "message matched no worker receiver" an observable signal
  instead of a silent default fan-out. Also: prefer a non-destructive worker-restart
  primitive (update_agent_template / PTY restart) over remove+add when only swapping
  creds/config.
  > **PR #519 landed the observability half**: each cascade force-delete now emits a
  > `Logger.warning` (rule id + matcher + worker) AFTER the txn commits, and
  > `remove_agent_slot` returns `{deleted_rules, repointed_rules}`. STILL OPEN:
  > (a) re-add restoring a slot's dropped rules, (b) the "message matched no worker
  > receiver" observable signal (the silent default-fan-out half), (c) the
  > disable-not-delete GC option. Confirmed live 2026-06-01: an @-mention to a
  > non-member slot worker silently goes nowhere — that's the (b) gap.
  >
  > **Update 2026-06-05 (verified vs origin/main):** `remove_agent_slot` was
  > RETIRED → replaced by member-model `remove_member` (tools.ex §3.8), which
  > SUBSUMES the #519 observability half — its result reports
  > `deleted_rules` (cascade-deleted, routing LOST + Logger.warning'd) vs
  > `repointed_rules`. So the remove-side observability (a-partial) is done.
  > **Genuine residual = (b)**: the "message matched no worker receiver →
  > silent default fan-out" signal lives in the ROUTING layer, not remove.
  > `Ezagent.Routing.Resolver.resolve_with_ctx/4`
  > (`apps/ezagent_core/lib/ezagent/routing/resolver.ex:190`) treats
  > `system_default` (`$session_users`/`$mentions`) as just another matched
  > rule; there is no signal distinguishing "matched a real worker/member
  > rule" from "only matched system_default" when a message carried
  > `@mentions` that resolved to no member. (b) is a NEW observability
  > feature needing design (signal shape + false-positive guard for
  > legitimate broadcasts) — NOT a quick patch. Recommend a small
  > brainstorm/spec before implementing.
  >
  > **CLOSED 2026-06-06 (Allen).** The remove-side cleanup/observability is
  > done (remove_member: deleted_rules/repointed_rules + cascade-delete
  > warnings). The (b) "no worker matched → silent fan-out" case is NOT a bug:
  > an `@mention` to a non-member is silently dropped by the Resolver's
  > `valid_member?/2` filter (resolver.ex:336) — IM-consistent (@nonexistent =
  > no-op) AND a load-bearing SECURITY boundary (chat.receive runs under
  > `system://chat-router`; delivering to an unvalidated target = privilege
  > escalation). Allen declined the optional UX hint. **Task closed — no
  > remaining work.**

- **✅ `domain.agent` — DONE (verified against origin/main 2026-06-05).** Content
  audit (not SHA — the stale local `domain-agent-foundation` branch's commits are on
  main under different SHAs via #539 + unify-uri-query reshaping): PR-1/PR-DR/PR-4 +
  codex merged via **PR #539**; PR-2 (split `working_directory`→`project_cwd`+`config_dir`)
  done (only comments reference the old name, no live reads); PR-6 `update_member_template`
  on main; the 2026-06-03 config_dir promotion (`claude_config_dir`→`config_dir`,
  fail-loud) merged; PR-3's domain-owns/plugin-materializes architecture landed
  (domain threads `config_dir`, core `Kind.Template` does `allocated_config_dir`,
  `Behavior.Sandbox` owns FS lifecycle + invokes `template_class.destroy_config_dir/2`,
  plugins only materialize). scenario-34 deterministic **8/0** in dev docker; live
  passed 2026-06-03 (old node). ONLY residual = move per-agent config_dir PATH
  COMPUTATION (cc_agent/codex_agent `agent_config_dir/1`) fully into the domain — a
  marginal structural refinement the spec flagged needs compat shims + Allen review;
  NON-blocking. The scenario-34 live re-run in the NEW #21 docker dev env needs Allen's
  dev Feishu app (cli_a97ae) event-subscription config. See [[project_domain_agent_spec]].

- **`domain.agent` abstraction — own per-agent identity + filesystem isolation as a
  structural invariant (Allen 2026-06-02, after E2E acceptance)** [SUPERSEDED by the ✅
  entry above — kept for the original problem statement]: the scenario-34
  live tier surfaced that per-agent resource isolation (cwd / config_dir / `.mcp.json`
  / bridge token) is currently SCATTERED — partly from template data
  (`working_directory`, which a mis-seeded template set to the SHARED
  `~/.ezagent/cc-orchestrator`, so all cc workers clobbered one `.mcp.json` → wrong
  bridge identity → `:no_bridge` silent drop), partly computed ad-hoc per flavor in
  the plugin Template Class. A `domain.agent` would make "an agent is a first-class
  entity with a UNIQUE identity + UNIQUE filesystem sandbox" a domain INVARIANT: the
  domain assigns per-agent working dir / config_dir / token and guarantees uniqueness,
  so no flavor's Template Class (or mis-set template field) can collapse two agents
  onto a shared path. Plugin Template Classes keep only flavor-specific bits (which
  binary, which flags). This makes the whole "shared-path leak" class structurally
  impossible. Ties into: creation-unification (domain.agent IS the agent-creation
  chokepoint), agent-clone-as-domain-primitive, per-agent-config_dir contract, and the
  plugin-isolation north star. The 2026-06-02 cc_agent.ex cwd fix (force per-agent cwd
  in `spawn_for_local_pty`) is the TACTICAL patch; domain.agent is the STRATEGIC home.
  Sequencing per Allen: do AFTER E2E acceptance.

- **Session snapshot WIPED on cold-start (e2e-orch15) — `{:snapshot,:on_change}` +
  empty `activate` overwrites good state (seen repeatedly 2026-06-02)**: the
  `session://default/system/e2e-orch15` snapshot (≈300KB: members/legends/
  prompt_templates/template_working_copy) gets overwritten with a 91-byte empty
  `%{state: %{}}` whenever the Session Kind cold-starts via a path whose `activate`
  returns empty (observed on boot-Loader respawn AND on a misused
  `SpawnRegistry.spawn/1`). Because the Session is `{:snapshot,:on_change}`, the empty
  activate immediately persists, destroying the durable state — and then
  `McpServer.rebuild_from_durable` can't find `template_working_copy.orchestrator_
  template_uri` → orchestrator registration fails (`:orchestrator_not_registered`) →
  orchestrator + tools dead. This is the `lifecycle_case.ex` "activate/2 didn't run or
  returned empty — cold-restart bug class". It BLOCKED the scenario-34 live round-trip
  (kept having to restore the snapshot from a DB backup; it re-wiped on the next cold
  start). Fix: make the Session's `activate` rebuild from the durable snapshot before
  any on_change persist (or guard on_change from writing an empty/partial slice over a
  non-empty one). Lesson recorded: NEVER `SpawnRegistry.spawn/1` an existing entity
  (fresh-spawns empty); revive via dispatch (`lazy_spawn_from_snapshot`).

## domain.agent — config/credential lifecycle gaps (Allen review 2026-06-03)

Surfaced answering Allen's two architecture questions after the scenario-34
cc→codex→curl live E2E passed. Both are NEXT-phase domain.agent scope, NOT in
the domain-agent-foundation PR (that PR is deliverability: PR-DR self-heal,
PR-4 snapshot guard, codex `--last`, table-rename).

- **Per-agent credential lifecycle (NOT implemented; test fixture only).**
  `CcAgent.create_agent_config_dir/2` (cc_agent.ex:1669) cleanly copies a
  template's `claude_config_dir` reference dir → per-agent private dir (cp_r +
  chmod creds + completion marker). But what POPULATES the reference dir with
  credentials is only test plumbing: the demo mix task
  `ezagent.demo.seed_cc_sandbox` (copies `~/.claude/.credentials.json` to
  "avoid re-login") and, during the live E2E, a MANUAL `cp` (not in code at
  all). The real flow Allen wants — **user creates a new agent → logs in
  themselves (claude `/login` inside the agent's sandbox) → credentials are
  saved and reused on future spawns** — does not exist. Proxy config has no
  code path either. domain.agent should own this lifecycle (login → persist →
  reuse) + runtime config (proxy), with a CLEAN separation between the test
  fixture (copy host creds) and the production config interface.

- **Per-flavor config UI (partial + generic; plugin `:form` surface unbuilt).**
  Create is a generic form (`agent_new_live`: flavor dropdown + name/cwd/pty);
  post-create config is spread across generic screens (`agent_detail` /
  `agent_extensions` / `agent_api_keys`). Flavors do NOT provide their own
  config UI: `config_surface/0` is `:route | :flavor | nil` (V1); the `:form`
  surface (plugin-provided config form, store V2 — SPEC §6.1) is noted but not
  built. No UI for cc/claude login or proxy. Decision needed: each flavor
  inherits one generic UI vs provides its own via the `:form` config_surface
  contract — then build it. Ties to the credential-lifecycle item (login UI).

## domain-agent-handoff parked work ledger (2026-06-04)

Source: `/tmp/handoff-esr-docker-pivot-2026-06-04.md` §4. Scope for the
parallel handoff branch is all parked work EXCEPT #21 Dockerize. #21 remains in
the separate cc-openclaw session; this ledger exists so non-#21 work is either
merged into `domain-agent-handoff` or left with a concrete blocker/decision.

- **#27 ComposerMention/AdminLive default session template seed — DONE.**
  Allen chose option B: seed a per-workspace `default` SessionTemplate. Merged
  to `domain-agent-handoff` as PR #559 (`66105e2c`). Targeted tests passed:
  `default_session_template_seed_test.exs`, `composer_mention_test.exs`, and
  the affected Admin/Agent LV suites.

- **PR-A2 codex CODEX_HOME per-agent isolation — DONE.** `CodexAgent` now uses
  ConfigDir namespace `codex`, materializes `auth.json`/`config.toml`, and
  passes `CODEX_HOME` through app-server, bridge sidecar, and PTY launch
  parameters. Merged to `domain-agent-handoff` as PR #560 (`4940f33f`).

- **#17 remaining gap: production auto-refresh-on-spawn — DECISION-BLOCKED,
  do not wire PR-E into production spawn by default.** The current spec
  (`docs/superpowers/specs/2026-06-03-agent-credential-lifecycle.md`) locks D3
  as "credential source resolved + cap-checked at agent CREATE time (human
  caller present), not spawn" and lists "Production runtime auto-refresh (users
  re-login)" under non-goals. `EzagentPluginCc.CredentialRefresh` is also
  documented as "#17 PR-E (TEST/E2E ONLY)" and "NOT for production runtime".
  Therefore the safe handoff status is:
  - production keeps the explicit `/login` + PR-C owner notification flow;
  - PR-E remains a non-prod/E2E provisioner;
  - any spawn-time production refresh/copy needs Allen to approve a new
    cap-checked credential-source model, not a direct call to the test
    provisioner from `ensure_subprocess_alive`.

- **#11 / #533 single authorized create path + manage-cap grant — IN PROGRESS
  IN PR-5 (2026-06-04).** The approved direction is to route user/operator
  session creation through `Ezagent.Workspace.create_session/3`, keep
  instance-message materialization as an internal implementation detail, and
  grant creator Manage caps through the shared create-time grant policy.
  Relevant docs:
  `docs/superpowers/specs/2026-06-02-domain-agent-design.md` §3.3/§4 and
  `docs/superpowers/specs/2026-06-01-unified-kind-creation-via-templates.md`.

- **#24 narrow default user session cap (§3.11) — PROD/#21 ADJACENT BLOCKER.**
  This gates a production Docker image because `Ezagent.ActionSet.Manage` makes
  session management depend on narrowing the current broad default session cap.
  Keep it visible for the #21 prod-image review, but do not fold it into
  Dockerize or merge to `main` from this handoff branch without explicit scope.

- **#20 consolidate test-only snapshot writers — DONE.** Cleanup PR #565 makes
  ordinary tests seed snapshot rows through `Ezagent.Test.SnapshotFixtures`,
  with `test_snapshot_fixture_access_test.exs` preventing new direct fixture
  writes to `Ezagent.Kind.Snapshot.save_now/3` and
  `Ezagent.Ecto.KindSnapshot.upsert/5`. Low-level lifecycle/snapshot invariant
  tests remain explicitly allowlisted because they exercise the primitive
  persistence boundary itself.

- **ExternalMirror flaky tests x3 — RESOLVED.** The flaky publish/rehydration
  failures were isolated from #21 and fixed as ExternalMirror reliability PRs.
  Merged to `domain-agent-handoff` as PR #563 (`017b8d2f`) and follow-up PR
  #566. The fixes make Worker publish tests use unique sessions, wait for the
  Worker's deferred Publisher subscription before asserting publish delivery,
  and wait for cold-spawn re-subscription via the Session publisher subscriber
  map instead of a fixed sleep.

- **#22 harden node RPC/distribution console — GATED SECURITY SCOPE.** Needs
  Allen to choose the deployment posture (dev node convenience vs production
  distribution hardening). Naturally relevant to #21 prod image lockdown, but
  should be a security-scoped PR/spec rather than an incidental Docker change.

- **#25 architecture discussion — DELIVERABLE SHIPPED; refactors IN PROGRESS
  (2026-06-08).** The discussion/proposal deliverable shipped (#610/#613); the
  Phase-2 fitness suite (#640) + Phase-3 deepening refactors (#644-#675, gt_1500
  5→0, gt_1000 17→10) are the follow-on. See the "Architecture clarity" section
  below for the consolidated status.

## Architecture clarity (Allen 2026-06-03) — IN PROGRESS (substantial, 2026-06-08)

> **Status 2026-06-08: SUBSTANTIALLY IN PROGRESS** (#25 architecture-deepening).
> What's DONE: discovery deliverable (`docs/notes/2026-06-07-architecture-deepening-v1.md`
> + `.zh_cn.md`, #610/#613); **Phase-2 fitness suite landed** (#640 —
> `apps/ezagent_core/test/architecture/{oversized_modules,cross_file_duplicate_fn,raw_home_path}_test.exs`
> + `arch_baseline_manifest.exs` ratchet); **Phase-3 refactors in progress** —
> `oversized_modules_gt_1500` driven **5→0** (#644/#657/#660/#663/#667/#672),
> `oversized_modules_gt_1000` **17→10 and counting** (#651/#660/#663/#675),
> plus seam splits (Capability, SessionCreator, Orchestrator MCP/Tools, Chat,
> Workspace membership, template-class resolver). REMAINING: continue
> `gt_1000` burn-down (10 modules left) + any further deepening passes; the
> written discussion/proposal deliverable is shipped, ongoing work is the
> Phase-3 refactor sequence. Tracked under label `arch-deepening`.
>
> **Regression to burn down (2026-06-15):** `ezagent_domain_pty/server.ex`
> crossed 1000 → **1027** via PR #723 (cc-runtime 2.1.170 MCP-trust/bypass
> dialog auto-prompt scanner), so `oversized_modules_gt_1000` cap was bumped
> **1→2** (`arch_baseline_manifest.exs`). Burn-down: extract the dialog-scanner
> state machine from `server.ex` into a focused sibling module (it is a clean
> seam — the PTY-output dialog matcher is independent of the core PtyServer
> loop), then ratchet the cap back to 1. The other oversized module is
> `ezagent_core/kind.ex` (1013).

- **~~Fresh-stack admin lacks create-cap~~ — NOT A BUG (misdiagnosed then
  corrected 2026-06-15).** The `create_session … denied :unauthorized` seen on a
  fresh stack was the **unauthenticated public landing form** (`/`) creating "as
  admin" with NO loaded caps — correct fail-closed behavior, not a missing
  grant. The documented flow works: `mix ezagent.user.set_password
  entity://system/user/admin --password <pw>` → log in at `/login` with the FULL
  URI → the authenticated session loads admin's wildcard caps
  (`Identity.caps_for/1`) → `create_session` is **granted** → the cc orchestrator
  comes up. **LIVE-VERIFIED 2026-06-15** on the fresh disposable stack: after
  login, `/sessions` shows `session://system/default/main` with the ORCHESTRATOR
  panel **alive**, `cc_orchestrator-main` **online**, **1 bridge connected**;
  logs show `orchestrator_not_registered`=0, `did NOT join`(90s timeout)=0,
  `orch:bridge JOINED`=1, `create_session granted`=1 — i.e. PR #783's
  orchestrator-readiness fix works end-to-end. (Operator note: a fresh stack has
  no admin password — set it first; the public `/` form is an anon/dev entry and
  is NOT the admin path.)

- **Repair-path orchestrator pre-store + readiness/binding separation
  (follow-up to PR #783, 2026-06-15)** — OPEN. PR #783 pre-stores the planned
  orchestrator URI before the readiness gate ONLY on the fresh-create path
  (`new_session?: true`), where any failure rolls the whole session back. The
  repair/restart path is NOT pre-stored — its EXISTING binding (== planned,
  preserved through `materialize_orchestrator_working_copy/3`) already resolves
  the live join, so a normal orchestrator restart works. The remaining gap is
  the NARROW case of repairing a session whose stored `:orchestrator_uri` is
  absent/nil (e.g. upgraded-from-plain), which still hits the original live-join
  deadlock. Pre-storing on the repair path is NOT a clean fix because the
  `:orchestrator_uri` field is OVERLOADED: it is both (a) the join-auth binding
  the live MCP join resolves against (needs to exist EARLY) and (b) the
  `session_complete?/4` readiness proof via `OrchestratorReadinessPort.ready?/1`
  → `McpServer.from_orchestrator_uri/1` (should be true only when FINALIZED).
  Pre-storing on the keep-the-live-session repair path makes a concurrent
  `session_complete?` read it as PREMATURE readiness (codex review, 4 rounds).
  The proper fix is to SEPARATE the two: add a durable `orchestrator_finalized`
  marker (set at step 6/7, survives restart) that `session_complete?` checks for
  readiness, leaving `:orchestrator_uri` purely as the join-auth binding that the
  pre-store can safely write early on BOTH paths. Then extend the pre-store to
  the repair path with prior-binding restore on failure.
  `session_creator.ex` `ensure_orchestrated_session/6` + the cc `McpServer` /
  `OrchestratorReadinessPort` readiness check.

- **Install + run `improve-codebase-architecture` skill to clarify the Ezagent
  architecture.** Skill installed at `.claude/skills/improve-codebase-architecture/`
  (cc-openclaw). Use it (informed by `UBIQUITOUS_LANGUAGE.md` + the `GLOSSARY.md`
  decisions log) to surface "deepening opportunities" — shallow modules, leaky
  seams, RBK / Kind / Behavior / Template / domain.agent layering friction — and
  discuss how to make the codebase deeper, more testable, more AI-navigable. The
  discussion + proposals are the deliverable. ✅ Done as #610/#613/#640 +
  Phase-3 (#644-#675); see status note above.

- **cc/codex agent interactive-login + clean authenticated-terminal screenshot
  (§5.B follow-up; Allen to co-handle).** STILL OPEN (confirmed 2026-06-08 —
  deferred by PR #661; Allen to co-handle, needs interactive login + judgment).
  §5.B cascade credential INHERITANCE is
  proven at the mechanism level (#641 `cb49a7e3`: unified create routes file-flavor
  agents through the #17 cascade → grant minted, source `.credentials.json`
  materialized into the agent's ISOLATED `CLAUDE_CONFIG_DIR` (not operator
  `~/.claude`), headless `claude --print` returns AUTHENTICATED exit 0 with no
  per-agent `/login`; the management-UI Credential-cascade panel confirms the
  resolved layer stack + source + active grant). REMAINING GAP vs the E2E bar:
  claude v2.1.162's INTERACTIVE PTY still shows "Select login method" despite a
  valid materialized cred — a claude-TUI-version + PtyServer theme/login dialog
  scanner-timing artifact (relates to the #39 `:theme_dialog` auto-prompt). To do
  together: (a) get a clean agent-browser screenshot of an authenticated cc
  terminal (no /login, no theme dialog); (b) fix the theme/login-dialog scanner
  timing so interactive cc agents reach the authenticated prompt; (c) the
  source-agent `config_dir` cred is non-durable across the source's own respawns
  (re-provision needed) — an E2E-provisioning durability gap to close. Needs
  Allen's cooperation (interactive login + judgment).

---

## Resolved 2026-06-08 verification batch

> Consolidated index of items VERIFIED-RESOLVED in the 2026-06-08 verification
> pass (`chore/cleanup-todo-refresh`, checked vs `origin/main` @ `88d608f2`).
> Each is also tagged inline above.

- **Capability struct action-axis (codex PR #356 r1 CRIT)** — RESOLVED.
  Evidence: SPEC `2026-05-27-capability-action-axis.md` implemented;
  `Ezagent.Capability` defstruct has `action: :any`; `matches?/2` checks the
  action dimension (`apps/ezagent_core/lib/ezagent/capability.ex`).
- **Codex PR #356 HIGH-2 (UserTokens combined-Behavior shared cap subject)** —
  RESOLVED by the action-axis (mint/list/revoke now per-action distinguishable).
- **#25 architecture-clarity discovery deliverable + Phase-2 fitness suite** —
  RESOLVED. Evidence: #610/#613 (deepening v1 docs), #640
  (`apps/ezagent_core/test/architecture/*` fitness tests +
  `arch_baseline_manifest.exs`). Phase-3 refactor sequence is IN PROGRESS
  (gt_1500 5→0 done; gt_1000 17→10 in progress).
- **Resource/FS-addressing unification (P0–P3)** — RESOLVED for runtime-app-code.
  Evidence: #658/#664/#665/#669/#670; `Ezagent.Resource.FsResolver` resolver;
  `raw_home_path_outside_core` baseline = **1**; `home_path_in_runtime_code`
  scan gate (#664) hard-fails new occurrences; uploads via resolver + signed-
  token download contract (#669). (Durable profile-relative Sandbox
  `config_dir_path` is a NARROWED residual — see home-portability item, OPEN.)
- **Back-compat / dead-code / fork cleanup batch (#673/#676/#677/#678)** — RESOLVED.
  Evidence: `routing.add_rule` deprecation stub DELETED (no routing mix task
  remains); forked fns deduped — `check_agent_uri/1`, `content_field/2`,
  `reject_stale_config_dir_data_key!/1`, bridge-adapter (#676,
  `arch_baseline_manifest.exs`); `/cc_socket` shim layer removed, all 4 shim
  modules deleted + endpoint unmounted, `cc_bridge_shim_callers: 0` gate
  (#677, `cc_bridge_shim_test.exs`); compile warnings fixed + FF-3
  `--warnings-as-errors --force` dead-code gate added (#678, `mix.exs:122` +
  `compiler_dead_code_gate_test.exs`). NOTE: deprecated `mix esr` / CLI↔GUI
  tasks were KEPT on their own timeline (NOT removed by this batch).
- **E2E findings: Jason.Encoder for Capability (HIGH) + `:not_ready` regression
  + destroy-gate/AgentLineage durability** — RESOLVED (#493 et al, re-verified
  2026-06-08). Evidence: `defimpl Jason.Encoder, for: Ezagent.Capability`
  (`capability.ex:494`); `ReadyGate` + `PendingDelivery.flush` in
  `kind/server.ex`. (Sandbox-isolation flakiness = pre-existing test-infra, not
  a code bug.)
- **ExternalMirrorWorker dedupe composite key (#516)** — RESOLVED.
  Evidence: `last_published_send_key: {term(), non_neg_integer()}` composite in
  `external_mirror_worker.ex` (was already ✅; re-confirmed).

### external_mirror `facade_test` PG-sandbox flake — OPEN (LOW, pre-existing)

> Surfaced 2026-06-22 (dev-together close, lead Claude). `Ezagent.ExternalMirrorTest`
> `test/ezagent/external_mirror/facade_test.exs:91` (`sessions_for_adapter/2 returns
> {:ok, []}`) intermittently exits with `DBConnection.Holder.checkout … owner … exited`
> under the PG sandbox — passes in isolation + in most full runs (4611/0 ×3), failed
> 1 full run. Sibling spawn-storm tests churn the shared sandbox connection pool and
> kill the facade test's owner connection. NOT a close regression (no merge touched
> `apps/ezagent_domain_external_mirror`). Fix: same `EzagentCore.DataCase` / `async:
> false` hardening pg applied to `repair_orchestrator_test`. Owner: external_mirror/pg.

---

## Agent console QA findings (from #1027, triaged 2026-07-03)

> Triage of the 7 QA findings (F1–F7) raised in PR #1027 / the QA branch
> `qa/agent-console-findings-0626` (original report basis: main `6f123b8b`,
> 2026-06-26), re-checked against `origin/main` @ `5a6dd484`. The agent-console
> rework that followed (SessionTemplate directly-creatable filter, socialware
> remove-participant, agent-delete guard + detail-route error) landed most of
> these; the fix commits carry explicit `F#:` markers, traced end-to-end below.
> Only ONE actionable residual survives (F7's missing session-delete/archive
> control). #1027 can be closed once this residual is recorded here.

### F7 (residual) — no session delete / archive control — OPEN (LOW-MID)

> Session conversation page still has NO delete-session / archive-session /
> end-session control (only Invite, Restart orchestrator, per-member Remove, and
> routing rules). Evidence: exhaustive grep across `apps/ezagent_plugin_world/lib`
> + `apps/ezagent_plugin_world/assets/src` finds no session delete/archive/end
> action — `@conversation_actions` (`world_live.ex:262`) has no `session.delete`;
> `Conversation.tsx` has no delete/archive button.
> NOTE — the ORIGINAL HIGH-impact half of F7 ("占用中的 agent 根本删不掉" — an
> occupied agent could not be deleted via the UI) is **RESOLVED**: a per-member
> Remove control now exists (`Conversation.tsx:728-737` → `onRemoveParticipant`
> → `main.tsx:350` `session.remove_participant` → `conversation_actions.ex:627`
> → `Ezagent.Session.Participants.remove_participant/3`). Traced end-to-end:
> removal mutates the `Session.session_member_uris` slice
> (`participants.ex:88-95`), which is exactly what the agent-delete guard
> `agent_live_sessions/1` counts (`.../session_creator/listing.ex:37-41`) — so
> removing the agent from its sessions clears the guard and the delete proceeds.
> Residual is therefore lower severity: you can move an agent out session-by-
> session, but you still cannot delete/close the now-empty session itself.
> Suggested fix: add a session delete/archive entry (owner-cap-gated, mirror the
> `remove_participant` dispatch pattern) on the conversation page + sessions table.

### Dropped as FIXED (verified against `origin/main` @ `5a6dd484`)

- **F3 (was HIGH) — new-session default template `advisor` invalid + create
  failure silently swallowed** — FIXED. `session_template_names/1` now always
  leads with `"default"` (`workspace_plugin_data.ex:215`) and filters out
  non-`directly_creatable?` classes like `advisor`
  (`workspace_plugin_data.ex:188-231`); the React picker takes `templates[0]`
  (`SessionsTable.tsx:29,33`). Create failures now push `create_error`
  (`conversation_actions.ex:293-296`) which the table renders as a banner
  (`SessionsTable.tsx:89-95`). Fix carries `F3:` markers.
- **F4 (was MID-HIGH) — occupied-agent delete blocked correctly but banner
  invisible (pushed to list route, not the detail page)** — FIXED. Delete error
  now rebuilds the DETAIL route (`agent_actions.ex:188-210`, `F4:` comment) and
  `AgentDetail` renders `action_error` where the Delete button lives
  (`Identities.tsx:706-713`); backend guard intact (`agent_actions.ex:151`
  `agent_live_sessions → {:ok, []}`). Banner text matches the suggested copy
  ("…先从这些对话移出再删除").
- **F6 (was MID) — py `script` not marked `*` / not enforced client-side; bare
  `:missing_script` atom** — FIXED. Backend advertises
  `script_required_flavors: ["py"]` (`identity_data.ex:155`); form marks `*` and
  disables Create when empty (`Identities.tsx:819-820,980,1030`, `F6:` comment);
  `:missing_script` now maps to a friendly message
  (`identity_data.ex:369-370`).
- **F1 (was LOW-MID) — agents list has no flavor filter** — FIXED. `AgentsTable`
  is now wired to `FilterBar` (`Identities.tsx:552`, flavor links at 1616-1621)
  AND has a free-text query filter whose haystack includes `agent.flavor`
  (`Identities.tsx:526,551`).
- **F2 (was LOW-MID) — deleted detail URL renders a hollow shell** — FIXED.
  `AgentDetail` renders a clean not-found empty state on `agent_not_found`
  (`Identities.tsx:672-685`, `F2:` comment); backend sets `agent_not_found`
  when there is no live process and no snapshot (`identity_data.ex:114-133`).
- **F5 (was LOW/cosmetic) — Entity Caps `instance` column dumped the raw
  `%URI{}` struct** — FIXED. `CapData.instance_scope_display/1` renders the
  canonical URI string (`cap_data.ex:31` → `encode_uri` → `URI.to_string/1`);
  the `entity_caps` surface reads `CapData.list_entity_caps/3`
  (`identity_data.ex:101`).
### arch-gate AST hardening — batch 2 (high-value, hard) — OPEN

> Surfaced 2026-07 (arch-gate AST conversion, lead Claude). **Batch 1 DONE**
> (branch `gate/ast-convert-batch1`): converted 6 grep-based counters to
> AST-based matchers in `mix/tasks/ezagent.arch.scan.ex` — `plugin_defined_kinds`
> (alias-resolved `@behaviour Ezagent.Kind` exactly), `spawn_registry_call_sites`/
> `_modules`/`_off_chokepoint_modules` (alias-resolved `SpawnRegistry.spawn[_detailed]`
> remote calls, parens-only), and `create_session_call_sites`/`_modules` (the
> `create_session` facade call). Each has a `*_in_source` testable entry point + a
> teeth-test proving the matcher fires on an ALIASED call a raw grep would miss
> (`spawn_chokepoint_test.exs`, `plugin_defined_kinds_test.exs`). The conversion
> also tightened 4 loose ratchets (grep had over-counted moduledoc/comment mentions
> and a `&Mod.fun/arity` capture — all documented in `arch_baseline_manifest.exs`).
>
> **Batch 2 — convert these 3 to AST + teeth-tests** (harder: semantic, not just
> module/call-site matching):
> - `missing_cap_check_mutating_actions` — SECURITY invariant. Today it string-scans
>   `kind/runtime.ex` for `behavior_module.required_caps()` + `Capability.matches?`
>   presence. AST version: verify each MUTATING action handler actually reaches a
>   cap-gate call on its path (not merely that the strings exist somewhere), so a
>   new mutating action without a cap check trips the gate.
> - `kind_runtime_ordering_violations` — dispatch-pipeline ORDER invariant
>   (`authz_check` → `workspace_isolation_check` → `invoke_behavior`). Today it uses
>   `:binary.match` byte offsets; AST version should assert the order structurally
>   within the pipeline function so a reformat/refactor can't fool the byte scan.
> - `kind_runtime_reentry_violations` — no `Invocation.dispatch(`/`Router.dispatch(`
>   inside `target_ownership_check`/`event_to_payload`. Today it regex-slices the
>   function body; AST version should walk the actual function clause bodies.
>
> Note: **AST + teeth-test are complementary** — AST cuts rename/formatting
> false-negatives (an aliased or reformatted call can't slip past); the teeth-test
> catches a TOOTHLESS gate regardless of cause (e.g. a matcher that silently matches
> nothing after a refactor). Batch 2 needs both, same as batch 1.

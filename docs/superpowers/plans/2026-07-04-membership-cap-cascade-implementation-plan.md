# Membership-Cap Unification + Cascade Notification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "member of session S" a **capability the member HOLDS** (`cap(:session, Ezagent.ActionSet.Session, :receive, instance: S, ws)` in the member's own `:identity`/`:caps` slice), demote the session `:members` slice to a delivery/presence cache, move receive- and read-authorization onto the held cap, and add a one-level manage/owner **cascade notification** on cap/membership changes.

**Architecture:** Four merge-safe phases landing one architecture (spec §12): **A1** adds the member-cap as an *additive, behavior-preserving* foundation (grant-at-join + reconcile + migration) while delivery still uses the old ephemeral mint; **A2** is the atomic cutover (receive/read authz read the held cap, the ephemeral mint is deleted, leave/remove revoke the cap) — this phase carries the **defense-in-depth** revoke→immediate-deny done-gate; **B** rides on A2's member-slice-change to notify managers/owners. A1→A2→B = **detect + react**. **C — the admission gate (owner-approval-to-mount, spec Part C / R4)** adds **PREVENTION**: a cross-owner add goes PENDING and does not mount (spend the owner's credential) until the member's owner approves — this phase carries the **PRIMARY** §14.5 done-gate and **closes the motivating threat X**. Roster (staleness-tolerant delivery targeting) is kept **⟂ separate** from receive-authorization (the recipient's *actually held* cap) — R1.1, the load-bearing invariant that also gives Part C its "pending cannot receive" property for free.

**Tech Stack:** Elixir umbrella (`apps/ezagent_core`, `apps/ezagent_domain_session`, `apps/ezagent_domain_identity`, `apps/ezagent_domain_agent`, `apps/ezagent_plugin_world`), Ezagent Lifecycle/ActionSet Behaviors, CapBAC capability primitives, ExUnit, `mix ezagent.*` CLI tasks, agent-browser for the UI acceptance scenario.

**Spec:** `docs/superpowers/specs/2026-07-04-membership-cap-unification-cascade-design.md`. **Precedence R4 > R3 > R2 > R1 > prose.** Read R4 + Part C (admission gate), R3.1 (reframed REMOVE), R1.1 (roster⟂authz), R2.3 (2 receive sites), §14.5 (done-gate — PREVENTION primary, revoke-deny defense-in-depth) before implementing.

## Global Constraints

- **Precedence when the spec conflicts with itself:** R4 > R3 > R2 > R1 > original prose. Several original §§ (§4.2, §5, §6, §8, K1, K6) are patched by later R-sections; §15's admission deferral is superseded by R4/Part C; always follow the latest R-section.
- **Admission gate (Part C, K7) withholds the member-cap ONLY — it is orthogonal to the join-cap, and is a requirement over ALL member-add entry paths (spec §C.1), checked at the COMMON chokepoint `handle_join/2` (`session.ex:588`), NOT scoped to one invite function.** ⚠️ CORRECTED (completeness review): scoping the trigger to `provision_invited_join_authority/3` UNDER-FIRES — the World-UI invite button `invite_member/3` (`conversation_actions.ex:395-427`) dispatches `session.join` directly with B's caps and NEVER calls that function, and `handle_join/2` checks only liveness, not manage-authority. Every member-add (World `invite_member/3`, orchestrator `join_member`, materializer, direct `session.join`) funnels through `handle_join` → the `do_join_apply` grant seam. Fire pending ONLY when `ctx.caller` (already in scope at `handle_join`) is a **real, non-system** entity that is neither the member nor a manager of it. **Do NOT** read `manages?` off `ctx.caps`: the materializer's caller is `Entity.User.admin_uri()` with only a narrow inline join cap (`materializer.ex:182-212`; `system://session-internal` was ELIMINATED #154) — `manages?(admin, member)` MUST resolve admin's DURABLE identity caps (genesis wildcard) or every team-template spawn pends forever (§16 risk 5 / §C.1 warning). Non-add mounts (materializer/admin, self-join incl. anon `caller==member`, own-agent/admin add) mount immediately, unchanged. Migration + `reconcile_after_load` seed under system authority — NOT caller-initiated adds, do NOT pend. Do not conflate the two layers: invite-authority = "may B initiate an add"; admission = "does that add mount now or wait for the owner". **Plan-time seam:** the check sits at the grant seam keyed on `ctx.caller` — no `inviter_uri` threading needed (the caller IS the inviter at `handle_join`).
- **Roster ⟂ authz (R1.1) is the non-negotiable invariant.** The `:members` projection is *delivery targeting only* and is **staleness-tolerant**. Authorization (receive AND read) is ALWAYS the recipient's/caller's **actually-held** member-cap. The projection is NEVER the authority. A stale roster entry costs a wasted delivery attempt that then fails authz — never an unauthorized receive/read.
- **No bearer tokens.** Delivery presents **NO** receive cap in `ctx.caps`. `member_receive_caps/1` is deleted, not replaced by a cache.
- **CapBAC discipline (read `references/capbac.md` before any grant/revoke/cap code):** granter ≠ caller; `granted_by = owner_uri` (ownerless → the #154 admin granter, logged + counted); provenance filter `Capability.granted_by_entity?/1` runs BEFORE `matches?/2`; revoke matches by 5-tuple `identity_key/1`, not full struct (invariant #19).
- **Read LIVE caps, never `users.caps_json`** (K5). Use `Ezagent.Identity.read_entity_caps/1` (`identity.ex:336-341`, live→snapshot). `caps_json` is a `:string` provisioning column (`users.ex:27`); scope tuples live in the live slice.
- **Behavior authored via `use Ezagent.Lifecycle` only** (2026-05-29 contract). Never hand-write `use Ezagent.ActionSet`/`init_slice`/`invoke/4` in developer code. Read `references/lifecycle.md` before any Behavior edit.
- **Cross-app placement (`undeclared_umbrella_dep_test`):** `Ezagent.Entity.Agent` lives in `apps/ezagent_domain_agent`. `apps/ezagent_domain_session` already deps `ezagent_domain_agent` (R2.6 CONFIRMED), so referencing it from the session reconcile is fine. If a caller in `ezagent_core`/`ezagent_domain_identity` needs it, route through an existing cross-app seam (a `UriQuery`-style enumerator or the identity layer), not a hard ref.
- **Per-phase gate (spec §12):** each phase gets `/codex:adversarial-review` BEFORE implementation and again at PR open (project convention `feedback_codex_review_every_pr`, `feedback_spec_codex_adversarial_review`).
- **DEMOTED / PROPOSED mechanisms stay open.** Where the spec demotes an item to "state the requirement + test, implementer picks the mechanism" (R3.2) or leaves a PROPOSED seam (R3.1 revoke inline-vs-deferred, R3.2 replay/notify wiring, migration idempotency predicate + sync flag, teardown authority/execution split, the `MemberReceive.authorize` predicate shape) — this plan pins the **constraint + acceptance test** and lets the implementer choose the code. Do NOT re-specify the predicate/tuple/effect-grammar/flag. These are the ONLY places this plan intentionally omits concrete code (a task-licensed departure from writing-plans' no-placeholder rule); everywhere else, code and tests are concrete.
- **Line numbers:** cited file:line are grounded in this worktree (`docs/cascade-notification-spec`, 2026-07-04). A few drifted from the spec's cites and are corrected here (e.g. `user/receive.ex` `caps:` at :114 / `handle_receive` at :144; `membership_predicate.ex` `member?/2` at :76-79). Re-grep before editing; treat line numbers as anchors, not addresses.

---

## Phase / PR / done-gate map (read first)

| Phase | What lands | Ships behind existing behavior? | PR | Done-gate |
|---|---|---|---|---|
| **A1** | member-cap grant at join (all member kinds) + `Entity.Agent.list_in_workspace/1` + `reconcile_after_load/2` seeding + `mix ezagent.migrate.member_caps` | **YES** — additive, behavior-preserving; delivery still mints ephemerally | **PR-1** | Tests 1-5, 23(preflight/compensation subset), 26; migration `--dry-run`/`--gate` correct; existing suite green (mint untouched) |
| **A2** | receive-authz cutover (`MemberReceive.authorize/1`, `:receive` cap_exempt, parity test) + **delete `member_receive_caps/1`** + socialware read → held-cap + leave/remove revoke (3 R3.1 sequences) + post-commit replay/notify + anon holds member-cap + **ExUnit defense-in-depth acceptance (§14.5 A step 5)** | **NO** — atomic cutover; must land as one | **PR-2** | Tests 6-12, 20-24; **§14.5(A) step 5 (revoke ⇒ deny) passes WITHOUT reconcile** — the defense-in-depth load-bearing assertion |
| **B** | extract `Ezagent.Identity.Authority` (K2) + cascade hook at emit chokepoint (K3) + `managers_of/1` (K4/K5) + content-free notify + cascade E2E (§14.5 A step 6) | **YES** — additive advisory notify, off the mutating path | **PR-3** | Tests 13-19; §14.5(A) step 6 (grant/revoke cascade to X, removal-notify) |
| **C** | admission gate (Part C/K7): trigger branch (`manages?(caller, member)` → mount-now vs pending) + `:pending_members` slice + approve/deny/withdraw actions + pending-member-as-subject notify + **§14.5(A) PRIMARY prevention acceptance** + agent-browser approve-UX scenario (§14.5 B) | **YES** — additive; security half entirely composed (R1.1 + R3.1) | **PR-4** | Tests 27-32; **§14.5(A) step 2 (pending cannot receive → cred not spent) — the PRIMARY assertion that X is closed** + steps 1,3,4; §14.5(B) three screenshots captured |

**Independently shippable:** A1 alone (foundation); B alone on top of A2 (cascade is additive/advisory); **C alone on top of A2+B** (admission is additive — its security half is entirely composed from R1.1+R3.1, its notify from B). **Must land together:** the whole of A2 is one atomic landing — see the A2 preamble for why (§14.5 step 5 is the defense-in-depth done-gate that can only pass when receive-reads-held-cap AND leave/remove-revoke-held-cap both exist). **Recommended: 4 PRs (A1, A2, B, C).** Optional internal splits noted per phase for reviewability, but A2's sub-tasks may NOT merge independently. **X is not closed until PR-4 (Phase C) lands** — A1→A2→B are detect+react; C adds the prevention that makes B's cross-owner pull unable to spend the owner's credential.

**Human/lead-action steps (flagged inline with 🧑):**
- 🧑 **Before A2:** lead sign-off on spec §16 open-risk #4 — the behavior shift "failed member-cap grant ⇒ not a member" (best-effort → fail-closed for the membership-defining cap). Spec explicitly defers this to the lead.
- 🧑 **Before C:** lead sign-off on spec §16 open-risk #5 — cross-owner adds that previously mounted immediately now go PENDING until the owner approves. This is the intended prevention of X but a user-visible change to existing add-others'-agent collaboration flows; confirm intended. (Manage-authorized adds — own agent/self-join/admin — are unchanged.)
- 🧑 **A1 deploy-time:** operator runs `mix ezagent.migrate.member_caps` (with `--dry-run` first, then live) in each environment. R2.2: live-grant write is safe on a running node, but the *decision to run* is an operator action.
- 🧑 **Per phase:** `/codex:adversarial-review` gate (pre-impl + at PR open).
- 🧑 **§14.5(B):** the agent-browser world-UI scenario needs a running disposable stack (fresh `EZAGENT_HOME`, dev mode, PORT — `feedback_disposable_stack_e2e`); operator/environment-dependent. Under Phase C this scenario captures the **approve UX** (add→pending→approve→mounted), three screenshots.

---

# PHASE A1 — member-cap model + migration (foundation, additive, behavior-preserving)

**Phase goal:** Member-caps exist and are authoritative for every member (users, agents, anon), seeded at join and by a migration, with reconcile as the steady-state backstop — while delivery/receive/read are UNCHANGED (still use the ephemeral mint). Nothing yet depends on the member-cap for delivery, so this phase is purely additive and merges alone.

**Phase dependencies:** none.

**Phase done-gate:** tests 1-5, 26, and the A1 subset of 23 (join role-conflict → no orphaned cap; join-fail-after-grant → compensating revoke) pass; `mix ezagent.migrate.member_caps --dry-run`/`--gate` behave per test 25; the full existing suite stays green (proof the mint/delivery path is untouched).

---

### Task A1.1: Define the member-cap constructor + agent enumerator

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` (add a private `member_cap/2` helper near `mount_participation_caps/2` at :805)
- Create: `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex` **only if** `Ezagent.Entity.Agent.list_in_workspace/1` has no home module (grep first — `agent_role_resolver.ex` is the pattern source, `apps/ezagent_domain_agent/lib/ezagent/agent_role_resolver.ex:35-64`)
- Test: `apps/ezagent_domain_agent/test/ezagent/entity/agent_list_in_workspace_test.exs`

**Interfaces:**
- Produces: `Ezagent.Entity.Agent.list_in_workspace(ws :: URI.t()) :: [URI.t()]` — workspace-scoped, type-filtered, live **and** dormant agent URIs.
- Produces: `member_cap(session_uri :: URI.t(), workspace_uri :: URI.t()) :: %Ezagent.Capability{}` = `Ezagent.Capability.cap(:session, Ezagent.ActionSet.Session, :receive, session_uri, workspace_uri)` (arg order per `capability.ex:144-155`; behavior is the MODULE ref, invariant #2, not an atom).

- [ ] **Step 1: Write the failing test (test 26 — agent enumeration, R1.4)**

```elixir
# agent_list_in_workspace_test.exs
test "list_in_workspace returns a DORMANT agent, excludes users and other workspaces" do
  ws = test_workspace_uri()
  dormant = create_agent_snapshot_only(ws)        # snapshot row, NOT live/ETS
  _user = create_user(ws)
  _other = create_agent_snapshot_only(other_workspace_uri())

  uris = Ezagent.Entity.Agent.list_in_workspace(ws)

  assert dormant in uris
  refute Enum.any?(uris, &user_uri?/1)
  refute Enum.any?(uris, fn u -> Ezagent.Capability.workspace_of(u) != ws end)
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test apps/ezagent_domain_agent/test/ezagent/entity/agent_list_in_workspace_test.exs`
Expected: FAIL — `Ezagent.Entity.Agent.list_in_workspace/1` undefined.

- [ ] **Step 3: Implement `list_in_workspace/1`** modeled exactly on `agent_role_resolver.ex:35-64` (snapshot scan, NOT ETS — so dormant agents survive a BEAM restart):

```elixir
def list_in_workspace(%URI{} = ws) do
  Ezagent.Kind.KindSnapshot.list_in_workspace(ws)          # repo, workspace-scoped (kind_snapshot.ex:72-78)
  |> Enum.filter(&(&1.kind_type == Atom.to_string(Ezagent.Entity.Agent.type_name())))
  |> Enum.map(& &1.uri)
  |> Enum.map(&Ezagent.URI.parse!/1)
end
```

- [ ] **Step 4: Run to verify it passes.** Run: `mix test .../agent_list_in_workspace_test.exs` → PASS.

- [ ] **Step 5: Add the private `member_cap/2` helper** in `membership.ex` (no separate test — it is exercised by Task A1.2's test 1):

```elixir
defp member_cap(%URI{} = session_uri, %URI{} = workspace_uri) do
  Ezagent.Capability.cap(:session, Ezagent.ActionSet.Session, :receive, session_uri, workspace_uri)
end
```

- [ ] **Step 6: Commit.**

```bash
git add apps/ezagent_domain_agent apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex
git commit -m "feat(session): add member_cap/2 + Entity.Agent.list_in_workspace/1 (A1.1)"
```

---

### Task A1.2: Grant the member-cap at join (all member kinds, grant-first + compensation)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` — the at-join grant flow (`mount_participation_caps/2` :805-881; the non-user no-op `mount_participation_caps(_, _), do: :ok` at :814 must gain an agent branch; `already_authorized?/5` at :888; `role_name_conflict/3` preflight at :48; `do_join_apply` projection at :127-135)
- Test: `apps/ezagent_domain_session/test/ezagent/session/member_cap_join_test.exs`

**Interfaces:**
- Consumes: `member_cap/2`, `Ezagent.Entity.Agent.list_in_workspace/1` (A1.1).
- Consumes: `already_authorized?(held, behavior, action, session_uri, workspace_uri)` (`membership.ex:888`, idempotent skip-already-held), `Ezagent.Identity.Grant.grant_cap_via_router/4` (`grant.ex:121-141`).
- Produces: after a successful join, EVERY member (user, agent, anon) holds `member_cap(S, ws)` in its `:identity`/`:caps` slice.

**JOIN sequence to implement (R2.1 restated, grant-first + preflight + compensate):**
1. Preflight `Members.role_name_conflict/3` (`membership.ex:48`) — already runs before `do_join_apply`, zero side effects on conflict. **Grant must be placed AFTER this.**
2. Grant `member_cap(S, ws)` — idempotent skip-already-held via `already_authorized?/5`. `granted_by = owner_uri` (ownerless → #154 admin granter).
3. `do_join_apply` → projection `{:set, :members, …}` (`membership.ex:127-135`).
4. **Compensation:** if the commit fails AFTER the grant, revoke the just-granted member-cap (de-escalating, needs no authz — `grant.ex:108`).

- [ ] **Step 1: Write the failing tests (spec tests 1, 2, 3)**

```elixir
# member_cap_join_test.exs
test "join grants the member-cap into the member's identity caps (granted_by = owner)" do
  {session, owner} = create_session_with_owner()
  member = create_user(workspace_of(session))
  :ok = join(session, member)

  caps = Ezagent.Identity.read_entity_caps(member)
  cap = Enum.find(caps, &member_cap_over?(&1, session))
  assert cap
  assert cap.granted_by == owner
end

test "join grants the member-cap to an AGENT member (agents carry :identity caps)" do
  {session, _owner} = create_session_with_owner()
  agent = create_agent(workspace_of(session))
  :ok = join(session, agent)
  assert Enum.any?(Ezagent.Identity.read_entity_caps(agent), &member_cap_over?(&1, session))
end

test "anon join grants the member-cap but NOT Session.:send (unconfirmed tier)" do
  {session, _owner} = create_public_session()
  anon = mint_anon(session)                                # users.confirmed == false
  :ok = anon_join(session, anon)
  caps = Ezagent.Identity.read_entity_caps(anon)
  assert Enum.any?(caps, &member_cap_over?(&1, session))
  refute Enum.any?(caps, &send_cap_over?(&1, session))
end
```

- [ ] **Step 2: Run to verify they fail.** Run: `mix test .../member_cap_join_test.exs` → FAIL (no member-cap granted yet).

- [ ] **Step 3: Implement the grant** — fold `member_cap/2` into the at-join grant flow (§3.2): grant to the member's identity via `grant_cap_via_router/4`, skip-if-held via `already_authorized?/5`; replace the `mount_participation_caps(_, _), do: :ok` non-user no-op (:814) with an explicit agent member-cap grant (so agents are covered — R1.4). Keep the `:send`/`:leave`/`:subscribe_from` tiering on `Users.confirmed?/1` (`:830-838`) UNCHANGED — the member-cap is the new universal base tier (§7); `:send` stays confirmed-only. `granted_by = owner_uri`, ownerless → #154 admin granter (mirror `public_view_granter/1`).

- [ ] **Step 4: Run to verify they pass.** Run: `mix test .../member_cap_join_test.exs` → PASS.

- [ ] **Step 5: Add compensation tests (test 23 subset — join drift states)**

```elixir
test "join role-conflict preflight → NO orphaned member-cap" do
  {session, _} = create_session_with_owner()
  member = create_user_with_conflicting_role(session)
  assert {:error, _} = join(session, member)
  refute Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))
end

test "join failure AFTER grant → compensating revoke leaves neither cap nor roster" do
  {session, _} = create_session_with_owner()
  member = create_user(workspace_of(session))
  force_do_join_apply_failure(session)                     # e.g. monitor failure injection
  assert {:error, _} = join(session, member)
  refute Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))
  refute Map.has_key?(read_members(session), member)
end
```

- [ ] **Step 6: Implement grant-after-preflight + compensation** per the JOIN sequence above. Verify: `mix test .../member_cap_join_test.exs` → PASS.

- [ ] **Step 7: Commit.**

```bash
git add apps/ezagent_domain_session
git commit -m "feat(session): grant member-cap at join for all member kinds, grant-first + compensation (A1.2)"
```

---

### Task A1.3: `reconcile_after_load/2` seeds/heals the projection from member-caps

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` — `activate/2` already rebuilds `:monitors` from persisted `:members` (:410-424); add the reconcile call there.
- Modify/Create: the reconcile function + the cold reverse-scan (§4.4) — place in `session.ex` or a `session/reconcile.ex` sibling.
- Test: `apps/ezagent_domain_session/test/ezagent/session/reconcile_after_load_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Capability.workspace_of/1` (`capability.ex:425`, O(1)), `Ezagent.Users.list_in_workspace/1` (`users.ex:411-417`), `Ezagent.Entity.Agent.list_in_workspace/1` (A1.1), `Ezagent.Identity.read_entity_caps/1`, `Ezagent.Capability.matches?/2`, `Ezagent.Capability.granted_by_entity?/1`.
- Produces: on `activate/2`, the `:members` projection is reconciled to the authoritative member-cap holder set ("caps win", invariant #20).

**Cold reverse-scan (§4.4) — bounded, no global scan, delivery NEVER calls it:**
1. `ws = workspace_of(S)` (O(1)).
2. candidates = `Users.list_in_workspace(ws)` ∪ `Entity.Agent.list_in_workspace(ws)`.
3. per candidate: read LIVE caps (`read_entity_caps/1`), apply `granted_by_entity?/1` (K4) THEN `matches?/2` for a member-cap whose instance matches S.
4. matching set = authoritative membership; reconcile the projection to it.

**Error handling (§13):** rescue per candidate (`list_in_workspace`/`read_entity_caps` raise) → log `:warning`, keep the persisted projection entry (fail-safe toward existing membership). NEVER crash `activate/2`.

- [ ] **Step 1: Write the failing test (spec test 5)**

```elixir
test "reconcile_after_load heals projection drift to the authoritative cap set" do
  {session, owner} = create_session_with_owner()
  member = create_user(workspace_of(session))
  grant_member_cap(member, session, owner)                # cap present, projection intentionally NOT set
  drop_projection_entry(session, member)                  # simulate cap-only drift

  reactivate_session(session)                             # triggers activate/2 → reconcile

  assert Map.has_key?(read_members(session), member)      # projection healed to the cap
end
```

- [ ] **Step 2: Run to verify it fails.** Run: `mix test .../reconcile_after_load_test.exs` → FAIL.

- [ ] **Step 3: Implement `reconcile_after_load/2`** with the §4.4 bounded scan + per-candidate rescue; call it from `activate/2` right after the `:monitors` rebuild (`session.ex:410-424`). Union/dedupe against the persisted projection.

- [ ] **Step 4: Run to verify it passes.** Run: `mix test .../reconcile_after_load_test.exs` → PASS.

- [ ] **Step 5: Add a rescue test** — a candidate whose `read_entity_caps/1` raises does not crash `activate/2` and the persisted entry survives. Verify PASS.

- [ ] **Step 6: Commit.**

```bash
git add apps/ezagent_domain_session
git commit -m "feat(session): reconcile_after_load seeds/heals members projection from member-caps (A1.3)"
```

---

### Task A1.4: `mix ezagent.migrate.member_caps` — repo READ, live-grant WRITE

**Files:**
- Create: `apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex` (the module; mirror `GrantMigration`'s CLI split shape but NOT its repo-write mechanism)
- Create: `apps/ezagent_domain_session/lib/mix/tasks/ezagent.migrate.member_caps.ex` (the front door; mirror `ezagent.session.migrate_grants.ex`)
- Test: `apps/ezagent_domain_session/test/ezagent/session/member_cap_migration_test.exs`

**Interfaces:**
- Consumes: `KindSnapshot.decode_state/1` (`kind_snapshot.ex:223-239`), keyset pagination over `KindSnapshot`, `Ezagent.Identity.Grant.grant_cap_via_router/4`, `already_authorized?/5`.
- Produces: CLI `mix ezagent.migrate.member_caps [--dry-run] [--gate]` reporting `{sessions_scanned, members_granted, skipped_already_held, ownerless_fallback}`.

**READ shape (R1.5/R2.2 — repo-only paginated read; nodes may be running):**
1. DB-level filter: `from s in KindSnapshot, where: s.kind_type == "session"` (WHERE clause, NOT load-all-then-filter).
2. Keyset pagination: `order_by: s.uri, where: s.uri > ^last_uri, limit: @page`, loop until empty. No `list_all`.
3. Decode ONCE per row (`decode_state/1`); read BOTH `members` AND `owner_uri` from the SAME decoded persisted state (never a live/racing owner lookup).

**WRITE shape (R2.2 — mutate via the LIVE grant path, so the in-memory slice + snapshot stay consistent):**
4. Per `(member, session)`: `grant_cap_via_router/4`, `granted_by = owner_uri` (ownerless → #154 admin granter, LOGGED + counted).

**DEMOTED — implementer picks the mechanism, constraint pinned (R3.2):**
- *Idempotency:* key on the **exact member-cap identity** (5-tuple), NOT on general authorization — a session whose owner already holds a broad `:any` cap **still gets its concrete member-cap written**. Do NOT re-specify which predicate. (The `already_authorized?/5` skip must be identity-exact for the member-cap, not satisfied by a broad `:any` match — verify against test below.)
- *Grant confirmation:* grants are **synchronous, CONFIRMED**, counting only committed `:ok` results.

- [ ] **Step 1: Write the failing tests (spec test 25 + the two R3.2 acceptance cases)**

```elixir
# member_cap_migration_test.exs
test "migration enumerates only session rows via keyset pages, no list_all" do
  seed_sessions_with_members(30)
  assert_no_call Ezagent.Kind.KindSnapshot, :list_all, fn ->
    Ezagent.Session.MemberCapMigration.run([])
  end
  # every seeded (member, session) now holds the member-cap
end

test "migration grants via the live router grant path, NOT a repo snapshot write" do
  seed_sessions_with_members(3)
  assert_called Ezagent.Identity.Grant, :grant_cap_via_router, fn ->
    Ezagent.Session.MemberCapMigration.run([])
  end
end

test "idempotent: run twice → exactly one member-cap per (member, session), no :caps churn" do
  seed_sessions_with_members(3)
  Ezagent.Session.MemberCapMigration.run([])
  snap = capture_caps_snapshots()
  Ezagent.Session.MemberCapMigration.run([])
  assert one_member_cap_per_pair()
  assert capture_caps_snapshots() == snap                 # no churn on re-run
end

# R3.2 idempotency acceptance
test "session under an all-:any admin cap STILL receives its concrete member-cap" do
  {session, owner} = create_session_with_owner()
  grant_all_any_admin_cap(owner)                          # broad :any authorization already present
  member = seed_member(session)
  Ezagent.Session.MemberCapMigration.run([])
  assert Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))
end

# R3.2 grant-confirmation acceptance
test "a grant whose commit fails is NOT counted as migrated" do
  {session, _} = create_session_with_owner()
  member = seed_member(session)
  force_grant_commit_failure(member)
  report = Ezagent.Session.MemberCapMigration.run([])
  assert report.members_granted == 0
end

test "--dry-run writes nothing; --gate exits nonzero pre-migration and zero post" do
  seed_sessions_with_members(2)
  assert Ezagent.Session.MemberCapMigration.run(["--dry-run"]).members_granted == 0
  assert no_member_caps_written()
  assert {:error, _} = Ezagent.Session.MemberCapMigration.run(["--gate"])     # sessions lack caps
  Ezagent.Session.MemberCapMigration.run([])
  assert :ok = Ezagent.Session.MemberCapMigration.run(["--gate"])             # all covered
end
```

- [ ] **Step 2: Run to verify they fail.** Run: `mix test .../member_cap_migration_test.exs` → FAIL (module undefined).

- [ ] **Step 3: Implement the module** (READ + WRITE shapes above) and the mix task front door (flags: `--dry-run`, `--gate`; report tuple). Idempotency keyed on exact member-cap identity; count only committed `:ok`.

- [ ] **Step 4: Run to verify they pass.** Run: `mix test .../member_cap_migration_test.exs` → PASS.

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex apps/ezagent_domain_session/lib/mix/tasks
git commit -m "feat(session): mix ezagent.migrate.member_caps — repo read, live-grant write, idempotent (A1.4)"
```

**Optional PR split:** A1.1-A1.3 (model + reconcile) and A1.4 (migration) are both additive on the same behavior-preserving base and could be two PRs. Default: one PR-1.

**🧑 A1 lead/operator note:** PR-1 merges without running the migration. The actual `mix ezagent.migrate.member_caps` run (dry-run first, then live) is an operator action at deploy time, per environment. Safe on a running node (R2.2 live-grant write).

**Phase A1 done-gate (verify before opening PR-1):** `mix test apps/ezagent_domain_session apps/ezagent_domain_agent` green including tests 1-5, 23(join subset), 25, 26; the full existing suite green (delivery/mint untouched). `/codex:adversarial-review`.

---

# PHASE A2 — delivery / receive / read / removal cutover (ATOMIC, load-bearing)

**Phase goal:** Flip receive- and read-authorization onto the held member-cap, delete the ephemeral mint, and make leave/remove revoke the cap — so a revoked member loses receive **immediately, without waiting for reconcile** (§14.5 step 5, the **defense-in-depth** assertion). (The PRIMARY §14.5 assertion — pending cannot receive → cred not spent — is Phase C's; A2 delivers the held-cap machinery that C reuses.)

**Why A2 is atomic (must land as one PR, sub-tasks may NOT merge independently):** The held-cap model is only *coherent* when both halves land together — receive-reads-held-cap (A2.1/A2.2) AND leave/remove-revoke-held-cap (A2.4). A2's done-gate §14.5 step 5 ("revoke ⇒ immediate deny, proven WITHOUT reconcile") can only pass when both exist. (Note: `leave_effects/2` still `Map.delete`s the roster entry, so a left member drops out of fan-out regardless; receive-cutover *alone* would merely add a check redundant with the still-load-bearing roster-drop — it is not independently *useful*, and the security property is unproven until revoke lands. Hence one atomic landing.)

**Phase dependencies:** A1 (member-caps must exist and be granted at join, else no held cap to authorize against).

**🧑 Before starting A2:** obtain lead sign-off on spec §16 open-risk #4 (best-effort → fail-closed for the membership-defining cap). Blocking human action.

**Phase done-gate:** tests 6-12, 20-24 pass; the §14.5(A) **defense-in-depth** assertion (step 5: revoke ⇒ immediate deny) passes — proven without re-activating the session — set up via a manage-authorized mount (A2.6, stable across Phase C). §14.5(A) steps 1-4 (prevention flow) and step 6 (cascade) are `@tag :skip`-ed with pointers to C and B. `/codex:adversarial-review`.

---

### Task A2.1: Shared `MemberReceive.authorize/1` predicate + `ReceiveAuthzParityTest`

**Files:**
- Create: `apps/ezagent_domain_session/lib/ezagent/session/member_receive.ex` (sibling to `membership_predicate.ex`)
- Test: `apps/ezagent_domain_session/test/ezagent/session/member_receive_test.exs`
- Test: `apps/ezagent_domain_session/test/ezagent/session/receive_authz_parity_test.exs`

**Interfaces:**
- Produces: `Ezagent.Session.MemberReceive.authorize(ctx :: map()) :: boolean()` (or `:ok | {:error, _}` — implementer's choice; the parity test only asserts the two receive behaviors route through it).

**DEMOTED — implementer picks the predicate shape, constraint pinned (R1.2, mirror the proven `socialware_publisher_read.ex:56-77` in-handler read-auth precedent):**
- Authorizes iff the recipient **HOLDS** a member-cap whose `instance` matches `ctx.caller` (the source session S).
- Reads the recipient's OWN caps from **`ctx[:siblings][:identity]`** — pre-loaded via `reads_siblings([:identity])`, so NO `GenServer.call`, NO self-slice deadlock (`runtime.ex:393-407` hazard avoided by construction), NO per-message cross-process read.
- Applies the `granted_by_entity?/1` provenance filter (K4) before `matches?/2`.
- May safely assume `ctx.caller` is a session (the sole `:receive` dispatch is session fan-out — invariant, guarded below). Do NOT re-specify the predicate/tuple.

- [ ] **Step 1: Write the failing predicate test**

```elixir
# member_receive_test.exs
test "authorize passes iff recipient holds a member-cap matching ctx.caller (source session)" do
  {session, _} = create_session_with_owner()
  member = create_user(workspace_of(session))
  grant_member_cap(member, session, owner_of(session))
  ctx = build_receive_ctx(recipient: member, caller: session)   # siblings[:identity] preloaded
  assert Ezagent.Session.MemberReceive.authorize(ctx)
end

test "authorize denies when the recipient does NOT hold a member-cap over ctx.caller" do
  {session, _} = create_session_with_owner()
  stranger = create_user(workspace_of(session))                 # no member-cap
  ctx = build_receive_ctx(recipient: stranger, caller: session)
  refute Ezagent.Session.MemberReceive.authorize(ctx)
end

test "authorize denies a system-granted (provenance-filtered) member-cap" do
  {session, _} = create_session_with_owner()
  member = create_user(workspace_of(session))
  grant_member_cap_granted_by_system(member, session)           # granted_by system:// — filtered by K4
  ctx = build_receive_ctx(recipient: member, caller: session)
  refute Ezagent.Session.MemberReceive.authorize(ctx)
end
```

- [ ] **Step 2: Run to verify they fail.** Run: `mix test .../member_receive_test.exs` → FAIL (module undefined).

- [ ] **Step 3: Implement `MemberReceive.authorize/1`** per the pinned constraints (read `ctx[:siblings][:identity]`, provenance-filter, `matches?/2` against `ctx.caller`).

- [ ] **Step 4: Run to verify they pass.** → PASS.

- [ ] **Step 5: Write `ReceiveAuthzParityTest` (spec test 24, corrected by R2.3)** — enumerate the ACTUAL registered `{Kind, :receive}` behaviors dynamically from the BehaviorRegistry (exactly `User.Receive` + `Agent.Receive` today) and assert each is `cap_exempt` for `:receive` AND routes through `MemberReceive.authorize/1`. Do NOT enumerate the unreachable `HelloBuilder`/`HelloConcierge` role receives.

```elixir
# receive_authz_parity_test.exs
test "every registered {Kind, :receive} behavior is cap_exempt for :receive and uses MemberReceive.authorize/1" do
  for {_kind, mod} <- registered_receive_behaviors() do          # from BehaviorRegistry, like BehaviorRequiredCapsParityTest
    assert :receive in mod.cap_exempt_actions(),
           "#{inspect(mod)} must make :receive cap_exempt"
    assert routes_through_member_receive_authorize?(mod),
           "#{inspect(mod)} must authorize via MemberReceive.authorize/1"
  end
end
```

- [ ] **Step 6: Run parity test** — expected FAIL now (User/Agent.Receive not yet wired; wired in A2.2). Leave it failing; A2.2 makes it pass. Commit the predicate + tests.

```bash
git add apps/ezagent_domain_session/lib/ezagent/session/member_receive.ex apps/ezagent_domain_session/test/ezagent/session/member_receive_test.exs apps/ezagent_domain_session/test/ezagent/session/receive_authz_parity_test.exs
git commit -m "feat(session): shared MemberReceive.authorize/1 predicate + parity test scaffold (A2.1)"
```

---

### Task A2.2: Wire the two receive sites + make `:receive` cap_exempt + delete the mint

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/user/receive.ex` — `caps:` at :114, `handle_receive/2` at :144; add `cap_exempt_actions` including `:receive`; call `MemberReceive.authorize/1` at the top of `handle_receive/2`; add `reads_siblings([:identity])`.
- Modify: `apps/ezagent_domain_agent/lib/ezagent/behavior/agent/receive.ex` — `reads_siblings([:sandbox])` at :80 → `reads_siblings([:sandbox, :identity])`; add `:receive` to `cap_exempt_actions`; call `MemberReceive.authorize/1` at the TOP of `handle_receive/2` (:194) **BEFORE** the bridge short-circuit `Delivery.deliver_agent_receive(msg, ctx)` (:210) — gates every plugin agent flavor through one site (R2.3).
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/delivery.ex` — **DELETE** `member_receive_caps/1` (:259-274); `dispatch_receive_call/3` (:143) presents NO receive cap (`caps: member_receive_caps(...)` at :176 → present no member-cap).
- Test: `apps/ezagent_domain_session/test/ezagent/session/held_cap_receive_test.exs`; add the `:receive`-dispatch-site guard test.

**Interfaces:**
- Consumes: `Ezagent.Session.MemberReceive.authorize/1` (A2.1).

- [ ] **Step 1: Write failing tests (spec tests 7, 8, 20, 21) + the single-dispatch-site guard**

```elixir
# held_cap_receive_test.exs
test "delivery presents NO member-cap in ctx.caps; receive authorizes on held cap (test 7/20)" do
  {session, _} = create_session_with_owner()
  member = create_member_with_cap(session)
  caps_on_receive = capture_receive_ctx_caps(session, member)
  refute Enum.any?(caps_on_receive, &member_cap?/1)              # bearer token gone
  assert receive_delivered?(session, member)                    # held cap authorizes
end

test "a non-member (no member-cap) is NOT delivered to — receive denies (test 8)" do
  {session, _} = create_session_with_owner()
  stranger = create_user(workspace_of(session))                 # roster may list, but no cap
  put_stale_roster_entry(session, stranger)
  refute receive_delivered?(session, stranger)
end

test "revoke → the very next receive is DENIED, WITHOUT running reconcile (test 20/21)" do
  {session, _} = create_session_with_owner()
  member = create_member_with_cap(session)
  revoke_member_cap(member, session)                            # roster entry left stale on purpose
  refute receive_delivered?(session, member)                    # denied immediately, no re-activate
end

test "member_receive_caps/1 has no callers (grep-gate, test 7)" do
  refute File.read!("apps/ezagent_domain_session/lib/ezagent/behavior/session/delivery.ex")
         =~ "member_receive_caps"
end

test "the ONLY :receive dispatch site is session fan-out (guard invariant)" do
  # asserts no Router.dispatch(action: :receive) exists outside Delivery.dispatch_receive_call/3
  assert single_receive_dispatch_site?()
end
```

- [ ] **Step 2: Run to verify they fail.** → FAIL.

- [ ] **Step 3: Implement** — the three file edits above (cap_exempt + in-handler authz at both sites, `reads_siblings([:identity])`, delete the mint). At `Agent.Receive`, place the authorize call before the bridge call at :210 (the self-message loop-guard at :195-205 is a plan detail — "before the bridge call" is the invariant).

- [ ] **Step 4: Run to verify they pass** — including the A2.1 `ReceiveAuthzParityTest` (now green). → PASS.

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_session apps/ezagent_domain_agent
git commit -m "feat(session,agent): :receive cap_exempt + in-handler held-cap authz at 2 sites; delete member_receive_caps mint (A2.2)"
```

---

### Task A2.3: Socialware read-authorization → held member-cap

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex` — `member?/2` at :76-79 (`Map.has_key?(members, caller)`) and `authorize/2` at :42-46. Read the caller's LIVE caps via `read_entity_caps/1` + `matches?/2` (after `granted_by_entity?/1`). Owner branch (`owner?/2`) UNCHANGED.
- Test: `apps/ezagent_domain_session/test/ezagent/session/socialware_read_held_cap_test.exs`

- [ ] **Step 1: Write the failing test (spec test 22)**

```elixir
test "ex-member (cap revoked) still in stale members projection is DENIED socialware read" do
  {session, _} = create_session_with_owner()
  member = create_member_with_cap(session)
  put_stale_roster_entry(session, member)
  revoke_member_cap(member, session)                            # cap gone, roster stale
  refute Ezagent.Session.MembershipPredicate.authorize(chat_of(session), member)
end

test "current member (holds cap) is ALLOWED socialware read" do
  {session, _} = create_session_with_owner()
  member = create_member_with_cap(session)
  assert Ezagent.Session.MembershipPredicate.authorize(chat_of(session), member)
end
```

- [ ] **Step 2: Run → FAIL** (current `member?/2` reads the projection).

- [ ] **Step 3: Implement** — `member?/2` additionally requires the caller to HOLD the member-cap (LIVE caps, provenance-filtered `matches?/2`). Owner branch unchanged.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex
git commit -m "feat(session): socialware read-authz reads held member-cap, not the roster projection (A2.3)"
```

---

### Task A2.4: Leave / Remove revoke the member-cap (three R3.1 sequences)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` — `leave_effects/2` (:524-529), `do_remove_participant/3` (:624-687), the fail-closed teardown reap (:636-645), routing-prune (:668-685).
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/teardown.ex` — split the fused authority+destruction in `teardown_participant_resources/4` (:63) / `reap_spawned_worker/3` (:90-94, calls `owner_destroy_dispatch` at :184 destructively BEFORE returning `{:ok,:worker}`).
- Consumes: `Ezagent.Identity.Grant.revoke_cap_via_router/4` (`grant.ex:121`) or `revoke_cap/3` (`grant.ex:108`, fallible → `:ok | {:error, _}`).
- Test: `apps/ezagent_domain_session/test/ezagent/session/member_cap_removal_test.exs`

**Three sequences (R3.1 supersedes R2.1 — the destructive `sandbox.destroy` moves AFTER a confirmed revoke; only the AUTHORITY half stays in the preflight):**

- **LEAVE (self-leave):** `leave_effects/2` has NO fallible follow-up (:519). Revoke the member-cap, then drop the projection. R1.1 → a projection-drop failure has no authz window.
- **REMOVE ordering:** `authority-preflight → (confirmed) abort-safe revoke → best-effort destructive teardown (sandbox.destroy) → roster-drop`:
  1. **teardown-AUTHORITY = a PURE preflight** (may this remover tear this participant down?). On reject: everything intact, ZERO mutation (no destroy, no revoke, no roster-drop) — this preserves test 11. **DEMOTED/PROPOSED:** the exact extraction (which lines split out of `teardown_participant_resources/4`, what the pure check is named) is the implementer's choice; constraint = authority check rejects with zero mutation.
  2. **member-cap REVOKE = synchronous, checked, ABORT-SAFE.** Revoke fails → the removal ABORTS, member left FULLY INTACT (loud error, never a silent partial proceed — let-it-crash). **DEMOTED/PROPOSED:** do NOT prescribe the revoke-effect API (inline synchronous `revoke_cap_via_router/4` [primary, matches "checks→revoke→drop" order] vs deferred `{:dispatch, revoke_cmd}` effect [also satisfies the rejection invariant]); constraint = synchronous + checked + abort-on-failure, placed AFTER every rejecting check.
  3. **destructive teardown (`sandbox.destroy`) + roster-drop = best-effort, AFTER a confirmed revoke.** A post-revoke destroy/drop failure is a RESOURCE leak (reconciled: lingering roster → `reconcile_after_load/2`; lingering worker → session-teardown reap `teardown.ex:82-85,120-150`), NOT a security regression.

- [ ] **Step 1: Write failing tests (spec tests 9, 10, 11, + the R3.1 abort-safe revoke case)**

```elixir
# member_cap_removal_test.exs
test "self-leave revokes the member-cap and drops the projection; {:member_left} broadcasts (test 10)" do
  {session, _} = create_session_with_owner()
  member = create_member_with_cap(session)
  assert_broadcast_member_left(session, member, fn -> leave(session, member) end)
  refute Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))
  refute Map.has_key?(read_members(session), member)
end

test "remove_participant fail-closed: teardown-cap-DENIED leaves BOTH cap AND projection intact (test 11)" do
  {session, remover} = create_session_with_owner()
  member = create_member_with_cap(session)
  deny_teardown_authority(remover, member)
  assert {:error, _} = remove_participant(session, member, remover)
  assert Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))  # cap intact
  assert Map.has_key?(read_members(session), member)                                           # roster intact
end

test "remove_participant: a FAILED revoke ABORTS, member left fully intact (R3.1 abort-safe)" do
  {session, remover} = create_session_with_owner()
  member = create_member_with_cap(session)
  force_revoke_failure(member, session)
  assert {:error, _} = remove_participant(session, member, remover)
  assert Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))
  assert Map.has_key?(read_members(session), member)
end

test "presence: :DOWN flips online:false but member RETAINS the member-cap (test 9)" do
  {session, _} = create_session_with_owner()
  member = create_member_with_cap(session)
  simulate_member_down(session, member)
  assert read_members(session)[member].online == false
  assert Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))
end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement the three sequences.** LEAVE: revoke-then-drop. REMOVE: split the teardown authority out as a pure preflight (test 11 must stay green), place the confirmed abort-safe revoke after all rejecting checks, move `sandbox.destroy` to best-effort after the revoke. Presence/monitors UNCHANGED.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_session
git commit -m "feat(session): leave/remove revoke member-cap — 3 R3.1 sequences, abort-safe revoke, best-effort destroy (A2.4)"
```

---

### Task A2.5: Anon holds the member-cap + post-commit replay/notify

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/.../anon_user.ex` — `anon_view_caps/1` (:130-132) or the anon-admission post-join mount: add the member-cap. Anon does NOT get `:send` (unconfirmed tier §7). First-join owner-claim suppression (`membership.ex:108`) unaffected.
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` — JOIN's inline `Delivery.replay_messages_since/3` (:95) + `Ezagent.Notifications.notify/2` (:115-125) must run POST-COMMIT.
- Test: `apps/ezagent_domain_socialware/test/.../anon_member_cap_test.exs`; `apps/ezagent_domain_session/test/.../post_commit_replay_test.exs`

**DEMOTED — implementer picks the wiring, constraint pinned (R3.2):** replay + notify run **POST-COMMIT — after BOTH the grant and the join have committed**; no replay/notify fires to a member whose join has not committed. Do NOT prescribe deferred-dispatch vs inline-post-commit.

- [ ] **Step 1: Write failing tests (spec test 3 anon path already in A1.2; add the post-commit case)**

```elixir
# post_commit_replay_test.exs
test "a join that fails AFTER the grant produces NO replay/notify to that member (R3.2)" do
  {session, _} = create_session_with_owner()
  member = create_user(workspace_of(session))
  force_join_commit_failure(session)
  spy = install_replay_notify_spy()
  assert {:error, _} = join(session, member)
  assert spy.replays_to(member) == []
  assert spy.notifies_to(member) == []
end
```

- [ ] **Step 2: Run → FAIL** (replay/notify currently inline pre-commit).

- [ ] **Step 3: Implement** — move replay + notify to post-commit (after grant AND join commit). Add the member-cap to anon admission.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_socialware apps/ezagent_domain_session
git commit -m "feat(session,socialware): anon holds member-cap; JOIN replay/notify run post-commit (A2.5)"
```

---

### Task A2.6: Blast-radius regression guards + §14.5(A) ExUnit security acceptance test

**Files:**
- Test: `apps/ezagent_domain_session/test/ezagent/session/blast_radius_guard_test.exs` (tests 6, 12)
- Test: `apps/ezagent_domain_session/test/ezagent/acceptance/member_cap_cascade_acceptance_test.exs` (§14.5 A — cross-app integration; session domain owns membership+delivery). A2 lands **only the defense-in-depth assertion (step 5: revoke ⇒ deny)**, set up via a **manage-authorized mount** so it is STABLE across Phase C (a cross-owner add would go pending under C and break a naive setup). §14.5(A) steps 1-4 (prevention flow, Phase C) and step 6 (cascade, Phase B) are `@tag :skip`-ed with pointers.

**Interfaces:**
- Consumes: everything from A2.1-A2.5.

- [ ] **Step 1: Write the crux/perf-shape guard (test 6) + roster-shape regression (test 12)**

```elixir
# blast_radius_guard_test.exs
test "delivery fan-out does NO reverse cap scan per message (test 6)" do
  {session, _} = create_session_with_members(3)
  assert_no_call Ezagent.Users, :list_in_workspace, fn -> send_message(session, "hi") end
  # the invariant that fails if someone 'simplifies' delivery into a reverse query
end

test "UI roster (member_options/1) and read-authz read the projection with unchanged shape (test 12)" do
  # regression guard: member_options/1 still maps members meta; socialware read still callable
end
```

- [ ] **Step 2: Write the §14.5(A) step-5 DEFENSE-IN-DEPTH acceptance test (A2's done-gate)**

Set up the mounted member via a **manage-authorized** add (owner mounts its OWN agent — mounts immediately under both pre-C and post-C), then revoke → deny. Do NOT use a cross-owner add here: under Phase C that would go pending and never mount, breaking this test.

```elixir
# member_cap_cascade_acceptance_test.exs
test "§14.5(A) step 5 [defense-in-depth]: revoke ⇒ immediate deny, no reconcile" do
  {session, owner} = create_session_with_owner()
  agent = create_cc_agent(owner: owner, workspace: workspace_of(session))  # owner MANAGES agent

  # manage-authorized add → mounts immediately (holds the member-cap)
  :ok = add_member(session, agent, by: owner)
  post(session, owner, "hello")
  assert receive_delivered?(session, agent)                # mounted member receives

  # 🔴 defense-in-depth: remove ⇒ revoke ⇒ next receive DENIED, no reconcile
  :ok = remove_participant(session, agent, by: owner)      # revoke the member-cap
  post(session, owner, "again")
  refute receive_delivered?(session, agent)                # DENIED immediately...
  refute reconcile_was_run?(session)                       # ...WITHOUT re-activating the session
end

# §14.5(A) PRIMARY prevention flow (steps 1-4) — added in Phase C (Task C.4).
# §14.5(A) step 6 (cascade to X) — added in Phase B (Task B.4).
@tag :skip
test "§14.5(A) steps 1-4 [PRIMARY prevention]: pending cannot receive → approve → mounts (Phase C)" do
  # C.4 replaces this: B (no manage-authority) adds A's-agent → PENDING, no cap;
  # B posts → A's-agent :receive DENIED, does NOT run, cred not spent (PRIMARY);
  # A notified; A approves → mounts → receives.
end
```

- [ ] **Step 3: Run → PASS** (step 5 live; prevention/cascade steps skipped).

- [ ] **Step 4: Commit.**

```bash
git add apps/ezagent_domain_session/test
git commit -m "test(session): blast-radius guards + §14.5(A) step-5 defense-in-depth (immediate deny on revoke, no reconcile) (A2.6)"
```

**Phase A2 done-gate (verify before opening PR-2):** tests 6-12, 20-24 green; §14.5(A) **step 5** (defense-in-depth revoke⇒deny) green and **proven without reconcile**; full suite green; §16 risk-4 lead sign-off obtained; `/codex:adversarial-review`. **The whole of A2 = one PR (PR-2); A2.1-A2.6 do NOT merge independently.** (The PRIMARY §14.5 assertion — pending cannot receive — is Phase C's gate, not A2's.)

---

# PHASE B — cascade notification (rides on A2, additive/advisory)

**Phase goal:** On a member-cap (or other allowlisted `{entity, :caps}`) slice-change on entity X, resolve X's one-level manage/owner holders and notify their inboxes — closing the S1 removal-notify gap for free.

**Phase dependencies:** A2 (join/leave/remove must produce a slice-change on the MEMBER's own `:identity`/`:caps` slice — that is what B subscribes to). B is additive and advisory: it runs on the post-commit `DeferredDispatch` turn, off the mutating dispatch's critical path (a slow/failing cascade cannot roll back the mutation).

**Phase done-gate:** tests 13-19 pass; §14.5(A) **step 6** (grant/revoke cascade to an arbitrary X → owner Y notified; removal-notify — the S1 gap closed) un-skipped and green. `/codex:adversarial-review`. (The world-UI agent-browser scenario §14.5(B) is now the **approve UX** — it moves to Phase C / Task C.4. B also delivers `Ezagent.Identity.Authority` (B.1) and `managers_of/1` (B.2), which Phase C consumes.)

**Note — Part C depends on B.** Phase C reuses B.1 (`Authority.manages?/2`), B.2 (`managers_of/1`), and B.3 (content-free notify). B must land before C.

---

### Task B.1: Extract `Ezagent.Identity.Authority` (K2)

**Files:**
- Create: `apps/ezagent_domain_identity/lib/ezagent/identity/authority.ex` — public `manages?/2` and `workspace_admin?/2`, extracted from the PRIVATE defps `holds_manage_over_target?/2` (`identity.ex:718`) and `holds_workspace_admin_cap?/2` (`identity.ex:858`).
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` — have `IdentityAdmin` call the new `Authority` (single source of truth; do NOT duplicate the predicate logic).
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/authority_test.exs`

> **Naming trap:** an `Ezagent.Identity.AdminAuthority` (`admin_authority.ex`, public `admin?/2`) ALREADY exists — it exposes no per-target `manages?/2`. Do NOT conflate. Create the NEW `Ezagent.Identity.Authority`.

- [ ] **Step 1: Write the failing test** — `manages?/2` returns true for a creator holding `CreatorGrant.manage_cap` over the target; `workspace_admin?/2` for a workspace-admin cap; both false otherwise.

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Extract** the two predicates into `Authority`; repoint `IdentityAdmin`'s call sites (:659, :690, :809) to it.

- [ ] **Step 4: Run → PASS**; run the existing identity suite to prove no regression from the extraction.

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_identity
git commit -m "refactor(identity): extract public Ezagent.Identity.Authority (manages?/2, workspace_admin?/2) — single source of authority truth (B.1)"
```

---

### Task B.2: `managers_of/1` cascade resolver

**Files:**
- Create: the resolver (place in `ezagent_core` or a cascade module; observe `undeclared_umbrella_dep_test` — use `Users.list_in_workspace/1` + `read_entity_caps/1` + `Ezagent.Identity.Authority`).
- Test: cascade resolver test (spec tests 15, 16, 17).

**Interfaces:**
- Produces: `managers_of(x :: URI.t()) :: [URI.t()]` — User URIs holding one-level manage/owner authority over X, bounded to X's workspace.

**Algorithm (§10):** `ws = workspace_of(X)` (O(1)) → candidates = `Users.list_in_workspace(ws)` → per candidate read LIVE caps (K5) → `granted_by_entity?/1` (K4) → `Authority.manages?/2` over X OR `Authority.workspace_admin?/2` → dedupe → filter to User URIs (agents can't be notified — §11/S2).

- [ ] **Step 1: Write failing tests (15, 16, 17)**

```elixir
test "managers_of(agent) returns the creator (holds CreatorGrant.manage_cap), not an unrelated user (15)" do ... end
test "a {:within_workspace, ws}-scoped Manage cap IS returned (matches?/2, not naive equality) (15)" do ... end
test "a different-workspace user is NEVER returned (bounded scan) (15)" do ... end
test "a system-granted stale Manage cap does NOT over-match (granted_by_entity?/1 filter, 16)" do ... end
test "cascade uses LIVE caps: grant a Manage cap at runtime, new manager IS resolved (17)" do ... end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** the bounded per-workspace live-cap scan.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git commit -am "feat(cascade): managers_of/1 bounded reverse-authority resolver (K4/K5) (B.2)"
```

---

### Task B.3: Cascade hook at the emit chokepoint + content-free notify

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind/server.ex` — after `commit_and_notify/3` (:731) succeeds, enqueue the cascade on the post-commit `DeferredDispatch` turn (`DeferredDispatch.enqueue`, :616/:647), like `deferred_dispatch` — NOT a per-URI subscriber (K3).
- Create: the cascade component (allowlisted `{scheme, slice_key}` — initially `{entity, :caps}`; payload `{entity_uri, slice_key, event_at, cursor}` — NO cap values, NO member list; deliver via `Ezagent.Notifications.notify/2` per resolved User recipient).
- Test: cascade hook tests (spec tests 18, 19); the drift/error guards (§13).

- [ ] **Step 1: Write failing tests (18, 19)**

```elixir
test "cascade hook fires from the post-commit DeferredDispatch turn; a raising resolver does NOT roll back the mutation (19)" do ... end
test "payload is exactly {entity_uri, slice_key, event_at, cursor} — NO cap values / member list (18)" do ... end
test "cascade only fires for allowlisted {entity, :caps} slice changes" do ... end
test "bad/non-dict cascade envelope → guard-clause ignore, never crash (§13)" do ... end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** the hook + resolver dispatch + content-free notify; rescue resolver/notify errors (best-effort, non-fatal — §13); filter recipients to Users.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git commit -am "feat(cascade): post-commit hook at emit chokepoint + content-free managers/owners notify (K3) (B.3)"
```

---

### Task B.4: Un-skip §14.5(A) step 6 — grant/revoke cascade to X + removal-notify

**Files:**
- Modify: `apps/ezagent_domain_session/test/ezagent/acceptance/member_cap_cascade_acceptance_test.exs` — un-skip step 6; add spec tests 13, 14.

> **Note (post-R4):** the old "step 2 = cross-owner add ⇒ A cascade-notified" no longer applies — under Part C a cross-owner add is PENDING and grants NO cap, so the `{entity,:caps}` cascade does not fire on the add. The owner-notify for a pending request is Phase C's pending-member-subject notify (test 29 / §14.5(A) step 3). Phase B proves the GENERIC cascade: a member-cap grant/revoke to an arbitrary X notifies X's owner Y (fires on the manage-authorized add, the approve-mount grant, and any removal-revoke). The agent-browser scenario (§14.5 B) is the approve UX → Phase C (Task C.4).

- [ ] **Step 1: Un-skip / add cascade tests (13, 14, §14.5(A) step 6)**

```elixir
test "§14.5(A) step 6: grant member-cap to X (owner Y) ⇒ Y notified; on revoke ⇒ Y notified (13/14, S1 gap closed)" do ... end
```

- [ ] **Step 2: Run → PASS** (§14.5(A) step 6 green; prevention steps 1-4 remain skipped until Phase C).

- [ ] **Step 3: Commit.**

```bash
git add apps/ezagent_domain_session/test
git commit -m "test(cascade): §14.5(A) step 6 grant/revoke cascade to X + removal-notify green (B.4)"
```

**Phase B done-gate:** tests 13-19 green; §14.5(A) step 6 green. `/codex:adversarial-review`. **B is one PR (PR-3); ships independently on top of a merged A2. Part C (PR-4) depends on B.1/B.2/B.3.**

---

# PHASE C — admission gate: owner-approval-to-mount (Part C / R4, PREVENTS X)

**Phase goal:** A cross-owner add (caller lacks manage-authority over the member) does NOT mount — it records a PENDING request and grants NO member-cap, so the pending agent cannot receive (R1.1) and the owner's credential is not spent, until the owner approves. This phase carries the **PRIMARY** §14.5 done-gate and **closes the motivating threat X by PREVENTION**.

**Phase dependencies:** A2 (R1.1 held-cap receive-authz — gives "pending cannot receive" for free) + B (B.1 `Authority.manages?/2`, B.2 `managers_of/1`, B.3 content-free notify). Additive/advisory on top: the security half is entirely composed from R1.1 + R3.1; the notify from B.

**🧑 Before starting C:** obtain lead sign-off on spec §16 open-risk #5 (cross-owner adds now go pending — a user-visible change to add-others'-agent flows). Blocking human action.

**Phase done-gate:** tests 27-34 pass (incl. **test 33 — the World `invite_member/3` bypass goes PENDING**, and **test 34 — cross-session routing cannot confer receive, covered by R1.1**); the §14.5(A) PRIMARY prevention assertion (step 2: B's cross-owner add pending ⇒ A's-agent cannot receive ⇒ cred not spent, asserted at the **flavor-adapter boundary** per Q3) passes deterministically, plus steps 1,3,4 (pending/notify/approve→mount); §14.5(B) approve-UX agent-browser scenario captured (3 screenshots); **the Task C.5 arch-invariant test (test 35) passes** — no member-cap grant / member mount outside the gated chokepoint. `/codex:adversarial-review`.

### Task C.5: Arch-fitness invariant — no member-mount bypasses the gated chokepoint (lead-requested 2026-07-04)

**Why (structural, not incidental):** the World-invite bypass (spec §C.1 bypass 1) was not a one-off — it is the general trap that *any* authority check scattered across the N `session.join` entry paths will leak. The runtime fix (a single gate at the `handle_join`→`do_join_apply` chokepoint) closes today's paths; this arch invariant **prevents a future dev from re-opening the class** by adding a new path that grants a member-cap / mounts a member without passing the gated chokepoint. Same pattern as the domain-only-Kinds gate — converts "everyone should use the chokepoint" into "compile/test-time proof no one bypasses it".

- **Test 35 (arch-fitness):** a static/AST invariant asserting that the member-cap grant + the member-roster mount happen at **exactly one** code site (the gated `do_join_apply` seam), i.e. no other module grants a `cap(:session, Session, ...)` member-cap or writes a `:members` mount outside that seam. A fixture that adds a bypassing grant/mount call MUST trip the gate (teeth test). Model on the existing arch-scan gates (`apps/ezagent_core/test/architecture/`); allowlist starts empty (or ratcheted to the known single seam).
- **Requirement (mechanism DEMOTED):** the implementer picks grep-vs-AST matching per the existing arch-scan conventions; the constraint is "one seam, provably no bypass, with a teeth test that fails on a planted bypass." Do NOT prescribe the matcher.
- **Done:** test 35 green; the planted-bypass fixture trips it; the arch baseline manifest updated.

**Global constraint (spec §C.1 — CORRECTED to all-entry-paths):** the gate withholds the **member-cap only** and sits at the member-cap grant seam in `do_join_apply`, **reached by `handle_join/2` (`session.ex:588`) from EVERY member-add entry path** — World `invite_member/3`, the orchestrator `provision_invited_join_authority`/`join_member` path, the materializer, and any direct `session.join`. **The trigger is a requirement over all these paths, NOT scoped to one invite function** (which misses the world-UI invite — spec §C.1 bypass 1). Key the check on **`ctx.caller`** (already in scope at `handle_join` — no `inviter_uri` threading needed): fire PENDING iff `ctx.caller` is a real non-system entity that is neither the member nor a manager (`Authority.manages?/2` false, resolved from the caller's **durable identity caps by URI**, NOT `ctx.caps`). **DEMOTED — implementer picks the mechanism, constraint pinned:** (a) the pending-notify wiring (direct `managers_of(member)→notify` call vs subject-carrying hook — spec §C.3); (b) the `:pending_members` shape + approve/deny/withdraw action plumbing. Constraint = the acceptance tests below; do NOT re-specify the effect grammar.

---

### Task C.1: Trigger branch + `:pending_members` state (cross-owner add goes pending, no cap)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` — the at-join member-cap grant seam (A1.2 grant, in/near `do_join_apply`), reached by `handle_join/2` (`session.ex:588`) from all entry paths. **The trigger is a requirement over ALL member-add paths (spec §C.1), checked at this COMMON chokepoint keyed on `ctx.caller`, NOT scoped to one invite function.** Fire pending ONLY when `ctx.caller` is a **real, non-system** entity that is neither the member nor a manager of it (`Authority.manages?/2` false, resolved from the caller's DURABLE identity caps by URI — not `ctx.caps`). Sit the check AFTER the idempotent-rejoin early-return (`session.ex:630-642`) so a live member's rejoin is never spuriously pended. **Do NOT pend:** caller manages the member (own agent/admin); self-join (`caller == member`, incl. anon self-admission `anon_admission.ex:107`); **the materializer / team-template spawn** — ⚠️ CORRECTED: `system://session-internal` is ELIMINATED (#154); the materializer dispatches under `ctx.caller = Entity.User.admin_uri()` with an inline join cap (`materializer.ex:182-212`), exempt via `manages?(admin_uri, member) = true` (workspace-admin). **⚠️ VERIFY** `manages?/2` reads admin's durable identity caps (the genesis wildcard, `user.ex:89`) and NOT `ctx.caps` (which holds only the inline join cap) — else every team-template spawn stalls at PENDING.
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session.ex` — add the `:pending_members` map to the `:session` slice (persistent), distinct from `:members`.
- Test: `apps/ezagent_domain_session/test/ezagent/session/admission_gate_test.exs`; the World-invite bypass regression (test 33) lives in the world plugin `apps/ezagent_plugin_world/test/…` (it drives `invite_member/3`, which takes a `Phoenix.LiveView.Socket`); the cross-session-routing test (test 34) lives with the session delivery tests.

> **⚠️ Over-fire trap (spec §C.1 warning, §16 risk 5 — CORRECTED):** a `ctx.caps`-based `manages?` check pends **every materializer / team-template spawn** — the materializer's `ctx.caps` carries only a narrow inline join cap, NOT the admin genesis wildcard, so `manages?` MUST resolve the caller's DURABLE identity caps by URI. The guard test below (materializer/admin-caller add + anon self-admission still MOUNT) fails if the trigger reads `ctx.caps` or ignores the not-self / non-system carve-outs.

**Interfaces:**
- Consumes: `Ezagent.Identity.Authority.manages?/2` (B.1), `member_cap/2` (A1.1), the grant seam (A1.2), `ctx.caller` (already threaded into `handle_join`).
- Produces: a cross-owner add records `:pending_members[member] = %{requested_by, requested_at, request_ref}` and grants NO member-cap; every non-add / manage-authorized / self / materializer mount is immediate (unchanged).

- [ ] **Step 1: Write failing tests (spec tests 27, 28, 30, 33, 34 + the over-fire guard)**

```elixir
# admission_gate_test.exs
test "manage-authorized add mounts immediately, no pending (test 27)" do
  {session, owner} = create_session_with_owner()
  agent = create_cc_agent(owner: owner, workspace: workspace_of(session))  # owner manages agent
  :ok = add_member(session, agent, by: owner)
  assert Enum.any?(Ezagent.Identity.read_entity_caps(agent), &member_cap_over?(&1, session))
  refute Map.has_key?(read_pending(session), agent)
end

test "cross-owner add goes PENDING, grants NO member-cap (test 28)" do
  {b_session, b} = create_session_with_owner()
  a = create_user(workspace_of(b_session))
  a_agent = create_cc_agent(owner: a, workspace: workspace_of(b_session))
  :ok = add_member(b_session, a_agent, by: b)                      # B does NOT manage A's agent
  assert Map.has_key?(read_pending(b_session), a_agent)
  refute Enum.any?(Ezagent.Identity.read_entity_caps(a_agent), &member_cap_over?(&1, b_session))
  refute Map.has_key?(read_members(b_session), a_agent)            # not mounted
end

test "PENDING agent cannot receive → cred not spent (PRIMARY prevention, test 30)" do
  {b_session, b} = create_session_with_owner()
  a = create_user(workspace_of(b_session))
  a_agent = create_cc_agent(owner: a, workspace: workspace_of(b_session))
  :ok = add_member(b_session, a_agent, by: b)                      # pending
  post(b_session, b, "run my prompt")
  refute receive_delivered?(b_session, a_agent)                    # holds no cap → R1.1 denies
  # ⚠️ Q3: assert the FLAVOR ADAPTER / bridge deliver call never fired (that IS the
  # OAuth spend) — NOT Process.alive?, since dispatch_receive_call/3 may ensure_live/1
  # the worker BEFORE the receive-authz denial (session/delivery.ex:163-165).
  refute_flavor_adapter_invoked(a_agent)                          # A's credential NOT spent
end

# 🔴 OVER-FIRE GUARD (§C.1 warning, CORRECTED) — the trigger must NOT pend non-add mounts.
# Fails if someone reads manages? off ctx.caps or wires a bare check on the grant seam.
test "materializer / admin-caller add still MOUNTS, does NOT go pending (over-fire guard)" do
  {session, _owner} = create_session_with_owner()
  # #154: NOT system://session-internal — the materializer runs under admin_uri with a
  # NARROW inline join cap (materializer.ex:182-212). Exempt via manages?(admin, member),
  # which MUST resolve admin's DURABLE identity caps (genesis wildcard), not ctx.caps.
  member = materializer_spawn_member(session)
  assert Enum.any?(Ezagent.Identity.read_entity_caps(member), &member_cap_over?(&1, session))
  refute Map.has_key?(read_pending(session), member)
end

test "anon self-admission (caller == member) still MOUNTS, does NOT go pending (over-fire guard)" do
  {session, _owner} = create_public_session()
  anon = anon_self_admit(session)               # anon_admission.ex:107 sets caller == anon
  assert Enum.any?(Ezagent.Identity.read_entity_caps(anon), &member_cap_over?(&1, session))
  refute Map.has_key?(read_pending(session), anon)
end

# 🔴 WORLD-UI INVITE BYPASS REGRESSION (test 33, spec §C.1 bypass 1) — world plugin test.
# invite_member/3 dispatches session.join directly with B's caps, NOT via
# provision_invited_join_authority — so this fails if the gate is scoped to one function.
test "World invite_member/3 of a cross-owner agent goes PENDING (test 33)" do
  {b_session, b} = create_session_with_owner()
  a = create_user(workspace_of(b_session))
  a_agent = create_cc_agent(owner: a, workspace: workspace_of(b_session))
  socket = world_socket(current_entity: b, session: b_session)     # B's identity + caps
  {:noreply, _} = Ezagent.World.ConversationActions.invite_member(socket, b_session, to_string(a_agent))
  assert Map.has_key?(read_pending(b_session), a_agent)            # NOT mounted
  refute Enum.any?(Ezagent.Identity.read_entity_caps(a_agent), &member_cap_over?(&1, b_session))
  refute Map.has_key?(read_members(b_session), a_agent)
end

# 🟠 CROSS-SESSION ROUTING (test 34, spec §C.1 bypass 2 — covered by R1.1) — session domain.
# The inline cross_session_send_caps mints :send only; a non-member A-agent still cannot receive.
test "cross-session forward cannot confer receive to a non-member agent (test 34)" do
  {src_session, _} = create_session_with_owner()
  {tgt_session, _} = create_session_with_owner(workspace: workspace_of(src_session))
  a_agent = create_cc_agent(workspace: workspace_of(src_session)) # NOT a member of tgt_session
  msg = build_message(sender: sender_of(src_session))
  Ezagent.Behavior.Session.Delivery.dispatch_cross_session_call(tgt_session, msg, src_session)
  refute receive_delivered?(tgt_session, a_agent)                 # holds no member-cap → R1.1 denies
  refute_flavor_adapter_invoked(a_agent)                          # credential not spent
end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** the trigger at the COMMON chokepoint (`handle_join` → `do_join_apply` grant seam), keyed on `ctx.caller`: fire pending iff a real non-system caller is neither the member nor a manager (`manages?` resolved from the caller's DURABLE identity caps). All non-add mounts (materializer/admin, self/anon self-admission, own-agent/admin add) take the existing grant+mount path unchanged. **Verify the over-fire guard tests + test 33 (world invite) pass** — do NOT scope the gate to one invite function and do NOT read `manages?` off `ctx.caps`.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_session
git commit -m "feat(session): admission trigger branch + :pending_members — cross-owner add pending, no cap (C.1)"
```

---

### Task C.2: Approve / deny / withdraw actions (approve = R3.1 grant + mount)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` — `:approve_admission` (grant member-cap via the R3.1 abort-safe grant + `do_join_apply` mount + drop pending), `:deny_admission` (drop pending), `:withdraw_admission` (drop pending, requester-only).
- Register the three actions on the Session behavior (via `use Ezagent.Lifecycle`).
- Test: `apps/ezagent_domain_session/test/ezagent/session/admission_approve_test.exs`

**Interfaces:**
- Consumes: `Ezagent.Identity.Authority.manages?/2` (B.1), the R3.1 abort-safe grant + `do_join_apply` mount (A2.4/A1.2).
- Produces: approve → member mounted (holds the cap, can receive); deny/withdraw → pending dropped, no cap.

**Authz (spec §C.4/§C.5):** approve/deny require `Authority.manages?(actor, member)`; withdraw requires `requested_by == actor`. A failed approve-grant is R3.1 abort-safe — the removal ABORTS and the request stays PENDING (loud, no half-mount).

- [ ] **Step 1: Write failing tests (spec tests 31, 32)**

```elixir
# admission_approve_test.exs
test "owner (manages member) approves → member mounts and can receive (test 31)" do
  {b_session, b, a, a_agent} = pending_cross_owner_add()
  :ok = approve_admission(b_session, a_agent, by: a)              # A manages A's agent
  assert Enum.any?(Ezagent.Identity.read_entity_caps(a_agent), &member_cap_over?(&1, b_session))
  post(b_session, b, "now allowed")
  assert receive_delivered?(b_session, a_agent)                  # now a functional member
  refute Map.has_key?(read_pending(b_session), a_agent)
end

test "non-manager approve is rejected, zero mutation (test 31)" do
  {b_session, b, _a, a_agent} = pending_cross_owner_add()
  assert {:error, _} = approve_admission(b_session, a_agent, by: b)   # B does NOT manage A's agent
  assert Map.has_key?(read_pending(b_session), a_agent)              # untouched
  refute Enum.any?(Ezagent.Identity.read_entity_caps(a_agent), &member_cap_over?(&1, b_session))
end

test "deny drops pending, no cap ever granted; withdraw by requester drops pending (test 32)" do
  {b_session, b, a, a_agent} = pending_cross_owner_add()
  :ok = deny_admission(b_session, a_agent, by: a)
  refute Map.has_key?(read_pending(b_session), a_agent)
  # withdraw path
  {b_session2, b2, _a2, a_agent2} = pending_cross_owner_add()
  :ok = withdraw_admission(b_session2, a_agent2, by: b2)          # requester withdraws
  refute Map.has_key?(read_pending(b_session2), a_agent2)
end

test "approve whose grant COMMIT fails aborts, request stays PENDING (R3.1 abort-safe, test 32)" do
  {b_session, _b, a, a_agent} = pending_cross_owner_add()
  force_grant_commit_failure(a_agent)
  assert {:error, _} = approve_admission(b_session, a_agent, by: a)
  assert Map.has_key?(read_pending(b_session), a_agent)          # still pending, nothing mounted
  refute Enum.any?(Ezagent.Identity.read_entity_caps(a_agent), &member_cap_over?(&1, b_session))
end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** the three actions; approve re-enters the grant+mount tail (R3.1 abort-safe grant → `do_join_apply` → drop pending). Authz-gate each.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_session
git commit -m "feat(session): approve/deny/withdraw admission actions — approve = R3.1 grant + mount (C.2)"
```

---

### Task C.3: Notify the owner of a pending request (managers_of(member) as subject)

**Files:**
- Modify: the cascade component (Phase B) OR the admission action (C.1) — fire the notify to `managers_of(pending_member)` on a new pending request.
- Test: `apps/ezagent_domain_session/test/ezagent/session/pending_notify_test.exs`

**DEMOTED — implementer picks the wiring, constraint pinned (spec §C.3, the cascade-subject trap):** the pending request notifies `managers_of(the pending MEMBER) = A`, content-free (envelope `{member, session, request_ref}`, no message/cap content). It must NOT notify `managers_of(the session) = B`. Choose: a direct `managers_of(member)→notify` call from the admission action, OR generalize the B.3 hook to carry an explicit notify-subject for a `{session, :pending_members}` change. Do NOT wire the pending change naively to the generic `{entity,:caps}` hook (it resolves managers of the SESSION = B — the wrong target).

- [ ] **Step 1: Write failing test (spec test 29 — the discriminator)**

```elixir
# pending_notify_test.exs
test "pending cross-owner add notifies the MEMBER's managers (A), NOT the session's (B) (test 29)" do
  {b_session, b} = create_session_with_owner()
  a = create_user(workspace_of(b_session))
  a_agent = create_cc_agent(owner: a, workspace: workspace_of(b_session))
  spy = install_notify_spy()
  :ok = add_member(b_session, a_agent, by: b)                    # pending
  assert spy.notified?(a)                                        # managers_of(a_agent) = A
  refute spy.notified?(b)                                        # NOT managers_of(session)
  assert spy.payload_content_free?()                            # {member, session, request_ref} only
end
```

- [ ] **Step 2: Run → FAIL.**

- [ ] **Step 3: Implement** the pending-member-subject notify per the pinned constraint.

- [ ] **Step 4: Run → PASS.**

- [ ] **Step 5: Commit.**

```bash
git add apps/ezagent_domain_session
git commit -m "feat(session): notify managers_of(pending member) on a pending admission request (C.3)"
```

---

### Task C.4: §14.5(A) PRIMARY prevention acceptance + approve-UX agent-browser scenario (§14.5 B)

**Files:**
- Modify: `apps/ezagent_domain_session/test/ezagent/acceptance/member_cap_cascade_acceptance_test.exs` — replace the skipped steps-1-4 stub with the live PRIMARY prevention flow; keep step 5 (defense-in-depth) and step 6 (cascade).
- Create: `docs/scenarios/2026-07-04-member-cap-cascade.md` — the world-UI agent-browser approve-UX scenario (§14.5 B).

- [ ] **Step 1: Write the §14.5(A) PRIMARY prevention acceptance (steps 1-5) — the DONE-GATE**

```elixir
# member_cap_cascade_acceptance_test.exs
test "§14.5(A) PRIMARY: cross-owner add PENDING ⇒ cannot receive (cred not spent) ⇒ approve ⇒ mounts; defense-in-depth revoke" do
  {b_session, b} = create_session_with_owner()
  a = create_user(workspace_of(b_session))
  a_agent = create_cc_agent(owner: a, workspace: workspace_of(b_session))

  # Step 1: cross-owner add → PENDING, no cap, not mounted
  :ok = add_member(b_session, a_agent, by: b)
  assert Map.has_key?(read_pending(b_session), a_agent)
  refute Enum.any?(Ezagent.Identity.read_entity_caps(a_agent), &member_cap_over?(&1, b_session))

  # Step 2: 🔴 PRIMARY PREVENTION — B posts, A's-agent does NOT receive, does NOT run, cred NOT spent
  post(b_session, b, "run my prompt")
  refute receive_delivered?(b_session, a_agent)
  # ⚠️ Q3: credential-non-spend is asserted at the FLAVOR-ADAPTER boundary, NOT process
  # liveness — dispatch_receive_call/3 may ensure_live/1 the worker (session/delivery.ex:163-165)
  # BEFORE the receive-authz denial, so a live process is NOT proof of a spend. Assert the
  # bridge/flavor adapter deliver call (AgentBridge.deliver_*, the OAuth spend) never fired.
  refute_flavor_adapter_invoked(a_agent)

  # Step 3: owner notified of the pending request (managers_of(a_agent) = A)
  assert notified?(a, :pending_admission, a_agent)

  # Step 4: approve → mount → now receives
  :ok = approve_admission(b_session, a_agent, by: a)
  post(b_session, b, "now allowed")
  assert receive_delivered?(b_session, a_agent)

  # Step 5: defense-in-depth — remove ⇒ revoke ⇒ immediate deny, no reconcile
  :ok = remove_participant(b_session, a_agent, by: b)
  post(b_session, b, "again")
  refute receive_delivered?(b_session, a_agent)
  refute reconcile_was_run?(b_session)
end
```

- [ ] **Step 2: Run → PASS** (whole §14.5(A) now green: prevention steps 1-4 + defense-in-depth step 5 + Phase B's step 6).

> **Expected (not a bug):** approve (step 4) grants the member-cap, which itself fires the Part B `{entity, :caps}` cascade → A gets a **second** notice (the grant it just approved), on top of the C.3 pending-request notice (step 3). Harmless; note it so a reviewer doesn't read the double-notify as a defect. (De-dup is a future polish, not in scope.)

- [ ] **🧑 Step 3: Write + run the §14.5(B) approve-UX agent-browser scenario.** On a running disposable stack (`feedback_disposable_stack_e2e`: fresh `EZAGENT_HOME`, dev mode, PORT), drive the world UI: B opens S, adds A's cc agent via the roster/picker; capture (1) A's agent shown as **PENDING** (awaiting approval), NOT a live member; (2) A's notification surface showing the **approvable pending request**; (3) after A approves, the roster showing A's agent now **mounted**. Save screenshots + steps to `docs/scenarios/2026-07-04-member-cap-cascade.md`. Use the remote browser IP `100.64.0.27` (`feedback_remote_browser_ip`), never localhost. **Operator/environment-dependent step.**

- [ ] **Step 4: Commit.**

```bash
git add apps/ezagent_domain_session/test docs/scenarios/2026-07-04-member-cap-cascade.md
git commit -m "test(admission): §14.5(A) PRIMARY prevention acceptance green; approve-UX agent-browser scenario captured (C.4)"
```

**Phase C done-gate:** tests 27-34 green (incl. **test 33 World-invite bypass → PENDING** and **test 34 cross-session routing covered-by-R1.1**); §14.5(A) PRIMARY (step 2, credential-non-spend asserted at the flavor-adapter boundary per Q3) + steps 1,3,4 green deterministically; §14.5(A) fully green; §14.5(B) three approve-UX screenshots captured. `/codex:adversarial-review`. **C is one PR (PR-4); ships on top of merged A2+B. X is closed when PR-4 lands.**

---

## Self-Review

**Spec coverage — every requirement maps to a task:**
- R1.1 roster⟂authz → A2.2 (receive) + A2.3 (read) + tests 20-22. R1.2 `MemberReceive`/cap_exempt/parity → A2.1+A2.2, test 24. R1.3 JOIN grant-first+compensation → A1.2, test 23. R1.4 `Entity.Agent.list_in_workspace` → A1.1, test 26. R1.5/R2.2 migration → A1.4, test 25. R1.6/§14.5 done-gate → A2.6 (defense-in-depth step 5) + B.4 (cascade step 6) + **C.4 (PRIMARY prevention steps 1-4 + approve-UX §14.5 B)**.
- R2.1/R3.1 three removal sequences → A2.4, tests 10-11 + abort-safe revoke. R2.3 two receive sites, `Agent.Receive` before bridge → A2.2. R2.4/R3.2 post-commit replay/notify → A2.5. R2.5 stale §4.2 prose → obsolete (implemented as R1.1, no code owner needed).
- R3.2 migration idempotency + grant-confirmation → A1.4 acceptance cases. Part B K2/K3/K4/K5 → B.1/B.3/B.2. §7 `:send` tiering unchanged → A1.2 (preserved). §8 presence unchanged → A2.4 test 9.
- **R4/Part C/K7 admission gate → Phase C:** C.1 trigger branch at the `handle_join` chokepoint (all entry paths) + `:pending_members` (tests 27,28,30 — incl. the PRIMARY prevention core; **test 33 World-invite bypass → PENDING**; **test 34 cross-session routing covered-by-R1.1**); C.2 approve/deny/withdraw = R3.1 grant+mount (tests 31,32); C.3 pending-member-subject notify (test 29, the cascade-subject discriminator); C.4 §14.5(A) PRIMARY acceptance (credential-non-spend at the flavor-adapter boundary, Q3) + §14.5(B) approve UX. **Security half entirely composed** (R1.1 "pending cannot receive" + R3.1 abort-safe grant); NEW = `:pending_members` + 3 actions + trigger + pending-subject notify.
- **§12 phasing honored** (A1 additive-first, A2 atomic cutover, B cascade, **C admission/prevention — closes X**). **§16 risk 4** → 🧑 lead sign-off before A2; **§16 risk 5** (cross-owner add now pending) → 🧑 lead sign-off before C. **§16 risk 3 cross-app placement** → Global Constraints + A1.1 note; **§C.1 all-entry-paths chokepoint (`handle_join`, keyed on `ctx.caller`)** → Global Constraints + C.1 (the trigger is a requirement over all member-add paths, NOT scoped to `provision_invited_join_authority`; corrects the world-invite under-fire).

**Placeholder scan:** the only non-code "implementer picks" spots are the task-licensed DEMOTED/PROPOSED items (R3.1 revoke inline-vs-deferred; R3.2 replay/notify wiring; migration idempotency predicate + sync flag; teardown authority/execution split; `MemberReceive.authorize` predicate; **Part C: the pending-notify wiring §C.3 + `:pending_members` shape / action plumbing**) — each has a pinned constraint + a concrete acceptance test. All other steps carry concrete code/commands.

**Type consistency (Part C):** `Authority.manages?/2` (B.1) → C.1 trigger + C.2 approve/deny authz. `managers_of/1` (B.2) → C.3 pending notify. `member_cap/2` (A1.1) + R3.1 grant + `do_join_apply` (A1.2/A2.4) → C.2 approve→mount. `:pending_members` slice (C.1) → C.2/C.3/C.4. Consistent.

**Type consistency:** `member_cap/2` (A1.1) → used by A1.2/A1.3/A1.4/A2. `Entity.Agent.list_in_workspace/1` (A1.1) → A1.3/A1.4. `MemberReceive.authorize/1` (A2.1) → A2.2 + parity test. `Ezagent.Identity.Authority` (B.1, NEW — distinct from existing `AdminAuthority`) → B.2. `managers_of/1` (B.2) → B.3/B.4. Consistent throughout.

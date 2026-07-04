# Membership-Cap Unification + Cascade Notification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "member of session S" a **capability the member HOLDS** (`cap(:session, Ezagent.ActionSet.Session, :receive, instance: S, ws)` in the member's own `:identity`/`:caps` slice), demote the session `:members` slice to a delivery/presence cache, move receive- and read-authorization onto the held cap, and add a one-level manage/owner **cascade notification** on cap/membership changes.

**Architecture:** Three merge-safe phases landing one architecture (spec §12): **A1** adds the member-cap as an *additive, behavior-preserving* foundation (grant-at-join + reconcile + migration) while delivery still uses the old ephemeral mint; **A2** is the atomic cutover (receive/read authz read the held cap, the ephemeral mint is deleted, leave/remove revoke the cap) — this phase carries the security done-gate; **B** rides on A2's member-slice-change to notify managers/owners. Roster (staleness-tolerant delivery targeting) is kept **⟂ separate** from receive-authorization (the recipient's *actually held* cap) — R1.1, the load-bearing invariant.

**Tech Stack:** Elixir umbrella (`apps/ezagent_core`, `apps/ezagent_domain_session`, `apps/ezagent_domain_identity`, `apps/ezagent_domain_agent`, `apps/ezagent_plugin_world`), Ezagent Lifecycle/ActionSet Behaviors, CapBAC capability primitives, ExUnit, `mix ezagent.*` CLI tasks, agent-browser for the UI acceptance scenario.

**Spec:** `docs/superpowers/specs/2026-07-04-membership-cap-unification-cascade-design.md`. **Precedence R3 > R2 > R1 > prose.** Read R3.1 (reframed REMOVE), R1.1 (roster⟂authz), R2.3 (2 receive sites), §14.5 (done-gate) before implementing.

## Global Constraints

- **Precedence when the spec conflicts with itself:** R3 > R2 > R1 > original prose. Several original §§ (§4.2, §5, §6, §8, K1, K6) are patched by later R-sections; always follow the R-section.
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
| **A2** | receive-authz cutover (`MemberReceive.authorize/1`, `:receive` cap_exempt, parity test) + **delete `member_receive_caps/1`** + socialware read → held-cap + leave/remove revoke (3 R3.1 sequences) + post-commit replay/notify + anon holds member-cap + **ExUnit security acceptance test (§14.5 A)** | **NO** — atomic cutover; must land as one | **PR-2** | Tests 6-12, 20-24; **§14.5(A) step 5 passes WITHOUT reconcile** — the single load-bearing assertion |
| **B** | extract `Ezagent.Identity.Authority` (K2) + cascade hook at emit chokepoint (K3) + `managers_of/1` (K4/K5) + content-free notify + cascade E2E + agent-browser scenario (§14.5 B) | **YES** — additive advisory notify, off the mutating path | **PR-3** | Tests 13-19; §14.5(A) steps 2&4 (cascade+removal-notify); §14.5(B) two screenshots captured |

**Independently shippable:** A1 alone (foundation), then B alone on top of A2 (cascade is additive/advisory). **Must land together:** the whole of A2 is one atomic landing — see the A2 preamble for why (§14.5 step 5 is the done-gate that can only pass when receive-reads-held-cap AND leave/remove-revoke-held-cap both exist). **Recommended: 3 PRs (A1, A2, B).** Optional internal splits noted per phase for reviewability, but A2's sub-tasks may NOT merge independently.

**Human/lead-action steps (flagged inline with 🧑):**
- 🧑 **Before A2:** lead sign-off on spec §16 open-risk #4 — the behavior shift "failed member-cap grant ⇒ not a member" (best-effort → fail-closed for the membership-defining cap). Spec explicitly defers this to the lead.
- 🧑 **A1 deploy-time:** operator runs `mix ezagent.migrate.member_caps` (with `--dry-run` first, then live) in each environment. R2.2: live-grant write is safe on a running node, but the *decision to run* is an operator action.
- 🧑 **Per phase:** `/codex:adversarial-review` gate (pre-impl + at PR open).
- 🧑 **§14.5(B):** the agent-browser world-UI scenario needs a running disposable stack (fresh `EZAGENT_HOME`, dev mode, PORT — `feedback_disposable_stack_e2e`); operator/environment-dependent.

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

**Phase goal:** Flip receive- and read-authorization onto the held member-cap, delete the ephemeral mint, and make leave/remove revoke the cap — so a revoked member loses receive **immediately, without waiting for reconcile** (§14.5 step 5).

**Why A2 is atomic (must land as one PR, sub-tasks may NOT merge independently):** The held-cap model is only *coherent* when both halves land together — receive-reads-held-cap (A2.1/A2.2) AND leave/remove-revoke-held-cap (A2.4). The load-bearing done-gate §14.5 step 5 ("revoke ⇒ immediate deny, proven WITHOUT reconcile") can only pass when both exist. (Note: `leave_effects/2` still `Map.delete`s the roster entry, so a left member drops out of fan-out regardless; receive-cutover *alone* would merely add a check redundant with the still-load-bearing roster-drop — it is not independently *useful*, and the security property is unproven until revoke lands. Hence one atomic landing.)

**Phase dependencies:** A1 (member-caps must exist and be granted at join, else no held cap to authorize against).

**🧑 Before starting A2:** obtain lead sign-off on spec §16 open-risk #4 (best-effort → fail-closed for the membership-defining cap). Blocking human action.

**Phase done-gate:** tests 6-12, 20-24 pass; the §14.5(A) ExUnit security acceptance test passes IN FULL, **especially step 5** — proven without re-activating the session. `/codex:adversarial-review`.

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
- Test: `apps/ezagent_domain_session/test/ezagent/acceptance/member_cap_cascade_acceptance_test.exs` (§14.5 A — cross-app integration; session domain owns membership+delivery). Steps 2 & 4 (cascade) are stubbed/skipped until Phase B; steps 1, 3, 5 (security) are live in A2.

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

- [ ] **Step 2: Write the §14.5(A) security acceptance test — the DONE-GATE**

```elixir
# member_cap_cascade_acceptance_test.exs
test "§14.5(A): membership-as-cap delivery + CRITICAL immediate-deny-on-revoke, no reconcile" do
  {b_session, b} = create_session_with_owner()
  a = create_user(workspace_of(b_session))
  a_agent = create_cc_agent(owner: a, workspace: workspace_of(b_session))

  # Step 1: cross-user add — B grants the member-cap to A's-agent
  :ok = add_member(b_session, a_agent, by: b)

  # Step 3: membership-as-cap delivery — B posts, A's-agent :receive fires
  post(b_session, b, "hello")
  assert receive_delivered?(b_session, a_agent)

  # Step 5: 🔴 CRITICAL SECURITY PROOF — B removes A's-agent, then posts again
  :ok = remove_participant(b_session, a_agent, by: b)     # revoke the member-cap
  post(b_session, b, "again")
  refute receive_delivered?(b_session, a_agent)           # DENIED immediately...
  # ...proven WITHOUT re-activating the session (never call reconcile_after_load/2)
  refute reconcile_was_run?(b_session)
end
```

> Steps 2 (cascade proof) and 4 (grant/revoke cascade to X) are added in Phase B (Task B.4). In A2 they are `@tag :skip`-ed with a pointer to B.4.

- [ ] **Step 3: Run → PASS** (security steps live; cascade steps skipped).

- [ ] **Step 4: Commit.**

```bash
git add apps/ezagent_domain_session/test
git commit -m "test(session): blast-radius guards + §14.5(A) security acceptance (immediate deny on revoke, no reconcile) (A2.6)"
```

**Phase A2 done-gate (verify before opening PR-2):** tests 6-12, 20-24 green; §14.5(A) step 5 green and **proven without reconcile**; full suite green; §16 risk-4 lead sign-off obtained; `/codex:adversarial-review`. **The whole of A2 = one PR (PR-2); A2.1-A2.6 do NOT merge independently.**

---

# PHASE B — cascade notification (rides on A2, additive/advisory)

**Phase goal:** On a member-cap (or other allowlisted `{entity, :caps}`) slice-change on entity X, resolve X's one-level manage/owner holders and notify their inboxes — closing the S1 removal-notify gap for free.

**Phase dependencies:** A2 (join/leave/remove must produce a slice-change on the MEMBER's own `:identity`/`:caps` slice — that is what B subscribes to). B is additive and advisory: it runs on the post-commit `DeferredDispatch` turn, off the mutating dispatch's critical path (a slow/failing cascade cannot roll back the mutation).

**Phase done-gate:** tests 13-19 pass; §14.5(A) steps 2 & 4 (cascade + removal-notify) un-skipped and green; §14.5(B) two agent-browser screenshots captured. `/codex:adversarial-review`.

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

### Task B.4: Un-skip §14.5(A) cascade steps + removal-notify + agent-browser scenario

**Files:**
- Modify: `apps/ezagent_domain_session/test/ezagent/acceptance/member_cap_cascade_acceptance_test.exs` — un-skip steps 2 & 4; add spec tests 13, 14.
- Create: `docs/scenarios/2026-07-04-member-cap-cascade.md` — the world-UI agent-browser scenario (§14.5 B).

- [ ] **Step 1: Un-skip / add cascade tests (13, 14, §14.5 steps 2 & 4)**

```elixir
test "§14.5 step 2: B adds A's-agent ⇒ A receives a cascade notification (13)" do ... end
test "§14.5 step 4: grant member-cap to X (owner Y) ⇒ Y notified; on revoke ⇒ Y notified (14, S1 gap closed)" do ... end
```

- [ ] **Step 2: Run → PASS** (whole §14.5(A) now green incl. steps 2 & 4).

- [ ] **🧑 Step 3: Write + run the §14.5(B) agent-browser scenario.** On a running disposable stack (`feedback_disposable_stack_e2e`: fresh `EZAGENT_HOME`, dev mode, PORT), drive the world UI: B opens S, adds A's cc agent via the roster/picker; capture (1) the roster showing A's agent as a member, (2) A's notification surface showing the cascade notice. Save screenshots + steps to `docs/scenarios/2026-07-04-member-cap-cascade.md`. Use the remote browser IP `100.64.0.27` (`feedback_remote_browser_ip`), never localhost. **Operator/environment-dependent step.**

- [ ] **Step 4: Commit.**

```bash
git add apps/ezagent_domain_session/test docs/scenarios/2026-07-04-member-cap-cascade.md
git commit -m "test(cascade): §14.5 cascade + removal-notify green; world-UI agent-browser scenario captured (B.4)"
```

**Phase B done-gate:** tests 13-19 green; §14.5(A) fully green; §14.5(B) screenshots captured. `/codex:adversarial-review`. **B is one PR (PR-3); ships independently on top of a merged A2.**

---

## Self-Review

**Spec coverage — every requirement maps to a task:**
- R1.1 roster⟂authz → A2.2 (receive) + A2.3 (read) + tests 20-22. R1.2 `MemberReceive`/cap_exempt/parity → A2.1+A2.2, test 24. R1.3 JOIN grant-first+compensation → A1.2, test 23. R1.4 `Entity.Agent.list_in_workspace` → A1.1, test 26. R1.5/R2.2 migration → A1.4, test 25. R1.6/§14.5 done-gate → A2.6 (security) + B.4 (cascade/UI).
- R2.1/R3.1 three removal sequences → A2.4, tests 10-11 + abort-safe revoke. R2.3 two receive sites, `Agent.Receive` before bridge → A2.2. R2.4/R3.2 post-commit replay/notify → A2.5. R2.5 stale §4.2 prose → obsolete (implemented as R1.1, no code owner needed).
- R3.2 migration idempotency + grant-confirmation → A1.4 acceptance cases. Part B K2/K3/K4/K5 → B.1/B.3/B.2. §7 `:send` tiering unchanged → A1.2 (preserved). §8 presence unchanged → A2.4 test 9.
- **§12 phasing honored** (A1 additive-first, A2 atomic cutover, B rides on top). **§16 risk 4** → 🧑 lead sign-off before A2. **§16 risk 3 cross-app placement** → Global Constraints + A1.1 note.

**Placeholder scan:** the only non-code "implementer picks" spots are the task-licensed DEMOTED/PROPOSED items (R3.1 revoke inline-vs-deferred; R3.2 replay/notify wiring; migration idempotency predicate + sync flag; teardown authority/execution split; `MemberReceive.authorize` predicate) — each has a pinned constraint + a concrete acceptance test. All other steps carry concrete code/commands.

**Type consistency:** `member_cap/2` (A1.1) → used by A1.2/A1.3/A1.4/A2. `Entity.Agent.list_in_workspace/1` (A1.1) → A1.3/A1.4. `MemberReceive.authorize/1` (A2.1) → A2.2 + parity test. `Ezagent.Identity.Authority` (B.1, NEW — distinct from existing `AdminAuthority`) → B.2. `managers_of/1` (B.2) → B.3/B.4. Consistent throughout.

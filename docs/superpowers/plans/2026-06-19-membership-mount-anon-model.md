# Unified membership-mount + anon model — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make session participation cap-mounted at join per member class, with anon = a `confirmed:false` user, so the chat fan-out system principals (`chat-reply`, `chat-router`, `lv-anon-mount`, `socialware-gc`) dissolve.

**Architecture:** One join flow mounts a per-class cap tier; join authority comes from session policy (not a universal baseline); anon is a first-class `confirmed:false` user state; login = re-join at a higher identity with footprint takeover (route B).

**Tech Stack:** Elixir/OTP umbrella, Ecto/SQLite, CapBAC (`Ezagent.Capability`), `Ezagent.Identity.Grant`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-06-19-membership-mount-anon-model-design.md` (verbatim authority).
- `no_unowned_system_principal_grant_test` stays **0** across every PR.
- Every PR: implement → subagent adversarial review → FULL gate suite (`system_principal_elimination` + `no_unowned` + `no_admin_caps_fallback` + `no_wildcard_system_principals` + `system_principal_catalog_action_audit` + `mix ezagent.arch.scan` all_slices + `mix ezagent.check_invariants` + `mix ezagent.doc.scan`) → admin-merge.
- Zero new test failures, proven against a clean base ([[feedback_zero_new_failures_baseline_proof]]).
- Migrations additive only, no destructive change on live DB ([[feedback_destructive_migration_anti_pattern]]).
- Worktree: `/Users/h2oslabs/Workspace/esr-ng/.worktrees/elim`. Run gates scoped to an app (e.g. `cd apps/ezagent_core && mix test ...`) to avoid the `ezagent_web` esbuild/npm step.

---

## PR-甲-1: `confirmed` attribute on users (behavior-preserving)

**Goal:** Add a real `confirmed` boolean to users; anon detection reads it instead of the `anon-` URI name-prefix. No cap/authorization change yet.

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260619010000_add_confirmed_to_users.exs`
- Modify: `apps/ezagent_domain_identity/lib/ezagent/users.ex` (schema `field`, `decode/1`, `create/3` → `confirmed: true`, `create_read_only/2` → `confirmed: false`, `reserved_anon_name?`→ attribute-aware)
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` (`anon_member?/1` → prefer the attribute, name-prefix fallback during migration)
- Test: `apps/ezagent_domain_identity/test/ezagent/users_confirmed_test.exs`

**Interfaces:**
- Produces: `Ezagent.Users.decoded()` gains `confirmed: boolean()`; `Ezagent.Users.confirmed?(uri) :: boolean()` (reads the row, default false on missing).
- Consumes: nothing new.

- [ ] **Step 1: Write the migration** (additive column, default false, backfill existing → true)

```elixir
defmodule Ezagent.Core.Repo.Migrations.AddConfirmedToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :confirmed, :boolean, null: false, default: false
    end
    # Backfill: every PRE-EXISTING user is a real (confirmed) user. New anon
    # rows insert confirmed:false explicitly (create_read_only). The reserved
    # anon- name prefix marks the only rows that should stay false.
    execute("UPDATE users SET confirmed = TRUE WHERE uri NOT LIKE '%/user/anon-%'")
  end

  def down do
    alter table(:users) do
      remove :confirmed
    end
  end
end
```

- [ ] **Step 2: Add the schema field + decode** in `users.ex`

In `schema "users"` add `field(:confirmed, :boolean, default: false)`. In `decode/1` include `confirmed: row.confirmed`. Add to the `@type decoded` map `confirmed: boolean()`.

- [ ] **Step 3: Write failing test** `users_confirmed_test.exs`

```elixir
test "create/3 makes a confirmed user; create_read_only/2 makes an unconfirmed user" do
  {:ok, u} = Ezagent.Users.create("entity://t/user/alice", "pw-not-secret", [])
  assert u.confirmed == true
  {:ok, a} = Ezagent.Users.create_read_only("entity://t/user/anon-xyz", [])
  assert a.confirmed == false
  assert Ezagent.Users.confirmed?(Ezagent.URI.new!("entity://t/user/alice")) == true
  assert Ezagent.Users.confirmed?(Ezagent.URI.new!("entity://t/user/anon-xyz")) == false
end
```

- [ ] **Step 4: Run it, verify it fails** — `cd apps/ezagent_domain_identity && mix test test/ezagent/users_confirmed_test.exs` → FAIL (`confirmed` not set / `confirmed?/1` undefined).

- [ ] **Step 5: Implement** — in `create_read_only/2`'s changeset add `confirmed: false`; in `do_create/3`'s changeset add `confirmed: true`; add `def confirmed?(uri)` reading the row (`get_by_uri`), default false. Keep `reserved_anon_name?` for the `create/3` reject (the `anon-` prefix is still RESERVED so a real user can't grab it), but it no longer DEFINES anon-ness — the attribute does.

- [ ] **Step 6: Make `anon_member?/1` attribute-first** in `membership.ex`

```elixir
# 2026-06-19 (#154): anon-ness is the `confirmed:false` attribute, not the URI
# name. During migration we still honor the `anon-` prefix as a fallback for
# rows not yet carrying the attribute; remove the fallback in PR-甲-6.
def anon_member?(%URI{scheme: "entity"} = uri) do
  cond do
    not user_uri?(uri) -> false
    Ezagent.Users.confirmed?(uri) -> false
    true -> true
  end
end
def anon_member?(_), do: false
```
(Drop the name-split path; the attribute is authoritative, `confirmed?` returns false for absent rows so the anon-name reserved-prefix users still classify as anon until backfilled.)

- [ ] **Step 7: Run the test + the existing anon/membership suites** — `cd apps/ezagent_domain_identity && mix test test/ezagent/users_confirmed_test.exs` (PASS) and the socialware anon tests `cd apps/ezagent_domain_socialware && mix test` (anon_public_view/anon_binding green).

- [ ] **Step 8: Migration runs clean** — `cd apps/ezagent_core && mix ecto.migrate` on the test DB (NOT a live dev DB — [[feedback_destructive_migration_anti_pattern]]); confirm up+down.

- [ ] **Step 9: FULL gate suite** (Global Constraints) — all green; ratchet UNCHANGED at 6 (no principal removed yet); `no_unowned` 0.

- [ ] **Step 10: Commit + PR + admin-merge**

```bash
git add -A && git commit -m "feat(identity): confirmed attribute on users (#154 甲-1)"
```

---

## PR-甲-2: per-class cap mount at join + session-policy join authority (LOAD-BEARING)

**Goal:** Mount the per-class participation tier at join; remove the broad `default_caps` baseline; authorize join from session policy. **This is the refactor that failed before — the gate is re-running its 8 failures.**

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity/user.ex` (`default_caps/1` — narrow/remove the `Session:any:any` baseline)
- Modify: `apps/ezagent_domain_identity/lib/ezagent_domain_identity/application.ex` (the `register_default_grant(User, default_caps)` registration, if present)
- Modify: `apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex` (`mount_participation_caps/3` by class; join-authz in `handle_join`)
- Reference (build on): branch `feat/per-session-default-caps` commit `e5b51888` — `grant_participation_caps/3` + `session_participation_caps_test.exs` (272 lines). `git show e5b51888 -- <path>` to lift the working `:async`/cast grant + telemetry shape.
- Test: port + extend `apps/ezagent_domain_session/test/ezagent/behavior/session_participation_caps_test.exs`; add `apps/ezagent_domain_session/test/ezagent/behavior/join_authority_test.exs`

**Interfaces:**
- Produces: `Membership.mount_participation_caps(session_uri, member_uri, owner_uri) :: :ok` (class-keyed: confirmed user → send+leave+subscribe_from; unconfirmed → subscribe_from; agent → handled at spawn in 甲-3, no-op here).
- Consumes: `Ezagent.Users.confirmed?/1` (甲-1).

- [x] **Step 1: Audit DONE (2026-06-19).** Root cause: `session.ex action(:join, caps: [:join])` ⇒ dispatch step-5.5 requires the caller hold `cap(:session, Session, :join, instance)`; today that comes from `User.default_caps` broad `cap(:session,:any,:any)` (matches :join). The prior branch zeroed `default_caps` with NO replacement join authority → self-join unauthorized → 8 failures.
  **Join access-point census (who joins + current authority):**
  - `anon_user.ex` mint + `chat_feed_controller.ex` — anon joins with its OWN minted `cap(:session,Session,:join,instance)`, `granted_by` owner (fallback admin). **Owner-rooted already ✓.**
  - `admin/invite.ex`, orchestrator `member_template.ex`, `template_team.ex`/`materializer.ex` (creation) — inviter/creator/owner authority. **Owner-rooted ✓.**
  - `stress.ex`, `seed_cc_agent.ex` — operator/admin inline caps. **System/operator ✓.**
  - **`admin/session_context.ex do_maybe_self_join` + `home_live.ex` — THE crux.** A logged-in user self-joins via the LV using `caller: caller_uri, caps: caller_caps` (their OWN caps incl. the broad baseline). This is the ONLY baseline-dependent join path. **KEY FINDING: it ALREADY degrades gracefully** — on `{:error, :unauthorized}` it flashes "ask the session owner to invite you, or you can only observe" (session_context.ex:133). So narrowing the baseline turns unauthorized self-joins into "observe", NOT crashes. The 8 failures are tests asserting self-join SUCCEEDS that now need per-policy provisioning or test updates to the new model.
  **Implication for the fix:** the should-SUCCEED self-join cases need policy-provisioned authority: (a) `public_view` session → provision the joiner a `cap(:session,Session,:join,instance)` `granted_by` owner at the access point (mirror anon mint); (b) owner/already-member → already authorized; (c) first-non-anon-join owner-claim → self-claim path. Everyone else → graceful "observe" (already handled).

- [ ] **Step 2: Write the join-authority tests (failing)** — `join_authority_test.exs`: (a) a confirmed user joins a `public_view` session WITHOUT any pre-held broad baseline → authorized; (b) a private session join by a non-owner without invite → rejected; (c) first-non-anon join claims owner. Encode the 8 audited paths as cases.

- [ ] **Step 3: Implement session-policy join authority** in `handle_join` — public_view → open; private → owner/inviter-authorized (the add-member dispatch carries inviter authority); keep `grant_first_join_owner_cap`. Run Step 2 tests → PASS.

- [ ] **Step 4: Write `mount_participation_caps` tests (failing)** — port `session_participation_caps_test.exs` from `e5b51888`; adjust tiers per spec §3.1 (unconfirmed = subscribe_from only; confirmed = +send+leave). Assert an unconfirmed member holds EXACTLY subscribe_from (no send); a confirmed member holds send.

- [ ] **Step 5: Implement `mount_participation_caps/3`** — lift the `e5b51888` `grant_participation_caps` (`:async`/cast, `{:rule, :session_participation, owner}`, best-effort, no-op for ownerless/agent), key the cap set on `Users.confirmed?/1` per spec §3.1. Call it from `handle_join` after membership is recorded. Run Step 4 tests → PASS.

- [ ] **Step 6: Narrow `default_caps/1`** — remove the broad `cap(:session, :any, :any)` baseline; keep ONLY a narrow `cap(:session, Session, :join)` IF the Step-1 audit shows a self-join path needs it, else remove entirely. Update/remove the `register_default_grant` registration accordingly.

- [ ] **Step 7: Re-run the 8 prior failures as the gate** — the `join_authority_test.exs` cases (Step 2) must all PASS with the narrowed baseline. This is the chicken-and-egg proof. If any fails, the join-authz model (Step 3) is incomplete — fix it, do NOT re-add the baseline.

- [ ] **Step 7b: OWNER-ROOTED-JOIN GATE (the 甲-2 acceptance invariant, spec §8 / Allen 2026-06-19).** Add `owner_rooted_join_test.exs` asserting: **(g1)** a user with NO broad baseline is REJECTED self-joining a private session (must be owner-authorized); **(g2)** an authorized join's grant `granted_by == session owner`, except the three documented exceptions — first-non-anon-join owner-claim / ownerless→`entity://system/user/admin` fallback / system-boot (bootstrap/admin); **(g3)** a `public_view` session admits a join via the public-view rule (configurer = owner). This test FAILS if join authority ever comes from a universal baseline — it is THE proof that the baseline removal is correct AND authority is owner-rooted. Run from the umbrella ROOT (cross-app deps), not `cd app`.

```elixir
# owner_rooted_join_test.exs (sketch — fill exact fixtures from Membership/Session)
test "g1: no-baseline user cannot self-join a PRIVATE session" do
  # owner O creates a private session; user U holds NO Session caps
  assert {:error, :unauthorized} = join_as(U, private_session)
end
test "g2: an authorized join's grant is granted_by the owner" do
  # O adds U → U joins; the participation/join grant's granted_by == O
  assert grant_granted_by(U, session) == O
end
test "g3: public_view session admits a join via the owner-configured rule" do
  assert {:ok, _} = join_as(U, public_view_session)
end
```

- [ ] **Step 8: Full identity + session + socialware suites green** — run from the umbrella ROOT (`mix test apps/ezagent_domain_identity/test`, etc.) — standalone `cd app` runs hit cross-app load artifacts (lesson 甲-1). Prove any residual failure pre-existing on a clean base. Behavioral proof.

- [ ] **Step 9: FULL gate suite + zero-new-failure baseline proof.** Ratchet still 6 (no principal removed yet — removals are 甲-3..6); `no_unowned` 0.

- [ ] **Step 10: Commit + subagent adversarial review + PR + admin-merge.**

---

## PR-甲-3..6 (planned after the foundation lands; detailed plans written then)

- **甲-3** — agent `Session:send` provisioned at spawn (thread session URI into Agent spawn; granter = spawner/owner); the cc/codex/echo/np/curl bridge adapters use the agent's own caps; delete `system://chat-reply` + gate ripple. *Ratchet 6→5.*
- **甲-4** — receive: implement R1 (member-consent receive cap granted to the session at join) or R2 (membership-gated cap-exemption) per spec §3.1; `sync_result`→agent self; `cross_session_forward`→`{:rule,:cross_session_forward,created_by||ws-admin}` + same-workspace guard; delete `system://chat-router` + ripple. *Ratchet 5→4.*
- **甲-5** — anon→login takeover (route B): a `confirm`/takeover Behavior action — a confirmed user (new or existing) joins + footprint transfer (re-point `Session.ReadMarker` + membership anon→user via the `AnonBinding` handle) + retire the anon. Ties to #17 interactive login (UI in spec 乙).
- **甲-6** — delete `system://lv-anon-mount` (LV mounts a `confirmed:false` user via the normal flow under the user's authority) + `system://socialware-gc` (reaper via admin/rule); remove the `anon-` name-prefix fallback from `anon_member?`. *Ratchet 4→2.*

After 甲: remaining = `session-internal` + `template-materialize` (separate, non-fan-out) + `bootstrap` genesis (last).

## Self-Review
- **Spec coverage:** §3.1 tiers → 甲-2 Step 4-5; §3.2 confirmed → 甲-1; §3.3 join authority → 甲-2 Step 3; §3.4 mount → 甲-2 Step 5; §3.5 takeover → 甲-5; §4 agent spawn → 甲-3; §4 delivery/chat-router → 甲-4; §4 anon family → 甲-6; §5 chicken-and-egg → 甲-2 Steps 1/7. All covered.
- **Placeholder scan:** 甲-1/甲-2 carry real code + commands; 甲-3..6 are deliberately outlined (detailed when the foundation lands — they depend on 甲-2's shape).
- **Type consistency:** `confirmed?/1`, `mount_participation_caps/3`, tier shapes consistent across tasks.

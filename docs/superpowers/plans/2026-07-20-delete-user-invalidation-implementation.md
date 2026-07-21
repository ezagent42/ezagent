# delete_user — invalidation-based revocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every implementer subagent MUST be dispatched with `Skill: ezagent-developer` and `Skill: elixir-phoenix-helper`.

**Goal:** Make `delete_user(U)` a *complete* revocation whose correctness does NOT depend on winning the race to kill U's owned/lineage agents: even a still-alive, busy agent is rendered INERT by a durable tombstone re-check at every authority-use chokepoint.

**Architecture:** Supersedes the held force-kill approach on `feat/delete-user-atomic-revocation` (#1469), which codex re-review 2 killed (F4 false-success, F1 agent-fence hole, false-convergence — see `docs/superpowers/specs/2026-07-19-delete-user-revoke-completeness-plan.md` §"Re-review 2"). The re-design keeps #1469's sound machinery (owned/lineage enumeration cascade, per-agent tombstone markers, token revoke, cap-clear, idempotent-retry) and replaces its broken correctness model with three pillars: (1) **honest `Kind.terminate` return** so teardown failure is observable; (2) **invalidation-based revocation** — the load-bearing pillar — where the transitive predicate `Ezagent.Identity.Offboarding.tombstoned_principal?/1` is consulted at every authority-USE chokepoint (cap-load, authenticate, the authz decision, the spawn/absorb fences), so a tombstoned principal is inert regardless of process liveness; (3) **an EtsOwner-restart-durable, agent-aware spawn/commit fence** closing F1.

**Tech Stack:** Elixir umbrella (ezagent), three-tier `core / domain / plugin`; CapBAC; `use Ezagent.Lifecycle` Behaviors; Ecto/Postgres durable state; ETS registries owned by `EzagentCore.EtsOwner`.

---

## THE CORRECTNESS KERNEL (read first — this is the spine)

`Ezagent.Identity.Offboarding.tombstoned_principal?/1` (already built on #1469, `apps/ezagent_domain_identity/lib/ezagent/identity/offboarding.ex`) is **transitive**: for an agent it returns `true` on its own marker **OR** its recorded creator tombstoned **OR** ANY lineage ancestor tombstoned (full-chain walk, depth 100). Therefore a derived agent becomes inert **the instant U's own user tombstone marker is durably committed** — even if the cascade never reached that agent, even if its process is alive and busy, because the predicate walks up to the deleted owner.

So the minimal correctness guarantee is exactly two facts:

1. **U's own tombstone marker (`users.deleted_at`) is durably committed** (the atomic step-1 transaction — already in `Users.tombstone/3` on #1469), AND
2. **the transitive predicate is consulted at EVERY authority-use chokepoint** (this plan's PR-1, PR-2, PR-6, PR-5).

Everything else — per-agent markers, `teardown_and_reap`, force-kill, snapshot clearing — is **cleanup + defense-in-depth, not the guarantee.** This kernel dissolves two of codex's three residuals directly:

- **F4 false-success** ("live agent still capable"): a live-but-inert agent is not "still capable" — cap-load returns `[]`, authenticate rejects, the authz decision denies. Liveness ≠ capability.
- **False-convergence** ("a sweep-skipped agent is skipped again while success returned"): a sweep-skipped derived agent is *still inert* via the owner/lineage arm of the predicate. Its own per-agent marker is a cleanup optimization, not the guarantee.

**One edge to name (backstop, not blocker):** an agent whose creator read AND lineage row are BOTH lost falls back to needing its own per-agent marker. This is why the idempotent sweep still runs (as the lost-linkage backstop) — but a sweep miss here is non-catastrophic degraded convergence, not the reopened-hole catastrophe the old model had.

Because the primary kill is at **cap-load** (`Ezagent.EntityCaps.load/1`), and dispatch/authorization sources caps through `EntityCaps.load(caller)` (verified: `apps/ezagent_domain_agent/lib/ezagent/domain/agent.ex:441,457`; `apps/ezagent_domain_identity/lib/ezagent/identity/authority.ex:110` — the "live-first K5" cap source), the invalidation core (PR-1, PR-2) is **epoch-independent** and lands on top of #1469 without waiting for any other program. The only chokepoint with an epoch dependency is the CORE-tier authz decision holder-check for INLINE-presented caps (PR-6) — see "Architectural convergence" below.

---

## Global Constraints

- **Base branch:** cut a new branch `feat/delete-user-invalidation` FROM `feat/delete-user-atomic-revocation` (#1469). This plan REUSES #1469's code (cascade enumeration, `AgentTombstone`, `Offboarding`, `Users.tombstone/3`, `SpawnFence`, token revoke, cap-clear, idempotent retry) and MODIFIES the broken parts. Do NOT re-implement from `main`.
- **`uv run` not `python`; `pnpm` not `npm`** — global hooks block raw `python`/`npm`.
- **No back-compat shims** (SPEC v2 §5.11) — delete legacy paths, don't keep them alongside new ones.
- **Three-tier layering is a hard invariant:** `ezagent_core` MUST NOT reference `ezagent_domain_*` modules. The tombstone truth lives in `ezagent_domain_identity` (`Users`, `AgentTombstone`, `Offboarding`). Any core-tier consultation of it goes through a registered-predicate registry (the `Ezagent.SpawnFence` pattern), never a direct call.
- **Formatter:** `mix format` only touched files; keep `mix precommit` as the final gate.
- **Fail-closed on the tombstone read** at every chokepoint: a DB/read failure is a DENY (return `[]` / `{:error, …}`), never a default-allow — EXCEPT the documented `DBConnection.OwnershipError` test-sandbox rescue already used in `Offboarding.refute_tombstoned/1` (a caller without a checked-out connection admits, because a real tombstone is still refused on every path that runs with DB access).
- **Verify env (shared PG drift):** `MIX_TEST_PARTITION=delinval MIX_ENV=test mix ecto.reset` before a suite run. `DBConnection.OwnershipError` in a run = known flake, re-run.
- **Reviewer gate:** the invalidation cap-model changes (PR-1, PR-4, PR-6) touch the core cap model → **codex adversarial review BEFORE kimi implements each**, and codex must confirm the terminate-timeout path is now a retryable-cleanup (not a false-success) with the new reproducing test. Never self-merge these.

---

## The atomicity boundary — REDEFINED (the design fork the old plan got wrong)

The held plan's Acceptance-5 ("teardown failure → retryable non-success") is the *force-kill* model and it **contradicts this task's headline** ("a busy agent whose terminate times out is STILL fully revoked"). You cannot have both. The re-design splits "success" along the line codex's ROOT exposed (`Kind.terminate/1`'s best-effort always-`:ok` contract is incompatible with "no success with a still-capable agent"):

| Sub-operation | On failure | Why |
|---|---|---|
| **Durable-invalidation commit** — U's marker + `caps_json`/slice clear + outbox dead-letter (the atomic step-1 txn) | `delete_user` returns **retryable non-success** | If invalidation is not durable, the agent *could* still act. This is the real atomicity boundary. |
| **Process kill / teardown / reap** (`Kind.terminate`, `Lifecycle.destroy`, `teardown_and_reap`) | **best-effort cleanup** — honest-terminate surfaces `{:error, :timeout}` so a reaper retries, but `delete_user` still returns `{:ok, _}` | The busy-timeout agent is already INERT via the kernel. Prove-inert, not prove-dead. |

This is the reconciliation of codex's ROOT: move the boundary from *prove-dead* to *prove-inert-via-durable-invalidation*. The headline test (the one that killed the old design, now GREEN): busy agent, terminate times out, markers committed → `delete_user` `:ok` **AND** the agent cannot authenticate/dispatch/load-caps **AND** it is queued for cleanup-retry.

Honest-terminate (pillar 1) is therefore **cleanup observability + test assertability, NOT the atomicity linchpin.** It is sequenced AFTER the invalidation core.

---

## Architectural convergence — ride the unified `authorize/3`, don't build a parallel chokepoint

Pillar 2's "tombstone re-check at every authority-use chokepoint" is the **same shape** as:
- epoch's per-cap **generation check** (`docs/superpowers/specs/2026-07-19-target-epoch-revocation-design.md` §3.1, the epoch *plan* `2026-07-20-epoch-revocation-implementation.md` is being written in parallel), and
- the read-plane **membership check**.

All three belong in the **single unified verifier** `authorize(holder_uri, presented_caps, needed)` that the epoch/cap-signing program is consolidating (epoch spec §3.1; today scattered across `Ezagent.Cap.Verifier` `apps/ezagent_core/lib/ezagent/cap/verifier.ex:81`, `Ezagent.Capability.Authorization`, the dispatch step-5.5 gate, `credential/resolver.ex:314`, `notification_subscriptions.ex:508`, `capability_registry.ex:449`).

**But note the two are different LAYERS, not two parallel chokepoints:**

- **cap-load** (`EntityCaps.load` → `[]` for a tombstoned holder, PR-1) is **source hygiene** — a per-HOLDER gate at the point caps are read from durable/live storage. It makes every downstream verifier see an empty cap set. This is DOMAIN-tier (can call `Offboarding` directly).
- **the authz decision holder-check** (PR-6) is the **use gate for INLINE-presented caps** (caps in `ctx.caps` that never passed through `EntityCaps.load` — e.g. a cached PTY ctx, admin genesis). It is per-HOLDER, and it rides the SAME `authorize/3` as epoch's per-CAP gen predicate — a *tombstone predicate alongside epoch's gen predicate*, not a second chokepoint. This is CORE-tier → it consults the domain predicate through a registry (the `SpawnFence` pattern), which is exactly what the unified `authorize/3` consolidation will host.

**Coordination rule (state in every PR-6 commit message):**
- If the epoch program's "unify authorize/3" has **already landed** when PR-6 starts → PR-6 is a *small predicate addition*: register/add `holder_not_tombstoned?` into the unified verifier alongside the gen predicate. **Do not** build a second gate.
- If it has **not** landed → PR-6 adds the holder-check at the current authz cap-check boundary (`Ezagent.Cap.Verifier`), structured to collapse into `authorize/3` when it lands (same registered-predicate shape).
- **PR-1 and PR-2 have NO such dependency** — they are epoch-independent and land first.

A third convergence point (non-blocking, see PR-9): both epoch and this program want a per-URI ETS hot-cache to keep the check off the DB on the hot path. A **fourth** convergence point is the enumerator GATE (PR-7): epoch (§8) and this program migrate the SAME list of authority-use sites — build the site-scan once, both checks ride it.

---

## The authority-USE chokepoints that need the tombstone re-check (enumeration)

| # | Chokepoint | File:line (on #1469 base) | Tier | This plan | Kind of gate |
|---|---|---|---|---|---|
| 1 | **cap-load — live-slice branch** | `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:44-52` (`load/1`) | domain | PR-1 | per-holder source hygiene → `[]` |
| 2 | **cap-load — durable branch** | `entity_caps.ex:56-67` (`load_persisted/1`) | domain | PR-1 | per-holder source hygiene → `[]` |
| 3 | **authentication (PAT → principal)** | `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:192-205` (`enabled_principal/1`, agent `else` branch 200-202) | domain | PR-2 | reject credential |
| 4 | **authz decision — inline caps** | `apps/ezagent_core/lib/ezagent/cap/verifier.ex:81` (the unified `authorize/3` target) | **core** | PR-6 | per-holder use gate (rides epoch authorize/3) |
| 5 | **spawn/activate Lifecycle fence** | `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:258` (`refute_tombstoned_entity!/1`) | domain | PR-5 (already agent-aware; make durable) | refuse start/rehydrate |
| 6 | **core spawn fence (no-Identity + already-running paths)** | `apps/ezagent_core/lib/ezagent/spawn_fence.ex` + `Kind.Server.init`/`SpawnRegistry` | core (registry) | PR-5 (make EtsOwner-restart durable) | refuse start/return |
| 7 | **commit-time absorb/recipient guard** | `identity.ex:618` (`refute_tombstoned_recipient/1`, user-only at :621) | domain | PR-5 (make agent-aware) | refuse post-tombstone slice commit |

Chokepoints 1–3 + 5–7 are DOMAIN and epoch-independent; chokepoint 4 is CORE and rides the unified `authorize/3`.

---

## Design forks needing codex / Allen sign-off

1. **Atomicity boundary redefinition** (above) — Allen chose the re-design; codex must confirm the split (durable-invalidation = atomicity boundary; teardown = best-effort cleanup) closes F4 without reopening it. This is THE contract-level decision the held branch was parked for.
2. **F1 fence durability mechanism** (PR-5) — two sub-parts; pin both:
   - (a) domain-side guards (chokepoints 5 & 7) call `tombstoned_principal?` **directly** = the durable backstop independent of the core ETS registry;
   - (b) the core registry (chokepoint 6, needed for the no-Identity-behavior + already-running-return paths) needs a concrete **re-registration-on-EtsOwner-restart** mechanism. **Recommended:** a tiny `Ezagent.Identity.SpawnFenceRegistrar` GenServer under the `ezagent_domain_identity` supervision tree that monitors the `:ezagent_spawn_fence` ETS table (`:ets.whereis` poll or the EtsOwner monitor) and re-registers `Offboarding.refute_tombstoned/1` whenever the table reappears empty. **Alternative:** `EzagentCore.EtsOwner` invokes registered init-callbacks after (re)creating tables. Codex to rule on (a)+(b) vs a single mechanism.
3. **Hot-path cost** (PR-9, non-blocking) — `tombstoned_principal?` does DB reads + a depth-100 lineage walk on the cap-load / authenticate / authz hot path. Flag to Allen whether to ship the per-principal ETS hot-cache in this program or defer to the shared epoch cache work.

---

## File Structure

**Modified (on #1469 base):**
- `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex` — cap-load tombstone gate (PR-1).
- `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex` — authenticate tombstone gate (PR-2).
- `apps/ezagent_core/lib/ezagent/kind.ex` — honest `terminate/1` return + `terminate!/1` coercing wrapper (PR-3).
- `apps/ezagent_core/lib/ezagent/lifecycle.ex` — `destroy/2` captures + branches on honest terminate; `destroy!/2` coercing wrapper (PR-3).
- `apps/ezagent_domain_identity/lib/ezagent/identity/offboarding.ex` — `teardown_and_reap/1` verifies no-live-process + branches; `tombstone_agent/3` routes teardown failure to cleanup (PR-4).
- `apps/ezagent_domain_identity/lib/ezagent/users.ex` — `tombstone/3` atomicity split: teardown failure → cleanup-retry, not `delete_user` failure (PR-4).
- `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex` — `refute_tombstoned_recipient/1` agent-aware (PR-5).
- `apps/ezagent_core/lib/ezagent/cap/verifier.ex` (or the unified `authorize/3` if landed) — holder-tombstone predicate for inline caps (PR-6).

**Created:**
- `apps/ezagent_domain_identity/lib/ezagent/identity/spawn_fence_registrar.ex` — EtsOwner-restart re-registration (PR-5, if (b) chosen).
- `apps/ezagent_domain_identity/lib/ezagent/identity/reap_queue.ex` — best-effort cleanup retry queue for failed teardowns (PR-4).
- Test files listed per-task.

---

## PR / Phase plan (8 PRs + 1 optional)

Order = correctness kernel first (PR-1, PR-2), then honesty/atomicity (PR-3, PR-4), then fence (PR-5), then inline-cap defense (PR-6), then the enumerator GATE (PR-7), then the runtime completeness proof (PR-8). PR-9 is an optional hot-path follow-up.

---

### PR-1: cap-load tombstone gate — the KEY gap (primary kill)

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex:44-67` (`load/1`, `load_persisted/1`)
- Test: `apps/ezagent_domain_identity/test/ezagent/entity_caps_tombstone_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.Identity.Offboarding.tombstoned_principal?/1` (from #1469 — transitive user/agent/creator/lineage predicate).
- Produces: `Ezagent.EntityCaps.load/1` and `load_persisted/1` return `[]` for any URI where `tombstoned_principal?/1` is true (a tombstoned agent, or an agent owned-by / in-lineage-of a tombstoned user), regardless of live-slice contents.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/ezagent_domain_identity/test/ezagent/entity_caps_tombstone_test.exs
defmodule Ezagent.EntityCapsTombstoneTest do
  use Ezagent.DataCase, async: false
  alias Ezagent.{EntityCaps, Users}

  @admin "entity://sys/user/genesis-admin"

  setup do
    ws = "workspace://team-x"
    user = Ezagent.URI.new!("entity://team-x/user/owner-1")
    {:ok, _} = Users.create(user, "pw", MapSet.new())
    {:ok, _} = Users.disable(user, @admin, "offboarding")
    # Spawn an agent OWNED by user (creator_uri == user), with a live cap in its :identity slice.
    agent = TestSupport.spawn_owned_agent!(owner: user, workspace: ws, caps: [TestSupport.signed_cap_to(agent_placeholder())])
    %{user: user, agent: agent}
  end

  test "a tombstoned agent's LIVE slice caps are NOT served (owner deleted)", %{user: user, agent: agent} do
    # Precondition: the live agent has caps before tombstone.
    assert EntityCaps.load(agent) != []
    # Tombstone the owning user (its own marker commits atomically).
    {:ok, _} = Users.tombstone(user, @admin, "gone")
    # KERNEL: even though the agent process is still live and its :identity slice
    # still holds the cap, cap-load must serve [] because its owner is tombstoned.
    assert EntityCaps.load(agent) == []
    assert EntityCaps.load_persisted(agent) == []
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/entity_caps_tombstone_test.exs`
Expected: FAIL — `load/1` returns the stale cap (the live-slice branch `entity_caps.ex:47-48` serves cached caps with no tombstone re-check). This reproduces codex F4's cap-loading gap (`entity_caps.ex:42` "explicitly prefers that live slice").

- [ ] **Step 3: Write minimal implementation**

Add a tombstone short-circuit at the top of both public readers (same-app call to `Offboarding` — no tier violation). Reuse the `DBConnection.OwnershipError` sandbox rescue pattern from `Offboarding.refute_tombstoned/1`.

```elixir
# entity_caps.ex — replace load/1 and load_persisted/1 heads:
def load(uri) do
  uri = parse_uri(uri)
  if tombstoned?(uri), do: [], else: do_load(uri)
end

defp do_load(uri) do
  case Kind.get_slice(uri, :identity) do
    {:ok, slice} when is_map(slice) -> slice |> caps_from_slice() |> verified(uri)
    {:error, :not_found} -> load_persisted(uri)
    _transient_or_invalid_live_read -> []
  end
end

def load_persisted(uri) do
  uri = parse_uri(uri)
  if tombstoned?(uri), do: [], else: do_load_persisted(uri)
end

defp do_load_persisted(uri) do
  caps = if user_uri?(uri), do: UserStore.load(uri), else: snapshot_caps(uri)
  verified(caps, uri)
end

# Fail-closed source hygiene: a tombstoned holder holds NO usable authority.
# Absence-of-connection in the test sandbox is NOT a tombstone signal (mirror
# Offboarding.refute_tombstoned/1) — admit the read there; every production path
# and every DataCase test runs the check with DB access.
# NOTE: use the do…end form on the reading clause so `rescue` actually guards
# the DB read (a `do:` shorthand cannot carry `rescue`).
defp tombstoned?(%URI{scheme: "entity"} = uri) do
  Ezagent.Identity.Offboarding.tombstoned_principal?(uri)
rescue
  DBConnection.OwnershipError -> false
end

defp tombstoned?(_), do: false
```

(Put the `rescue` on the private `tombstoned?/1` reading clause, not on `load/1`, so a genuine DB error still surfaces where intended. Match the exact `rescue`/`catch` structure `Offboarding.refute_tombstoned/1` uses.)

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/entity_caps_tombstone_test.exs`
Expected: PASS.

- [ ] **Step 5: Run the identity cap suites to confirm no regression**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test`
Expected: PASS (no live user/agent that ISN'T tombstoned changes behavior — `tombstoned_principal?` returns false for them).

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_identity/lib/ezagent/entity_caps.ex apps/ezagent_domain_identity/test/ezagent/entity_caps_tombstone_test.exs
git commit -m "feat(offboarding): cap-load fail-closes on tombstoned holder (invalidation core, F4 cap-load gap)

The primary kill: a tombstoned agent (or owned/lineage-of a tombstoned user)
serves [] caps regardless of live-slice contents. Dispatch/authz source caps
via EntityCaps.load, so this denies at every downstream verifier.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-2: authentication tombstone gate — reject tombstoned-principal PATs

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/entity/token.ex:192-205` (`enabled_principal/1`)
- Test: `apps/ezagent_domain_identity/test/ezagent/entity/token_tombstone_test.exs` (create)

**Interfaces:**
- Consumes: `Ezagent.Identity.Offboarding.tombstoned_principal?/1`.
- Produces: `Token.authenticate/1` returns `{:error, :invalid_credentials}` (the outer catch-all) when the PAT's principal is a tombstoned agent OR an agent owned-by/in-lineage-of a tombstoned user; user principals keep the existing `disabled_at`/`deleted_at` gate.

- [ ] **Step 1: Write the failing test**

```elixir
# token_tombstone_test.exs
defmodule Ezagent.Entity.TokenTombstoneTest do
  use Ezagent.DataCase, async: false
  alias Ezagent.{Users, Entity}
  alias Ezagent.Entity.Token

  @admin "entity://sys/user/genesis-admin"

  test "a PAT for an agent whose owner was deleted no longer authenticates" do
    user = Ezagent.URI.new!("entity://team-x/user/owner-2")
    {:ok, _} = Users.create(user, "pw", MapSet.new())
    {:ok, _} = Users.disable(user, @admin, "offboarding")
    agent = TestSupport.spawn_owned_agent!(owner: user, workspace: "workspace://team-x")
    {plain, _row} = Token.mint(agent, label: "cli")

    assert {:ok, ^agent} = Token.authenticate(plain)      # live before tombstone
    {:ok, _} = Users.tombstone(user, @admin, "gone")
    assert {:error, :invalid_credentials} = Token.authenticate(plain)  # KERNEL: inert
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/entity/token_tombstone_test.exs`
Expected: FAIL — `enabled_principal/1`'s agent `else` branch (`token.ex:200-202`) returns `{:ok, principal}` unconditionally, so the PAT still authenticates.

- [ ] **Step 3: Write minimal implementation**

```elixir
# token.ex — enabled_principal/1
defp enabled_principal(entity_uri) do
  principal = Ezagent.URI.new!(entity_uri)

  cond do
    Ezagent.URI.type?(principal, :user) ->
      case Ezagent.Users.get_by_uri(entity_uri) do
        %{disabled_at: %DateTime{}} -> {:error, :disabled}
        _ -> {:ok, principal}
      end

    # task #180 re-design: an agent principal is rejected when it (or its
    # owner / lineage ancestor) is tombstoned — the same transitive predicate
    # the fence and cap-load use, so a tombstoned agent cannot re-establish
    # a session even if its Kind process is still alive.
    Ezagent.Identity.Offboarding.tombstoned_principal?(principal) ->
      {:error, :disabled}

    true ->
      {:ok, principal}
  end
rescue
  ArgumentError -> {:error, :invalid_credentials}
end
```

(`{:error, :disabled}` is coerced by `authenticate/1`'s outer `else` to `{:error, :invalid_credentials}` — don't leak the tombstone state to an unauthenticated caller.)

- [ ] **Step 4: Run test to verify it passes**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/entity/token_tombstone_test.exs`
Expected: PASS.

- [ ] **Step 5: Run token suite**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/entity/token_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_identity/lib/ezagent/entity/token.ex apps/ezagent_domain_identity/test/ezagent/entity/token_tombstone_test.exs
git commit -m "feat(offboarding): PAT authenticate fail-closes on tombstoned agent principal

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-3: honest `Kind.terminate` return + `Lifecycle.destroy` branches + coercing wrappers

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/kind.ex:524-566` (`terminate/1`)
- Modify: `apps/ezagent_core/lib/ezagent/lifecycle.ex:686-820` (`destroy/2`, `do_destroy/2`, `run_developer_destroy_hooks/2`)
- Test: `apps/ezagent_core/test/ezagent/kind_terminate_honest_test.exs`, `apps/ezagent_core/test/ezagent/lifecycle_destroy_honest_test.exs` (create)

**Interfaces:**
- Produces:
  - `Ezagent.Kind.terminate/1 :: :ok | {:error, :timeout | :still_alive | term()}` — `:ok` ONLY on confirmed teardown (process dead); `{:error, _}` on timeout/exit/liveness-after-fallback. BEHAVIOR unchanged (still best-effort, non-blocking beyond the existing supervisor call).
  - `Ezagent.Kind.terminate!/1 :: :ok` — thin `:ok`-coercing wrapper for don't-care callers (GC, restart, test cleanup) so those sites stay byte-equivalent.
  - `Ezagent.Lifecycle.destroy/2 :: :ok | {:error, term()}` — now propagates the honest terminate result AND the hook-drain result; still returns `{:error, :cannot_self_destroy}` for the self-target guard.
  - `Ezagent.Lifecycle.destroy!/2 :: :ok` — `:ok`-coercing wrapper for don't-care callers.

- [ ] **Step 1: PARITY AUDIT — enumerate every caller (do this first; it sizes the wrappers)**

Run and record the full list; classify each as CARE (must observe failure) vs DON'T-CARE (GC/restart/test → route through `terminate!`/`destroy!`):

```bash
git grep -n "Kind.terminate(" -- 'apps/**/*.ex' | grep -v test
git grep -n "Lifecycle.destroy(" -- 'apps/**/*.ex' | grep -v test
```

Expected CARE sites: `Offboarding.teardown_and_reap/1` (the ONLY site that must branch — PR-4). Everything else (GC, restart, developer teardown, ExternalMirror) is DON'T-CARE → `terminate!`/`destroy!`. Record the classification in the commit body as the proof of "byte-unchanged at don't-care sites."

- [ ] **Step 2: Write the failing test (honest terminate)**

```elixir
# kind_terminate_honest_test.exs
test "terminate/1 returns {:error, :timeout} when the Kind's supervisor teardown times out" do
  {:ok, uri, _pid} = TestSupport.spawn_busy_kind!(block_terminate_ms: 30_000)
  assert {:error, reason} = Ezagent.Kind.terminate(uri)
  assert reason in [:timeout, :still_alive]
  # BEHAVIOR still non-blocking: the call returned promptly, it did not hang 30s.
end

test "terminate!/1 coerces the same case to :ok (don't-care wrapper)" do
  {:ok, uri, _pid} = TestSupport.spawn_busy_kind!(block_terminate_ms: 30_000)
  assert :ok = Ezagent.Kind.terminate!(uri)
end

test "terminate/1 returns :ok on a confirmed teardown" do
  {:ok, uri, _pid} = TestSupport.spawn_kind!()
  assert :ok = Ezagent.Kind.terminate(uri)
  assert :error = Ezagent.KindRegistry.lookup(uri)  # actually gone
end
```

- [ ] **Step 3: Run to verify it fails**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind_terminate_honest_test.exs`
Expected: FAIL — current `terminate/1` (`kind.ex:524`, `@spec :: :ok`) coerces every path to `:ok` at lines 535/542-543/556-557/560/563/565.

- [ ] **Step 4: Make `terminate/1` honest + add `terminate!/1`**

```elixir
@spec terminate(URI.t()) :: :ok | {:error, term()}
def terminate(%URI{} = uri) do
  :ok = Ezagent.Kind.ReadyTransition.mark_failed(uri)

  with {:ok, pid} <- Ezagent.KindRegistry.lookup(uri),
       {:ok, kind_module} <- safe_kind_module(pid) do
    case terminate_strategy(kind_module) do
      :standard ->
        supervisor = resolve_supervisor(kind_module)
        case DynamicSupervisor.terminate_child(supervisor, pid) do
          :ok -> :ok                                   # confirmed dead
          {:error, :not_found} -> exit_and_verify(pid) # fallback: prove death
        end

      {:custom, mod, fun} when is_atom(mod) and is_atom(fun) ->
        _ = apply(mod, fun, [uri, pid])
        verify_dead(pid)                               # honest: did custom teardown work?
    end
  else
    :error -> :ok                                      # genuinely absent — idempotent
    {:error, _} = e -> e
  end
rescue
  error -> {:error, {:terminate_crashed, error}}
catch
  :exit, reason -> {:error, {:terminate_exit, reason}}
end

# Non-blocking liveness check: Process.exit is async, so give a SHORT bounded
# grace (not the old unbounded 5s hook wait) then report honestly.
defp exit_and_verify(pid) do
  _ = Process.exit(pid, :shutdown)
  verify_dead(pid)
end

defp verify_dead(pid) do
  if wait_dead(pid, Application.get_env(:ezagent_core, :terminate_verify_ms, 200)),
    do: :ok, else: {:error, :still_alive}
end

defp wait_dead(pid, budget_ms) do
  ref = Process.monitor(pid)
  receive do
    {:DOWN, ^ref, :process, ^pid, _} -> true
  after
    budget_ms -> Process.demonitor(ref, [:flush]); not Process.alive?(pid)
  end
end

@doc "Best-effort teardown for don't-care callers (GC/restart/test cleanup) — always :ok."
@spec terminate!(URI.t()) :: :ok
def terminate!(%URI{} = uri) do
  _ = terminate(uri)
  :ok
end
```

Note: `safe_kind_module/1` (`kind.ex:664`) currently `catch _,_ -> :ok`-coerces its `GenServer.call(pid, :ezagent_kind_module, 5_000)`. Change it to surface `{:error, :module_query_timeout}` so a busy Kind that can't answer is honestly a terminate failure, not a silent success. Route it into the `{:error, _} = e -> e` branch above.

**Latency note (avoid a hidden behavior change for don't-care callers):** on the STANDARD path `DynamicSupervisor.terminate_child` already blocks-until-dead, so `:ok` is honest with NO added latency. The `verify_dead` `receive` grace applies ONLY to the fallback (`Process.exit`) and custom-teardown paths. Since `terminate!/1` (GC/restart/cleanup) inherits it, default `:terminate_verify_ms` to a small value AND make it `0`-able (a `0` budget = a single `Process.alive?/1` poll after `demonitor`, no wait) so don't-care callers do not silently start paying a grace they never did. State this in the moduledoc so codex does not read it as a behavior change.

- [ ] **Step 5: Update DON'T-CARE `terminate` callers to `terminate!`**

For every DON'T-CARE site from Step 1, replace `Kind.terminate(` with `Kind.terminate!(`. Verify with `git diff` that behavior is byte-equivalent (both discard non-`:ok`).

- [ ] **Step 6: Make `Lifecycle.destroy/2` capture + branch on the honest result**

```elixir
# do_destroy/2 (lifecycle.ex:747) — capture terminate's honest result and the
# hook-drain result instead of discarding them.
defp do_destroy(uri, reason) do
  uri_str = Ezagent.URI.stable_key(uri)

  with :ok <- run_developer_destroy_hooks(uri_str, reason),
       :ok <- terminate_live(uri_str) do
    :ok = Ezagent.Ecto.KindSnapshot.delete(uri_str)   # clear durable state only after a CONFIRMED teardown
    :ok
  end
end

defp terminate_live(uri_str) do
  case Ezagent.KindRegistry.lookup(uri_str) do
    {:ok, _pid} -> Ezagent.Kind.terminate(Ezagent.URI.new!(uri_str))  # honest now
    :error -> :ok
  end
end
```

And `run_developer_destroy_hooks/2` (`lifecycle.ex:809`): change the busy-Kind coercion `catch :exit, _ -> :ok` at line 818 to surface `{:error, :destroy_hook_timeout}`. Keep the `{:error, :cannot_self_destroy}` guard as-is (that is a correct fail-loud, not a timeout). Add `destroy!/2` that `:ok`-coerces, and route the DON'T-CARE `Lifecycle.destroy` callers from Step 1 to it.

**Important nuance:** if terminate fails, do NOT delete the snapshot row (`with` short-circuits before `KindSnapshot.delete`). This keeps the durable state consistent with "the process is still alive" — the reaper (PR-4) retries. This is safe because invalidation (PR-1) already made the still-alive agent inert.

- [ ] **Step 7: Run tests**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_core/test/ezagent/kind_terminate_honest_test.exs apps/ezagent_core/test/ezagent/lifecycle_destroy_honest_test.exs`
Then the core lifecycle/kind suites: `mix test apps/ezagent_core/test/ezagent/lifecycle_test.exs apps/ezagent_core/test/ezagent/kind_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/kind.ex apps/ezagent_core/lib/ezagent/lifecycle.ex apps/ezagent_core/test/ezagent/kind_terminate_honest_test.exs apps/ezagent_core/test/ezagent/lifecycle_destroy_honest_test.exs
git commit -m "feat(core): honest Kind.terminate/Lifecycle.destroy return + :ok-coercing wrappers

terminate/1 and destroy/2 now return {:error, :timeout|:still_alive} on failure;
terminate!/destroy! keep don't-care callers (GC/restart/cleanup) byte-unchanged.
Behavior stays best-effort/non-blocking; only the RETURN becomes honest so
offboarding can branch (F4 root: was always-:ok).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-4: atomicity boundary redefinition + honest teardown_and_reap + cleanup reaper (THE headline)

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/identity/offboarding.ex` (`teardown_and_reap/1`, `tombstone_agent/3`)
- Modify: `apps/ezagent_domain_identity/lib/ezagent/users.ex` (`tombstone/3` post-commit branch, `cascade_owned_agents/3`)
- Create: `apps/ezagent_domain_identity/lib/ezagent/identity/reap_queue.ex`
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/delete_user_busy_timeout_test.exs` (create — the test that killed the old design)

**Interfaces:**
- Consumes: honest `Lifecycle.destroy/2` (PR-3), `EntityCaps.load` fail-closed (PR-1), `Token.authenticate` fail-closed (PR-2).
- Produces:
  - `teardown_and_reap/1 :: :ok | {:error, {:teardown_incomplete, uri, reason}}` — `:ok` ONLY when the KindRegistry no longer holds a live process AND the snapshot row is gone; `{:error, _}` otherwise (a live process is now a real error, not "row absent → :ok").
  - `Users.tombstone/3` — a teardown failure NO LONGER flips `delete_user` to failure. It enqueues the URI on the reap queue and returns `{:ok, decoded}` **because the durable-invalidation commit (marker + caps-clear + outbox) succeeded and the principal is inert.** Only a durable-invalidation-commit failure yields a retryable non-success.
  - `Ezagent.Identity.ReapQueue.enqueue/1` + a periodic `sweep/0` that retries `teardown_and_reap` for still-live tombstoned principals.

- [ ] **Step 1: Write the headline failing test (the terminate-timeout path, NOT self-destroy)**

The held atomicity test (`offboarding_atomicity_test.exs:31-53`) only simulates `:cannot_self_destroy` — codex explicitly noted that misses the real "terminate times out → :ok" path. This test injects a genuinely busy Kind whose terminate times out.

```elixir
# delete_user_busy_timeout_test.exs
defmodule Ezagent.Identity.DeleteUserBusyTimeoutTest do
  use Ezagent.DataCase, async: false
  alias Ezagent.{Users, EntityCaps}
  alias Ezagent.Entity.Token

  @admin "entity://sys/user/genesis-admin"

  test "a busy owned-agent whose terminate TIMES OUT is STILL fully revoked, and delete_user succeeds" do
    user = Ezagent.URI.new!("entity://team-x/user/owner-3")
    {:ok, _} = Users.create(user, "pw", MapSet.new())
    {:ok, _} = Users.disable(user, @admin, "offboarding")

    # Owned agent, occupied so its Lifecycle destroy hook / terminate cannot complete in-budget.
    agent = TestSupport.spawn_owned_agent!(owner: user, workspace: "workspace://team-x",
             caps: [TestSupport.signed_cap()], block_terminate_ms: 30_000)
    {plain, _} = Token.mint(agent, label: "cli")
    assert EntityCaps.load(agent) != [] and {:ok, ^agent} = Token.authenticate(plain)

    # delete_user SUCCEEDS despite the un-killable process (prove-inert, not prove-dead).
    assert {:ok, _decoded} = Users.tombstone(user, @admin, "gone")

    # Full revocation holds REGARDLESS of the still-alive process:
    assert Process.alive?(TestSupport.pid_of(agent))         # it really is still up
    assert EntityCaps.load(agent) == []                       # cannot load/use caps
    assert {:error, :invalid_credentials} = Token.authenticate(plain)  # cannot authenticate
    assert {:error, _} = TestSupport.dispatch_as(agent, some_action())  # cannot dispatch

    # And it is queued for best-effort cleanup (observable, retryable).
    assert agent in Ezagent.Identity.ReapQueue.pending()
  end

  test "a DURABLE-INVALIDATION commit failure (caps-clear) DOES yield a retryable non-success" do
    user = Ezagent.URI.new!("entity://team-x/user/owner-4")
    {:ok, _} = Users.create(user, "pw", MapSet.new())
    {:ok, _} = Users.disable(user, @admin, "offboarding")
    TestSupport.inject_caps_clear_failure(user)   # UserStore.persist([]) fails

    assert {:error, {:caps_clear_failed, _}} = Users.tombstone(user, @admin, "gone")
    refute Users.deleted?(user)                    # atomic: marker rolled back with the caps-clear
    TestSupport.clear_injection()
    assert {:ok, _} = Users.tombstone(user, @admin, "gone")   # retry converges
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/identity/delete_user_busy_timeout_test.exs`
Expected: FAIL on the first test — with PR-1/2/3 present but PR-4 absent, the held `teardown_and_reap` returns `{:error, {:agent_teardown_failed, …}}` (now that terminate is honest) and `Users.tombstone/3` propagates it as a hard failure → `delete_user` returns `{:error, _}` instead of `{:ok, _}`. (Before PR-3 it would have falsely returned `{:ok,_}` via the snapshot-only reaper — the codex F4 bug.) Either way the assertion `{:ok, _decoded}` fails, proving the atomicity boundary is mis-drawn.

- [ ] **Step 3: Redraw the boundary in `teardown_and_reap/1` (honest, but non-fatal)**

```elixir
# offboarding.ex
@spec teardown_and_reap(URI.t()) :: :ok | {:error, {:teardown_incomplete, URI.t(), term()}}
def teardown_and_reap(%URI{} = uri) do
  case destroy_kind(uri) do            # honest Lifecycle.destroy now
    :ok ->
      # Verify BOTH the process is gone AND the snapshot row is gone (F4: the
      # old code checked only the row). A live process => incomplete.
      cond do
        live_process?(uri) -> {:error, {:teardown_incomplete, uri, :still_alive}}
        residual_snapshot?(uri) -> reap_residual_snapshot(uri)
        true -> :ok
      end

    {:error, reason} ->
      {:error, {:teardown_incomplete, uri, reason}}
  end
end

defp live_process?(uri) do
  match?({:ok, _pid}, Ezagent.KindRegistry.lookup(uri))
end
```

- [ ] **Step 4: Redraw the boundary in `Users.tombstone/3` — teardown failure → reap-queue, not delete_user failure**

In BOTH the fresh-tombstone post-commit branch (`users.ex` after `{:ok, :ok} ->`) and the idempotent-retry branch, replace the hard `with :ok <- teardown_and_reap(...) ...` gate so a teardown/cascade-teardown failure is captured as a cleanup task, not a `delete_user` failure:

```elixir
# users.ex — post-commit branch (marker + caps-clear + outbox ALREADY committed atomically above)
case txn do
  {:ok, :ok} ->
    # Durable invalidation is committed → the user and every derived agent are
    # INERT (Offboarding.tombstoned_principal? walks to this marker). Teardown is
    # now best-effort CLEANUP: a failure enqueues a reap-retry but does NOT flip
    # delete_user to failure (the busy-timeout agent is already revoked).
    _ = best_effort_reap(row_uri)
    _ = cascade_owned_agents_best_effort(row_uri, by, normalized_reason)
    {:ok, decode(Repo.get_by(__MODULE__, uri: row.uri))}

  {:error, reason} ->
    {:error, reason}   # durable-invalidation commit failed → retryable non-success (unchanged)
end

defp best_effort_reap(uri) do
  case Ezagent.Identity.Offboarding.teardown_and_reap(uri) do
    :ok -> :ok
    {:error, _} = e -> Ezagent.Identity.ReapQueue.enqueue(uri); e
  end
end
```

**Only U's OWN durable-invalidation commit is fatal.** Per the kernel, a derived agent is inert the instant U's marker commits — `tombstoned_principal?` walks to the deleted owner with ZERO dependency on the agent's own marker, token-revoke, or authority-retire. So making a per-agent step fatal to `delete_user` would reintroduce the very false-convergence we are eliminating: `delete_user(U)` must NOT return `{:error}` because one already-inert derived agent's `revoke_all_for_entity` DB write hiccuped. Therefore `cascade_owned_agents_best_effort/3` treats the ENTIRE per-agent tombstone — BOTH the marker/token/authority txn AND `teardown_and_reap` — as best-effort → reap-queue → retry-to-convergence. The per-agent marker's real job is the **lost-linkage backstop** (the edge where an agent's creator read AND lineage row are both gone, so the owner-walk can't reach it) — that is convergent cleanup, not an atomicity boundary. The enumeration sweep runs to completion (never halts mid-sweep on a per-agent failure); any per-agent failure enqueues that agent for reap-retry, and `delete_user` still returns `{:ok, _}` (U's own commit stood → every derived agent is already inert). The reap-queue sweep re-runs `cascade_owned_agents` idempotently until it converges.

- [ ] **Step 5: Create the reap queue**

```elixir
# reap_queue.ex — durable-enough best-effort retry of teardown for still-live tombstoned principals.
defmodule Ezagent.Identity.ReapQueue do
  @moduledoc "Best-effort cleanup of tombstoned-but-still-live Kinds. Correctness does NOT depend on this — invalidation already made them inert; this only reclaims the process/snapshot."
  use GenServer
  # enqueue/1, pending/0, sweep/0 (periodic Process.send_after); sweep re-runs
  # Offboarding.teardown_and_reap/1 per pending uri, dropping on :ok. Idempotent.
end
```

Register it under the `ezagent_domain_identity` supervision tree. Back the pending set with a small durable table (or reuse `agent_tombstones` + a `reaped_at` column) so a node restart re-derives the worklist as "tombstoned AND still snapshot-present." (The durable derivation is preferable to an in-memory queue — a crash between enqueue and sweep must not orphan a live process; but since invalidation holds regardless, an in-memory queue is acceptable for v1 with the durable derivation as a fast-follow.)

- [ ] **Step 6: Run the headline test + the held atomicity suite**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/identity/delete_user_busy_timeout_test.exs apps/ezagent_domain_identity/test/ezagent/identity/offboarding_atomicity_test.exs`
Expected: PASS. The held atomicity test's `:cannot_self_destroy` cases still pass (a self-destroy is a caller bug, not a teardown timeout — keep it fatal OR reclassify per codex; note the distinction explicitly). The two new busy-timeout cases pass.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_domain_identity/lib/ezagent/identity/offboarding.ex apps/ezagent_domain_identity/lib/ezagent/users.ex apps/ezagent_domain_identity/lib/ezagent/identity/reap_queue.ex apps/ezagent_domain_identity/test/ezagent/identity/delete_user_busy_timeout_test.exs
git commit -m "feat(offboarding): redraw atomicity boundary — durable-invalidation commit is the gate, teardown is best-effort cleanup (closes F4 false-success)

A busy owned-agent whose terminate times out is STILL fully revoked (inert via
the tombstone predicate at cap-load/authenticate/authz) and delete_user succeeds;
the un-killable process is enqueued for reap. Only a caps-clear/marker/outbox
commit failure yields a retryable non-success. Adds the terminate-timeout
reproducing test codex required.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-5: close F1 — agent-aware commit guard + EtsOwner-restart-durable fence

**Files:**
- Modify: `apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex:618-624` (`refute_tombstoned_recipient/1`)
- Create: `apps/ezagent_domain_identity/lib/ezagent/identity/spawn_fence_registrar.ex` (mechanism (b))
- Test: `apps/ezagent_domain_identity/test/ezagent/identity/spawn_fence_durability_test.exs`, extend `apps/ezagent_domain_identity/test/ezagent/behavior/identity_commit_guard_test.exs`

**Interfaces:**
- Consumes: `Offboarding.tombstoned_principal?/1`, `Ezagent.SpawnFence.{register,check}/*`, `EzagentCore.EtsOwner`.
- Produces:
  - `refute_tombstoned_recipient/1` refuses a commit whose recipient is a tombstoned AGENT (not only a deleted user).
  - `Ezagent.Identity.SpawnFenceRegistrar` re-registers `Offboarding.refute_tombstoned/1` after an `EtsOwner` restart empties `:ezagent_spawn_fence`, so `SpawnFence.check/1` is never silently empty for a tombstoned principal.

- [ ] **Step 1: Write the failing test (commit guard, agent arm)**

```elixir
test "a slice-commit whose recipient is a tombstoned AGENT is refused (F1 residual: guard was user-only)" do
  {user, agent} = TestSupport.owned_agent_deleted!()   # user tombstoned, agent derived
  # A cap-delivery claimed pre-tombstone attempts to commit post-tombstone.
  ctx = TestSupport.absorb_ctx(recipient: agent)
  assert {:error, {:principal_tombstoned, _}} = TestSupport.commit_absorb(ctx)
end
```

- [ ] **Step 2: Write the failing test (fence durability across EtsOwner restart)**

```elixir
test "SpawnFence refuses a tombstoned principal even after EtsOwner recreates the table empty" do
  {user, agent} = TestSupport.owned_agent_deleted!()
  assert {:error, {:principal_tombstoned, _}} = Ezagent.SpawnFence.check(agent)

  TestSupport.restart_ets_owner!()        # recreates :ezagent_spawn_fence EMPTY
  TestSupport.await_registrar_reregister()
  # Without the registrar this is :ok (empty registry = fail-open) — the F1 hole.
  assert {:error, {:principal_tombstoned, _}} = Ezagent.SpawnFence.check(agent)
end
```

- [ ] **Step 3: Run to verify both fail**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/identity/spawn_fence_durability_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/identity_commit_guard_test.exs`
Expected: FAIL — the commit guard (`identity.ex:621`) checks only `Ezagent.URI.type?(uri, :user) and Ezagent.Users.deleted?(uri)`; and after `restart_ets_owner!`, `SpawnFence.check/1` returns `:ok` (the moduledoc's admitted "recreates it EMPTY … re-registers on ITS restart" trade-off).

- [ ] **Step 4: Make the commit guard agent-aware (durable backstop, part (a))**

```elixir
# identity.ex — refute_tombstoned_recipient/1
defp refute_tombstoned_recipient(ctx) do
  uri = recipient_uri(ctx)
  # Call the durable transitive predicate DIRECTLY (not via the core in-memory
  # SpawnFence registry, which an EtsOwner restart can empty). This makes the
  # domain-side guard independent of registry liveness — the F1 durability
  # backstop — and agent-aware (was user-only).
  if is_struct(uri, URI) and Ezagent.Identity.Offboarding.tombstoned_principal?(uri) do
    {:error, {:principal_tombstoned, Ezagent.URI.instance(uri)}}
  else
    :ok
  end
end
```

Apply the same directness to the Lifecycle create/activate fence `refute_tombstoned_entity!/1` (`identity.ex:258`) — it already calls `agent_tombstoned_or_derived?` → `Offboarding.tombstoned_principal?`, so it is already the durable backstop; just confirm it does not route through `SpawnFence.check`.

- [ ] **Step 5: Add the registrar (core-registry durability, part (b))**

```elixir
# spawn_fence_registrar.ex
defmodule Ezagent.Identity.SpawnFenceRegistrar do
  @moduledoc "Keeps Offboarding.refute_tombstoned/1 registered in the core SpawnFence across EtsOwner restarts (which recreate :ezagent_spawn_fence empty). The domain-side guards are the primary backstop; this keeps the core no-Identity/already-running chokepoints honest too."
  use GenServer
  # On init and on a periodic tick (or an EtsOwner :DOWN monitor), if the table
  # exists and lacks our predicate, re-register it. Idempotent.
end
```

Register under `ezagent_domain_identity`'s supervision tree, AFTER the app's normal boot registration. (If codex prefers mechanism-alternative EtsOwner-init-callbacks, implement that instead — pin ONE, per the design fork.)

- [ ] **Step 6: Run the tests**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/identity/spawn_fence_durability_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/identity_commit_guard_test.exs apps/ezagent_core/test/ezagent/spawn_fence_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex apps/ezagent_domain_identity/lib/ezagent/identity/spawn_fence_registrar.ex apps/ezagent_domain_identity/test/ezagent/identity/spawn_fence_durability_test.exs apps/ezagent_domain_identity/test/ezagent/behavior/identity_commit_guard_test.exs
git commit -m "feat(offboarding): close F1 — agent-aware commit guard + EtsOwner-restart-durable spawn fence

commit-time recipient guard now refuses tombstoned AGENTS (was user-only) via
the durable predicate directly; SpawnFenceRegistrar re-registers refute_tombstoned
after an EtsOwner restart so the core fence is never silently empty.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-6: authz-decision holder-check for INLINE caps — rides the unified `authorize/3`

**Files:**
- Modify: `apps/ezagent_core/lib/ezagent/cap/verifier.ex` (or the unified `authorize/3` module if it has landed by now)
- Create: `apps/ezagent_core/lib/ezagent/principal_fence.ex` (core registry, if `authorize/3` not yet unified) — OR add the predicate to the unified verifier's predicate list.
- Test: `apps/ezagent_core/test/ezagent/authz_holder_tombstone_test.exs`

**Interfaces:**
- Consumes: a core-tier registry of holder predicates (the `SpawnFence` pattern), into which `ezagent_domain_identity` registers `Offboarding.tombstoned_principal?/1` at boot; OR the unified `authorize/3` predicate hook.
- Produces: the authz decision denies when the HOLDER (caller/`holder_uri`) is tombstoned, even for caps presented INLINE in `ctx.caps` that never passed through `EntityCaps.load` (the one path PR-1 cannot cover).

**COORDINATION (mandatory — read "Architectural convergence" above):**
- If the epoch/cap-signing "unify `authorize/3`" has landed → add `holder_not_tombstoned?(holder_uri)` as a predicate INSIDE that single verifier, next to epoch's per-cap gen check. Do NOT create `principal_fence.ex`. One chokepoint.
- If it has NOT landed → add the holder-check at `Ezagent.Cap.Verifier`'s decision boundary using a core registry (`Ezagent.PrincipalFence`, byte-for-byte the `SpawnFence` registry pattern — core ETS table owned by EtsOwner + registrar re-registration from PR-5), so a CORE verifier can consult the DOMAIN predicate without a tier violation, and so it collapses into `authorize/3` cleanly.

- [ ] **Step 1: Write the failing test (inline cap, the PR-1-can't-reach case)**

```elixir
test "a tombstoned agent presenting an INLINE cap (never via EntityCaps.load) is denied at the authz decision" do
  {user, agent} = TestSupport.owned_agent_deleted!()
  inline_cap = TestSupport.signed_cap(holder: agent, action: some_action())
  ctx = %{caller: agent, caps: MapSet.new([inline_cap]), mode: :call}
  # PR-1 doesn't help: caps are inline in ctx, not loaded from the slice.
  assert {:error, _denied} = TestSupport.authorize(ctx, needed_for(some_action()))
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_core/test/ezagent/authz_holder_tombstone_test.exs`
Expected: FAIL — the verifier matches the inline signed cap and returns `:ok`; nothing checks the holder's tombstone for inline-presented caps.

- [ ] **Step 3: Add the holder-tombstone predicate at the decision (per the coordination branch)**

```elixir
# cap/verifier.ex (pre-unification) — after signature+shape+presenter, before returning :ok:
# holder gate: a tombstoned principal holds no usable authority, even inline.
with :ok <- Ezagent.PrincipalFence.check(holder_uri),   # runs registered domain predicate; empty => :ok fail-open (backstopped by PR-1/PR-2)
     %Capability{} = matched <- Enum.find(verified, &Capability.matches?(&1, needed)) do
  {:ok, matched}
else
  {:error, _} = denied -> denied
  nil -> {:error, :no_matching_cap}
end
```

(In the unified case: register `holder_not_tombstoned?` into `authorize/3`'s predicate list; the shape is identical.)

- [ ] **Step 4: Register the domain predicate at identity boot** (in `ezagent_domain_identity`'s `Application.start/2`, next to the existing `SpawnFence.register`), and extend `SpawnFenceRegistrar` (PR-5) to also keep the `PrincipalFence` registration alive across EtsOwner restarts.

- [ ] **Step 5: Run tests + the cap-check-chokepoint invariant gate**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_core/test/ezagent/authz_holder_tombstone_test.exs && mix ezagent.check_invariants`
Expected: PASS — and the `cap_check_only_at_chokepoint` gate is unaffected (the holder check is AT the chokepoint, not a new off-chokepoint cap read).

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_core/lib/ezagent/cap/verifier.ex apps/ezagent_core/lib/ezagent/principal_fence.ex apps/ezagent_core/test/ezagent/authz_holder_tombstone_test.exs
git commit -m "feat(offboarding): deny tombstoned holder at the authz decision for inline caps (rides unified authorize/3)

Defense-in-depth for the one path cap-load can't cover: caps presented inline in
ctx.caps. Core-tier consults the domain tombstone predicate via the PrincipalFence
registry (SpawnFence pattern); collapses into the unified authorize/3 when it lands
(a predicate beside epoch's gen check — not a second chokepoint).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-7: the enumerator gate — source-scan of every authority-use site (the correctness guarantee, not the runtime tests)

**Why this is a PR, not a nicety.** #1469 failed codex review THREE times on the same shape: "tests pass, but a chokepoint was missed." A hand-built chokepoint table + runtime tests prove the sites you *thought of* deny — they cannot prove the table is complete or that it stays complete as code drifts. This is a "revoke ALL authority" task, so the standing rule binds (MEMORY "Enumerate gates before deletion", "Completion = invariant test"; CLAUDE.md agent-orchestration "for any gate-ALL-X task, build the enumerator gate, run it empty-allowlist to produce the worklist, enforce it in CI — the gate is the correctness guarantee"). The runtime tests (PR-8) remain the load-bearing behavioral proof; THIS gate is the completeness proof that no authority-use site bypasses the tombstone check.

**The convergence dividend:** the epoch sister-plan already specifies this exact gate (epoch spec §8.1 source-scan + §8 presence-tripwire), and the machinery exists — `apps/ezagent_core/test/ezagent/cap_check_only_at_chokepoint_test.exs` (the `%{id, desc, pattern, allowlist}` over `apps/*/lib/**/*.ex`, no runtime BEAM) and `ezagent.check_invariants` #10 (which greps `kind/runtime.ex` for `Capability.matches?` and fails if absent). The **same site list is the worklist for BOTH** epoch's gen check and this tombstone check — build it once.

**Files:**
- Create/extend: `apps/ezagent_core/test/ezagent/tombstone_check_enumerator_test.exs` (mirror `cap_check_only_at_chokepoint_test.exs`)
- Modify: `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex` (add the presence tripwire)

**Interfaces:** consumes the chokepoint enumeration table above + the `Capability.matches?` consumer list surfaced during orientation.

- [ ] **Step 1: Enumerate every authority-use / `Capability.matches?` consumer, empty-allowlist**

The worklist (grep-verified during planning) — every site that turns a cap into an authorization decision MUST either (i) source its caps from the fail-closed `EntityCaps.load` (PR-1), or (ii) consult `tombstoned_principal?`/the `PrincipalFence`/the unified `authorize/3` holder-check (PR-6), or (iii) carry a reviewed, explicit exemption entry:

```
apps/ezagent_core/lib/ezagent/cap/verifier.ex:81                     # PR-6 covers
apps/ezagent_core/lib/ezagent/capability_registry.ex:449,526        # RULE each
apps/ezagent_core/lib/ezagent/notification_subscriptions.ex:508     # RULE
apps/ezagent_core/lib/ezagent/credential/resolver.ex:314            # RULE
apps/ezagent_core/lib/ezagent/capability/authorization.ex:29        # RULE
# projection-bypass reads (epoch §3.1 enumerates the same set):
apps/ezagent_domain_socialware/.../session_view.ex                   # RULE (a revoked board must not render)
external_mirror consumers, orchestrator tools                        # RULE
```

- [ ] **Step 2: Write the failing enumerator test (empty allowlist = red)**

```elixir
# tombstone_check_enumerator_test.exs
test "every Capability.matches? / authz consumer consults the tombstone check or is exempt" do
  offenders =
    authority_use_sites()                       # scan apps/*/lib/**/*.ex for the patterns
    |> Enum.reject(&sources_from_failclosed_cap_load?/1)
    |> Enum.reject(&consults_tombstone_predicate?/1)
    |> Enum.reject(&exempt?/1)                   # explicit reviewed allowlist, initially []
  assert offenders == [], "authority-use sites bypassing the tombstone check:\n#{inspect(offenders)}"
end
```

- [ ] **Step 3: Run it — it lists the real worklist (RED)**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/tombstone_check_enumerator_test.exs`
Expected: FAIL, printing the un-migrated sites. THIS red list is the completeness worklist — every site here is a chokepoint PR-1/PR-6 did not cover.

- [ ] **Step 4: Drive each listed site to green — route it through the check OR add a reviewed exemption**

For each offender: either it already funnels through `EntityCaps.load` (mark it via the `sources_from_failclosed_cap_load?` detector) / the `PrincipalFence` (PR-6), or wire it, or add an `exempt?` entry with a one-line reviewed justification (e.g. "authorizes visibility of an already-owned surface, not access to the target" — the epoch §3.1 carve-out shape). Codex reviews every exemption.

- [ ] **Step 5: Add the presence tripwire (positive assertion)**

A forbid-scan proves *other* sites don't authorize off-chokepoint; it cannot prove the tombstone check IS present in the verifier. Mirror `ezagent.check_invariants` #10: add an invariant that FAILS the build if the unified verifier / `cap/verifier.ex` (or `PrincipalFence.check`) does not contain the holder-tombstone call. The gate thus asserts BOTH presence and non-leakage.

- [ ] **Step 6: Run to green + wire into CI**

Run: `MIX_ENV=test mix test apps/ezagent_core/test/ezagent/tombstone_check_enumerator_test.exs && mix ezagent.check_invariants`
Expected: PASS with the allowlist reflecting ONLY reviewed exemptions. Confirm the test runs in the same CI stage as `cap_check_only_at_chokepoint_test.exs`.

- [ ] **Step 7: Commit**

```bash
git add apps/ezagent_core/test/ezagent/tombstone_check_enumerator_test.exs apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex
git commit -m "test(offboarding): source-scan enumerator + presence tripwire — no authority-use site bypasses the tombstone check

The completeness GATE (the guarantee, not the runtime tests): empty-allowlist red
lists every un-migrated authz/Capability.matches? consumer; each must route through
fail-closed cap-load or the tombstone predicate, or carry a reviewed exemption.
Shares the epoch program's site list (epoch spec §8).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-8: the completeness-proof acceptance suite

**Files:**
- Create: `apps/ezagent_domain_identity/test/ezagent/identity/delete_user_completeness_test.exs`

**Interfaces:** consumes all of PR-1..PR-7. These are the runtime invariant tests that, together with the PR-7 enumerator gate, ARE the completeness proof (task Acceptance) — the gate proves no site is missed; these prove the covered sites deny.

- [ ] **Step 1: Write the full acceptance suite**

```elixir
defmodule Ezagent.Identity.DeleteUserCompletenessTest do
  use Ezagent.DataCase, async: false
  # Each test asserts fail-before is impossible post-delete.

  # (1) Owned agent — alive OR busy — cannot authenticate / dispatch / load caps.
  test "owned agent fully revoked regardless of liveness" ...

  # (2) Nested lineage — a grandchild agent (spawned by U's agent) is revoked
  #     via the transitive lineage arm of tombstoned_principal?.
  test "grandchild lineage agent revoked" ...

  # (3) Independent agent NOT derived from U is UNAFFECTED (scoped revocation —
  #     guards against over-broad revocation; predicate is owner/lineage-FILTERED).
  test "workspace/admin-granted independent agent still authenticates + dispatches" ...

  # (4) F1 fence: respawn/absorb of a tombstoned agent refused even after an
  #     EtsOwner restart.
  test "respawn + absorb refused post-EtsOwner-restart" ...

  # (5) Busy >10s terminate-timeout agent STILL fully revoked (delete_user :ok),
  #     enqueued for reap. (The case that killed the old design.)
  test "busy terminate-timeout agent revoked, delete_user succeeds" ...

  # (6) Idempotent cascade sweep converges: run delete_user twice; second run is a
  #     clean idempotent :ok; a partial-failure retry reaches full revocation.
  test "idempotent cascade converges" ...
end
```

- [ ] **Step 2: Run the suite**

Run: `MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test/ezagent/identity/delete_user_completeness_test.exs`
Expected: PASS (all six).

- [ ] **Step 3: Full verify from umbrella root**

Run:
```bash
MIX_TEST_PARTITION=delinval MIX_ENV=test mix compile --warnings-as-errors
MIX_TEST_PARTITION=delinval MIX_ENV=test mix test apps/ezagent_domain_identity/test apps/ezagent_core/test
mix ezagent.check_invariants
```
Expected: compile clean; offboarding + core suites green; invariants green. (`DBConnection.OwnershipError` = known flake, re-run.)

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_domain_identity/test/ezagent/identity/delete_user_completeness_test.exs
git commit -m "test(offboarding): delete_user invalidation completeness proof (6 acceptance invariants)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TBWH8DkTYXNfdu9EgdDngQ"
```

---

### PR-9 (OPTIONAL, non-blocking): per-principal tombstone ETS hot-cache

`tombstoned_principal?/1` does DB reads + a depth-100 lineage walk. On the cap-load / authenticate / authz hot paths that is per-authorization DB cost. Epoch went to a per-URI ETS hot-cache for exactly this — a **third convergence point**. If Allen wants the hot-path win in this program (vs deferring to the shared epoch cache), add a per-principal ETS cache (`@target_hint_table` / `RoutingRegistry.reverse_index` precedent) keyed by principal URI, invalidated on any tombstone write, consulted before the DB walk, fail-closed on miss (fall through to the DB). Do NOT build this until PR-1..PR-8 are green — correctness must not depend on the cache.

---

## Self-Review

**Spec coverage** (task requirements → task):
- Pillar 1 honest terminate → PR-3 (with the exact `:ok`-coercion points cited: `kind.ex:535/542-543/556-557/560/563/565`; `lifecycle.ex:763` discard, `:818` hook-timeout coercion; `safe_kind_module` `kind.ex:664`).
- Pillar 2 invalidation → PR-1 (cap-load `entity_caps.ex:44-67`, the KEY gap), PR-2 (authenticate `token.ex:192-205`), PR-6 (authz inline caps `cap/verifier.ex:81`); cascade enumeration reused from #1469.
- Pillar 3 F1 fence → PR-5 (commit guard `identity.ex:618`; EtsOwner durability).
- Atomicity redefinition → PR-4 (the design fork, resolved).
- Architectural convergence with unified `authorize/3` → the dedicated section + PR-6 coordination rule + PR-7 shared enumerator + PR-9 cache convergence.
- Reuse #1469 sound parts (cascade, token revoke, cap-clear, idempotent retry) → Global Constraints base-branch + PR-4.
- Completeness GATE (source-scan enumerator, empty-allowlist worklist, presence tripwire — the guarantee that no authority-use site is missed) → PR-7.
- Acceptance invariants (runtime behavioral proof) → PR-8 (all six).

**Placeholder scan:** every code step shows real code or a real grep; test steps show real assertions. `TestSupport.*` helpers are named where fixtures are needed (spawn_owned_agent!, block_terminate_ms, inject_caps_clear_failure, restart_ets_owner!) — flagged as fixtures to build, not hand-waved logic.

**Type consistency:** `tombstoned_principal?/1`, `refute_tombstoned/1`, `teardown_and_reap/1`, `cascade_owned_agents/3`, `Users.tombstone/3`, `Users.deleted?/1`, `AgentTombstone.tombstone/3|tombstoned?/1`, `Token.revoke_all_for_entity/1`, `SpawnFence.{register,check}/*` used consistently with their #1469 signatures. New: `Kind.terminate/1 :: :ok | {:error, term()}`, `Kind.terminate!/1 :: :ok`, `Lifecycle.destroy/2 :: :ok | {:error, term()}`, `Lifecycle.destroy!/2 :: :ok`, `ReapQueue.{enqueue/1,pending/0,sweep/0}`, `PrincipalFence.check/1`.

**Open forks (need codex/Allen):** (1) the atomicity-boundary split — Allen approved, codex confirms; (2) F1 durability mechanism (registrar vs EtsOwner-init-callbacks) — pin one; (3) ReapQueue durable-vs-in-memory for v1; (4) hot-path cache (PR-9) now vs defer to epoch. Core cap-model PRs (PR-1, PR-4, PR-6) + the enumerator gate (PR-7) → codex adversarial review BEFORE kimi.

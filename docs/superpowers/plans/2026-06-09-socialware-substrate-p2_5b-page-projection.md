# Socialware Substrate P2.5b — Order-Independent Committed Page Projection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (`feedback_subagent_must_load_project_skills`).

**Goal:** Make the committed customer-page projection **order-independent and robust**: the page is the **maximum committed surface version** (`max(SettlementRecord.target_surface_version)` among `status == :committed` settlements), not "the latest committed settlement by `committed_at`". This removes two latent edge bugs P2.5a left in the page read — (1) a `committed_at` microsecond tie + non-padded turn-id lexicographic order could pick an older turn; (2) a delayed re-commit of an older turn could roll the page back — with one `max()` that does not depend on commit timestamp or turn-id ordering at all.

**Architecture:** Pure read-path change to `CustomerFeed.committed_surface_version/1` (introduced in P2.5a). The customer page must show the latest APPROVED-and-COMMITTED page; surface versions increase monotonically per session (`version_seq + 1` at compose) and are immutable-append, so "latest committed page" ≡ "highest committed `target_surface_version`". `max()` is inherently order-independent: it cannot be perturbed by `committed_at` ties, turn-id lexicographic order, or a late re-commit of an older (lower-version) turn. Settlement-based (no outbox column, no migration) → upgrade-safe (operates on existing `target_surface_version`). No `ezagent_core` change.

**Scope / sequencing change (was: "durable cursor"):** the earlier P2.5b draft added an outbox `committed_seq` commit-order cursor + `committed_deliveries_since/2` replay primitive. That is **deferred to P3**: it is the durable source the ExternalAdapter replays, it has **no consumer yet**, and its correctness is entangled with the **P2.5c** post-parent-turn-commit ordering (atomic outbox-insert + status-flip → a commit-order cursor). Per the spec ANTI-PATTERN "don't migrate a consumer onto a signal before its correct form exists," the cursor is built WITH P3 (after P2.5c), not speculatively now. P2.5b is just the page-projection robustness fix that makes the **current** (P2.5a) page read correct under ties + re-commit.

**Tech Stack:** Elixir 1.19 / OTP 27, `apps/ezagent_domain_socialware` (one function + tests). No migration. Run mix from the umbrella root with `MIX_ENV=test`.

**SAFETY:** No migration, no schema change — pure read-path. Nothing destructive; nothing touches `ezagent_core`.

---

## Background — grounded current state (after P2.5a, on origin/main)

- `CustomerFeed.snapshot/2` → `%{messages: …, page: customer_page(session)}`.
- `CustomerFeed.customer_page/1` (P2.5a) → `committed_surface_version(session_uri)` then `Surface.tree_for_version(surface_slice(session_uri), version)`. `surface_slice/1` is cold-safe (get_slice → StateRebuilder.rebuild + normalize_slice_view). **These stay unchanged.**
- `CustomerFeed.committed_surface_version/1` (P2.5a) — **the function this plan changes**. Currently:
  ```elixir
  from(s in SettlementRecord,
    where: s.session_uri == ^session_str and s.status == :committed and not is_nil(s.target_surface_version),
    order_by: [desc: s.committed_at, desc: s.turn_id],
    limit: 1,
    select: s.target_surface_version)
  |> Repo.one()
  ```
  The `committed_at desc, turn_id desc` ordering is the source of both edge bugs.
- `SettlementRecord`: `session_uri`, `status` `Ecto.Enum [:pending,:committed]`, `target_surface_version :integer`, `committed_at`. PK `turn_id` (`#{session}#turn-N`, non-padded).
- Turn ids are `…#turn-1 … #turn-10`; lexicographically `"#turn-9" > "#turn-10"`, so on a `committed_at` tie `turn_id desc` picks `#turn-9` (older). Surface `version_seq` increments per session, so a later turn has a higher `target_surface_version`.
- `customer_page/1` renders `Surface.tree_for_version(surface_slice, version)`; the `:surface` slice retains ALL versions (immutable append), so any committed version's tree is renderable.

**Why `max(target_surface_version)` is the correct page:** the customer must see the latest approved+committed page. Surface versions are per-session monotonic + immutable; the highest committed version IS the latest approved content (a "revert" is itself a new, higher version). `max()` ignores `committed_at`/`turn_id` entirely, so ties and late re-commits cannot change it.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex` | Modify | `committed_surface_version/1` → `max(target_surface_version)` among committed settlements (order-independent). |
| `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs` | Modify | Add `committed_at`-tie + re-commit-no-rollback regressions (the existing P2.5a gate tests stay). |

No migration. No `ezagent_core` change. No outbox/schema change.

---

## Task 1: Order-independent committed page projection

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs`

- [ ] **Step 1: Write the failing tests**

Add to the existing `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs` (created in P2.5a — it already has `spawn_session/0`, `test_token/1`, `compose_page/2`, `settle/2`, `dispatch/4`, `wait_until/2`). Add `import Ecto.Query` + `alias Ezagent.Socialware.SettlementRecord` near the top if not present, then add these `describe` blocks before the final `end`:

```elixir
  describe "committed page is the MAX committed surface version (order-independent)" do
    test "re-committing an older turn after a newer one does NOT roll the page back" do
      uri = spawn_session()
      token = test_token(uri)
      {t1, _v1} = compose_page(uri, %{type: "text", props: %{text: "p1"}})
      settle(uri, t1)
      {t2, _v2} = compose_page(uri, %{type: "text", props: %{text: "p2"}})
      settle(uri, t2)

      {:ok, s1_before} = Ezagent.Socialware.Settlement.get(t1)

      # Delayed re-commit of the OLDER turn (commit_after_pointer is public + idempotent).
      _ = Ezagent.Socialware.Settlement.commit_after_pointer(t1, nil)

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == %{type: "text", props: %{text: "p2"}}, "page must stay the MAX version"

      # (Hygiene) re-commit must not be observable; if the no-op guard is present,
      # committed_at is unchanged. If it is not, the max() page is still correct.
      {:ok, s1_after} = Ezagent.Socialware.Settlement.get(t1)
      assert s1_after.committed_at == s1_before.committed_at
    end

    test "committed_at tie does not pick an older turn (max version wins, not lexicographic turn_id)" do
      uri = spawn_session()
      token = test_token(uri)

      # 10 turns -> committed surface versions 1..10, turn ids #turn-1..#turn-10.
      # "#turn-9" sorts lexicographically AFTER "#turn-10" — the old
      # (committed_at desc, turn_id desc) read would pick #turn-9 (version 9) on a tie.
      tns = for n <- 1..10 do
        {t, _v} = compose_page(uri, %{type: "text", props: %{text: "p#{n}"}})
        settle(uri, t)
        t
      end

      t9 = Enum.at(tns, 8)
      t10 = Enum.at(tns, 9)
      {:ok, s10} = Ezagent.Socialware.Settlement.get(t10)

      from(s in SettlementRecord, where: s.turn_id in ^[t9, t10])
      |> EzagentCore.Repo.update_all(set: [committed_at: s10.committed_at])

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == %{type: "text", props: %{text: "p10"}}
    end
  end
```

> `compose_page/2` returns `{turn_id, version}` and does NOT settle; `settle/2` drives commit + waits for `status: :committed` (both already in the P2.5a test file — reuse, do not redefine). `commit_after_pointer/2` is `public` in `Settlement`. If the P2.5a file lacks `import Ecto.Query`, add it (used by the tie test's `update_all`).

- [ ] **Step 2: Run to verify the tie test fails (and re-commit may already pass)**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs -v 2>&1 | tail -25`
Expected: the `committed_at` tie test FAILS (old `committed_at desc, turn_id desc` returns version 9). The re-commit test may pass or fail depending on whether P2.5a's `commit_after_pointer` rewrites `committed_at` — either way the `max()` fix below makes both pass.

- [ ] **Step 3: Switch the page read to `max(target_surface_version)`**

Edit `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`. Replace `committed_surface_version/1` (P2.5a) with:

```elixir
  # P2.5b — the committed customer page = the MAXIMUM committed surface version.
  # Surface versions are per-session monotonic + immutable-append, so the highest
  # committed target_surface_version is the latest approved+committed page. Using
  # max() makes this order-INDEPENDENT: it cannot be perturbed by a committed_at
  # microsecond tie + non-padded turn-id lexicographic order, nor by a delayed
  # re-commit of an older (lower-version) turn (codex P2.5b HIGH x2). nil when no
  # committed page (messages-only commits have target_surface_version nil and are
  # ignored by max()).
  defp committed_surface_version(session_uri) do
    session_str = URI.to_string(session_uri)

    from(s in SettlementRecord,
      where: s.session_uri == ^session_str and s.status == :committed,
      select: max(s.target_surface_version)
    )
    |> Repo.one()
  end
```

(`SettlementRecord`, `Repo`, `import Ecto.Query` are already present in `customer_feed.ex` from P2.5a — no alias change.)

- [ ] **Step 4: Run to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs -v 2>&1 | tail -20`
Expected: PASS — the tie test now returns version 10; the re-commit test stays version 2; all existing P2.5a gate tests (committed-page, leak, partial-commit, wake-up-loss, cold-read, cold-auth) still pass (they each have a single committed page version, where `max()` == the only/latest version).

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs
git commit -m "fix(socialware/p2.5b): committed page = max committed surface version (order-independent)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Regression + arch gate

- [ ] **Step 1: Full socialware suite**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -8`
Expected: 0 failures (incl. all P2.5a customer-page + attachment tests + `turn_customer_feed_integration_test.exs`).

- [ ] **Step 2: Arch fitness gates**

Run (each exit 0):
```bash
MIX_ENV=test mix compile --warnings-as-errors --force 2>&1 | tail -5
MIX_ENV=test mix ezagent.arch.scan 2>&1 | grep -E "FAIL|gt_1000"
MIX_ENV=test mix ezagent.check_invariants 2>&1 | tail -4
```
Expected: no FAIL; `oversized_modules_gt_1000: count=0`; invariants clean.

---

## Self-Review (run before handing to codex)

1. **Correctness of `max()`:** the customer page must show the latest approved+committed page; surface versions are per-session monotonic + immutable, so `max(committed target_surface_version)` is exactly that. `max()` is order-independent → immune to `committed_at` ties (codex rev2) AND late re-commit of an older turn (codex rev1 HIGH-2). Both edge bugs are fixed at the source, not by tiebreak tuning.
2. **Upgrade-safe:** settlement-based on the existing `target_surface_version` (populated for all committed settlements). No new column, no migration, no backfill — so none of the legacy-row hazards the earlier draft introduced (codex rev3 backfill tie / `mark_committed_for_test` MatchError) can occur.
3. **messages-only commits:** `target_surface_version` is nil for them; `max()` ignores nils → a message-only commit never clears a previously-committed page. Correct.
4. **Existing P2.5a tests:** each has exactly one committed page version, so `max()` returns the same value the old `committed_at desc` read did → they stay green (partial-commit/pending → no committed settlement → `max()` nil → page nil).
5. **Cursor deferral is intentional:** the durable `committed_seq` cursor + `committed_deliveries_since/2` are built WITH P3 (its only consumer) after P2.5c's commit-ordering — avoiding consumer-less infra whose backfill/idempotency edges this review surfaced. P2.5b ships only the page-projection robustness fix.
6. **No core / no schema change:** one function + two tests in `ezagent_domain_socialware`.

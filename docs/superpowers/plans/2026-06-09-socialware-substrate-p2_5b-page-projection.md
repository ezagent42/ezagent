# Socialware Substrate P2.5b — Commit-Order Cursor + Order-Correct Page Projection Implementation Plan

> **Rollback-correctness (codex rev4 HIGH):** the socialware model permits ROLLBACK — `Surface.handle_approve/2` accepts ANY retained version, so an operator can commit v2 then later approve+commit the older retained v1, and the customer page MUST then become v1. A `max(version)` projection is therefore WRONG (it keeps serving v2). The page MUST follow **commit order** — exactly what `committed_seq` gives: the rollback turn commits last → highest `committed_seq` → its lower `surface_version` is the page. So the page reads from the max-`committed_seq` page-bearing outbox row; rollback, `committed_at` ties, and late re-commit are all resolved by one total commit order.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (project invariant `feedback_subagent_must_load_project_skills`).

**Goal:** Give the socialware customer-delivery outbox a **commit-order cursor** + the committed **surface version**, and a cursor-addressable replay primitive `CustomerFeed.committed_deliveries_since/2` — the durable source the P3 ExternalAdapter will replay from. The cursor is assigned **at the commit boundary** (not at outbox insert), so it is monotonic in commit order and a delivery can NEVER be permanently skipped by an out-of-order commit (the hazard codex flagged on the P2.5a rev2 pre-commit `id` cursor).

**Architecture:** Socialware-local (no `ezagent_core` library change beyond a migration). Add two outbox columns: `surface_version :integer` (the committed page version, deferred from P2.5a) and `committed_seq :integer` (the per-session monotonic **commit-order** cursor, NULL until committed). `Settlement.commit_after_pointer/2` already runs inside the single `SocialwareSession` GenServer (commits are serialized per session), so at the commit boundary it atomically (one `Repo.transaction`) (1) assigns `committed_seq = max(committed_seq for session) + 1`, (2) writes `surface_version`, (3) flips `settlement.status` to `:committed`. Because `committed_seq` is set ONLY at commit, `committed_seq != nil` ⟺ committed, and a pending row (NULL seq) is invisible to replay and later receives the NEXT seq (higher than every prior commit) — so it is never skipped. `CustomerFeed.committed_deliveries_since(session, cursor)` returns outbox rows WHERE `committed_seq > cursor` ascending; `latest_cursor/1` returns the max.

**Scope boundary:** This is the durable-source half. The **post-parent-turn-commit ordering** fix (settlement casts firing before the parent Turn slice durably commits — rev4 HIGH; touches `ezagent_core` Kind.Server) is the separate **P2.5c** plan, and **wire-schema #44** folds into P3 prep. Both land before P3 consumes this source.

**Tech Stack:** Elixir 1.19 / OTP 27, umbrella (`apps/ezagent_domain_socialware`, `apps/ezagent_core` migration only), Ecto (PostgreSQL + SQLite via exqlite — plain `add` columns + a backfill), ExUnit. Run mix from the umbrella root with `MIX_ENV=test`.

**SAFETY:** Migration runs ONLY against the test DB here (`MIX_ENV=test mix ecto.migrate`). NEVER against live dev/prod (`feedback_destructive_migration_anti_pattern`). The migration is two non-destructive `add` columns + an in-migration backfill of existing committed rows (idempotent, ordered by `committed_at`). Flag any non-test migration to the operator.

---

## Background — grounded current state

- `Ezagent.Socialware.Settlement.commit_after_pointer/2` (`settlement.ex:96-129`): `confirm_pointer_advanced` → `emit_outbox_once` (inserts the outbox row, marks `@outbox_emitted`) → `get` → `committed_ready?` → `Repo.update_all(set: [status: :committed, committed_at: committed_at])` → conditional `broadcast`. **The outbox row is inserted BEFORE the status flip.**
- `emit_outbox_once/1` (`settlement.ex:161-190`): `Repo.insert_all(CustomerOutbox, [%{turn_id, session_uri, workspace_uri, message_ids, emitted_at}], on_conflict: :nothing, conflict_target: :turn_id)`. No `surface_version`, no `committed_seq`.
- `Ezagent.Socialware.CustomerOutbox` (`customer_outbox.ex`): `@primary_key {:turn_id, :string, []}`; fields `session_uri, workspace_uri, message_ids, emitted_at`.
- `SettlementRecord`: `status` `Ecto.Enum [:pending, :committed]`, `committed_at`, `target_surface_version`, `session_uri`.
- `commit_after_pointer/2` runs inside `Surface.handle_commit_settlement/2` → dispatched on the `SocialwareSession` Kind → executed by that single GenServer process. **Per-session commits are serialized** (one mailbox), so `max(committed_seq)+1` within a session has no concurrent writer.
- Outbox table migration: `apps/ezagent_core/priv/repo/migrations/20260618000400_add_message_visibility_and_socialware_settlements.exs` (table created there); next free slot ≥ `20260618000700` (P2.5a was descoped to no migration, so `…000600` was never used — confirm with `ls apps/ezagent_core/priv/repo/migrations` and pick the next unused timestamp after the highest existing).
- `CustomerFeed` (`customer_feed.ex`) after P2.5a: has `import Ecto.Query`, `alias …{CustomerAuth, SettlementRecord}`, `alias EzagentCore.Repo`, `alias Ezagent.URI, as: EzURI`; `customer_page/1` reads the committed settlement's `target_surface_version` (NOT the outbox). P2.5b ADDS the cursor primitive; it does not change `customer_page/1`.

**Why a commit-order `committed_seq`, not the insert-order `id`:** an `id`/insert-order cursor is allocated before the status flip; a pending row id=1 can be skipped forever if id=2 commits first and a consumer advances past it (codex P2.5a rev2 CRITICAL). Assigning the cursor AT commit, in commit order, makes skipping impossible by construction.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/ezagent_core/priv/repo/migrations/<next>_socialware_outbox_surface_version_and_committed_seq.exs` | Create | `add :surface_version, :integer` + `add :committed_seq, :integer` to `socialware_customer_outbox`; unique index `(session_uri, committed_seq)`; backfill existing committed rows. |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex` | Modify | Add `surface_version :integer` + `committed_seq :integer` fields. |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex` | Modify | `emit_outbox_once/1` writes `surface_version`; the commit step atomically assigns `committed_seq` + flips status in one transaction. |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex` | Modify | Add `committed_deliveries_since/2` + `latest_cursor/1` (cursor replay); re-point `committed_surface_version/1` (P2.5a) onto the outbox `committed_seq` order so the page projection shares one commit-order source with replay. |
| `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_cursor_test.exs` | Create | commit-order cursor + replay-since + out-of-order-no-skip + surface_version + pending-invisible + upgrade-pending + re-commit-no-op + committed_at-tie tests. |

---

## Task 1: Migration — `surface_version` + `committed_seq` + backfill

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/<next>_socialware_outbox_surface_version_and_committed_seq.exs`

- [ ] **Step 1: Pick the next migration timestamp**

Run: `ls apps/ezagent_core/priv/repo/migrations | sort | tail -3`
Pick a timestamp strictly greater than the highest existing (e.g. `20260618000700`). Use it in the filename + module name.

- [ ] **Step 2: Write the migration**

```elixir
defmodule EzagentCore.Repo.Migrations.SocialwareOutboxSurfaceVersionAndCommittedSeq do
  use Ecto.Migration
  import Ecto.Query

  # P2.5b — durable commit-order delivery cursor + committed page version on the
  # customer outbox. `committed_seq` is the per-session monotonic COMMIT-ORDER
  # cursor (NULL until the settlement commits; assigned at the commit boundary).
  # `surface_version` is the committed page version (mirrors
  # SettlementRecord.target_surface_version) carried on the durable delivery row
  # for the P3 ExternalAdapter. Non-destructive adds + a one-time backfill of
  # existing committed rows so the cursor is dense from deploy.
  def up do
    alter table(:socialware_customer_outbox) do
      add :surface_version, :integer
      add :committed_seq, :integer
    end

    # Backfill existing committed rows so committed_seq is dense from deploy
    # (else legacy committed pages would vanish — the page read is committed_seq
    # based). Delegated to a PERMANENT idempotent helper (only touches committed
    # rows whose committed_seq IS NULL), so it is unit-testable and safe to keep
    # across future refactors (a re-run on a fresh DB finds no NULL-seq committed
    # rows and no-ops).
    flush()
    Ezagent.Socialware.Settlement.backfill_committed_seq!()

    # A per-session unique index — a backstop against a committed_seq collision
    # (per-session commits are serialized by the single SocialwareSession
    # GenServer, so a collision would be a real bug → fail loudly, not corrupt).
    create unique_index(:socialware_customer_outbox, [:session_uri, :committed_seq],
             name: :socialware_customer_outbox_session_committed_seq_index
           )
  end

  def down do
    drop index(:socialware_customer_outbox, [:session_uri, :committed_seq],
           name: :socialware_customer_outbox_session_committed_seq_index
         )

    alter table(:socialware_customer_outbox) do
      remove :committed_seq
      remove :surface_version
    end
  end
end
```

- [ ] **Step 3: Do NOT run the migration yet (ordering — codex rev5 HIGH)**

The migration calls `Ezagent.Socialware.Settlement.backfill_committed_seq!/0`, which does not exist until Task 3. Running `mix ecto.migrate` now would raise `UndefinedFunctionError`. **Compile-only check** the migration file is syntactically valid (`MIX_ENV=test mix compile 2>&1 | tail -3`), then proceed. The migration is RUN in **Task 3 Step 5** (after the schema in Task 2 + the helper in Task 3 exist). NEVER run against dev/prod.

- [ ] **Step 4: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/<next>_socialware_outbox_surface_version_and_committed_seq.exs
git commit -m "feat(socialware/p2.5b): outbox surface_version + committed_seq cursor migration (not yet run)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `CustomerOutbox` schema — `surface_version` + `committed_seq`

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex`

- [ ] **Step 1: Add the fields**

```elixir
defmodule Ezagent.Socialware.CustomerOutbox do
  use Ecto.Schema

  @primary_key {:turn_id, :string, []}

  schema "socialware_customer_outbox" do
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:message_ids, {:array, :string}, default: [])
    # P2.5b — the committed page version this delivery carries (nil = messages
    # only). Mirrors SettlementRecord.target_surface_version, denormalized onto
    # the durable delivery row for the P3 adapter.
    field(:surface_version, :integer)
    # P2.5b — per-session monotonic COMMIT-ORDER cursor. NULL until the
    # settlement commits (assigned at the commit boundary in commit_after_pointer).
    # committed_seq != nil <=> the delivery is committed-visible.
    field(:committed_seq, :integer)
    field(:emitted_at, :utc_datetime_usec)
  end
end
```

- [ ] **Step 2: Compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tail -10`
Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex
git commit -m "feat(socialware/p2.5b): CustomerOutbox surface_version + committed_seq fields

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Atomic commit-seq assignment in `Settlement.commit_after_pointer/2`

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_cursor_test.exs` (create)

- [ ] **Step 1: Write the failing tests**

Create `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_cursor_test.exs`:

```elixir
defmodule Ezagent.Socialware.CustomerDeliveryCursorTest do
  @moduledoc """
  P2.5b — the customer-delivery outbox is a durable, cursor-addressable source.
  committed_seq is assigned at the commit boundary in commit order (per session),
  so replay never skips an out-of-order-committed row; pending rows are invisible.
  """
  use EzagentCore.DataCase, async: false

  import Ecto.Query

  alias Ezagent.Invocation
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.{CustomerFeed, CustomerOutbox, SettlementRecord}
  alias EzagentCore.Repo

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "p2-5b-#{System.unique_integer([:positive])}")
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(s, b, a), do: Ezagent.URI.new!("#{URI.to_string(s)}?action=#{b}.#{a}")

  defp dispatch(s, b, a, args) do
    Invocation.dispatch(%Invocation{
      target: target(s, b, a),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")
  defp wait_until(fun, attempts), do: if(fun.(), do: :ok, else: (Process.sleep(20); wait_until(fun, attempts - 1)))

  defp spawn_session do
    uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(uri))
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: uri})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  defp test_token(session_uri) do
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)
    Ezagent.Socialware.CustomerAuth.issue_token(session_uri, workspace_uri)
  end

  # full turn -> committed delivery; returns turn_id.
  defp run_turn(uri, page_tree) do
    {:ok, %{turn_id: turn_id}} =
      dispatch(uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    {:ok, _} =
      dispatch(uri, :turn, :dispatch, %{
        turn_id: turn_id,
        subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
      })

    {:ok, _} =
      dispatch(uri, :turn, :deliver, %{
        turn_id: turn_id,
        subtask_id: :page,
        card_ref: %{kind: :page, tree: page_tree}
      })

    {:ok, %{version: _v}} = dispatch(uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})
    {:ok, %{status: :settled}} = dispatch(uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn ->
      case Repo.get_by(CustomerOutbox, turn_id: turn_id) do
        %{committed_seq: seq} when is_integer(seq) -> true
        _ -> false
      end
    end)

    turn_id
  end

  describe "committed_seq assignment" do
    test "the first committed delivery gets committed_seq 1 + records surface_version" do
      uri = spawn_session()
      turn_id = run_turn(uri, %{type: "text", props: %{text: "p1"}})

      row = Repo.get_by(CustomerOutbox, turn_id: turn_id)
      assert row.committed_seq == 1
      assert row.surface_version == 1
    end

    test "successive committed deliveries get increasing per-session committed_seq" do
      uri = spawn_session()
      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      assert Repo.get_by(CustomerOutbox, turn_id: t1).committed_seq == 1
      assert Repo.get_by(CustomerOutbox, turn_id: t2).committed_seq == 2
    end
  end

  describe "committed_deliveries_since/2" do
    test "returns committed deliveries with committed_seq > cursor, ascending" do
      uri = spawn_session()
      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      all = CustomerFeed.committed_deliveries_since(uri, 0)
      assert Enum.map(all, & &1.turn_id) == [t1, t2]
      assert Enum.map(all, & &1.cursor) == [1, 2]
      assert List.last(all).surface_version == 2

      assert Enum.map(CustomerFeed.committed_deliveries_since(uri, 1), & &1.turn_id) == [t2]
      assert CustomerFeed.committed_deliveries_since(uri, 2) == []
    end

    test "latest_cursor/1 is the max committed_seq (0 when none)" do
      uri = spawn_session()
      assert CustomerFeed.latest_cursor(uri) == 0
      _ = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      assert CustomerFeed.latest_cursor(uri) == 1
    end
  end

  describe "pending rows are invisible + never skipped (codex rev2 hazard)" do
    test "a pending settlement's outbox row has nil committed_seq and is not replayed; on commit it gets the NEXT seq" do
      uri = spawn_session()
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)

      # Commit one real delivery first -> committed_seq 1.
      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      assert Repo.get_by(CustomerOutbox, turn_id: t1).committed_seq == 1

      # Manually create a PENDING settlement + outbox row (the partial-commit
      # window) for a second turn.
      pending_turn = "#{URI.to_string(uri)}#turn-pending"

      {:ok, _} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: pending_turn,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: 2
        })

      {:ok, _} =
        Repo.insert(%CustomerOutbox{
          turn_id: pending_turn,
          session_uri: URI.to_string(uri),
          workspace_uri: URI.to_string(workspace_uri),
          message_ids: [],
          surface_version: 2,
          committed_seq: nil,
          emitted_at: DateTime.utc_now()
        })

      # Pending row: nil seq, invisible to replay.
      assert Repo.get_by(CustomerOutbox, turn_id: pending_turn).committed_seq == nil
      assert Enum.map(CustomerFeed.committed_deliveries_since(uri, 0), & &1.turn_id) == [t1]

      # A THIRD real turn commits while the second is still pending.
      t3 = run_turn(uri, %{type: "text", props: %{text: "p3"}})
      assert Repo.get_by(CustomerOutbox, turn_id: t3).committed_seq == 2

      # Now commit the pending one -> it MUST get the next seq (3), not be skipped.
      # mark_committed_for_test now does the full commit (status + seq + surface_version).
      {:ok, _} = Ezagent.Socialware.Settlement.mark_committed_for_test(pending_turn)

      assert Repo.get_by(CustomerOutbox, turn_id: pending_turn).committed_seq == 3

      # A consumer that had advanced to cursor 2 still sees the late commit.
      assert Enum.map(CustomerFeed.committed_deliveries_since(uri, 2), & &1.turn_id) == [pending_turn]
    end
  end

  describe "upgrade: pending outbox row with nil surface_version (codex rev1 HIGH-1)" do
    test "committing it assigns BOTH committed_seq and surface_version from the settlement" do
      uri = spawn_session()
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)
      turn_id = "#{URI.to_string(uri)}#turn-legacy"

      {:ok, _} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: turn_id,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: 7
        })

      # Pre-migration-shaped outbox row: surface_version + committed_seq both nil.
      {:ok, _} =
        Repo.insert(%CustomerOutbox{
          turn_id: turn_id,
          session_uri: URI.to_string(uri),
          workspace_uri: URI.to_string(workspace_uri),
          message_ids: [],
          surface_version: nil,
          committed_seq: nil,
          emitted_at: DateTime.utc_now()
        })

      # mark_committed_for_test now does the full commit (status + seq + surface_version).
      {:ok, _} = Ezagent.Socialware.Settlement.mark_committed_for_test(turn_id)

      row = Repo.get_by(CustomerOutbox, turn_id: turn_id)
      assert row.committed_seq == 1
      assert row.surface_version == 7, "upgrade-pending row must get surface_version at commit"

      [d] = CustomerFeed.committed_deliveries_since(uri, 0)
      assert d.surface_version == 7
    end
  end

  describe "re-commit is a full no-op (codex rev1 HIGH-2): page does not roll back" do
    test "re-committing an older turn after a newer one preserves committed_at + latest page" do
      uri = spawn_session()
      token = test_token(uri)
      t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      {:ok, s1_before} = Ezagent.Socialware.Settlement.get(t1)
      assert s1_before.status == :committed

      # Delayed re-commit of the OLDER turn — must be a complete no-op.
      {:ok, %{status: :committed}} = Ezagent.Socialware.Settlement.commit_after_pointer(t1, nil)

      {:ok, s1_after} = Ezagent.Socialware.Settlement.get(t1)
      assert s1_after.committed_at == s1_before.committed_at, "committed_at must NOT move on re-commit"
      assert Repo.get_by(CustomerOutbox, turn_id: t1).committed_seq == 1

      # Cursor order unchanged; the customer page stays the NEWER version.
      assert Enum.map(CustomerFeed.committed_deliveries_since(uri, 0), & &1.turn_id) == [t1, t2]
      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == %{type: "text", props: %{text: "p2"}}
    end
  end

  describe "committed_at tie: page follows committed_seq, not lexicographic turn_id (codex rev2 HIGH)" do
    test "two latest deliveries sharing committed_at -> page is the max-committed_seq version" do
      uri = spawn_session()
      token = test_token(uri)

      # 10 turns -> surface versions 1..10, committed_seq 1..10, turn ids
      # ...#turn-1 .. #turn-10. Lexicographically "#turn-9" SORTS AFTER "#turn-10",
      # so the OLD (committed_at desc, turn_id desc) projection would wrongly pick
      # turn-9 (older, version 9) on a committed_at tie.
      turn_ids = for n <- 1..10, do: run_turn(uri, %{type: "text", props: %{text: "p#{n}"}})
      t9 = Enum.at(turn_ids, 8)
      t10 = Enum.at(turn_ids, 9)

      # Force turn-9 + turn-10 to share the LATEST committed_at (a microsecond tie).
      {:ok, s10} = Ezagent.Socialware.Settlement.get(t10)

      from(s in SettlementRecord, where: s.turn_id in ^[t9, t10])
      |> Repo.update_all(set: [committed_at: s10.committed_at])

      assert Repo.get_by(CustomerOutbox, turn_id: t9).committed_seq == 9
      assert Repo.get_by(CustomerOutbox, turn_id: t10).committed_seq == 10

      # committed_seq is the authority -> page is version 10 (NOT version 9).
      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == %{type: "text", props: %{text: "p10"}}

      # ...and it agrees with the cursor replay's last delivery.
      assert List.last(CustomerFeed.committed_deliveries_since(uri, 0)).turn_id == t10
    end
  end

  describe "rollback to an older retained version (codex rev4 HIGH): page follows commit order, not max(version)" do
    test "commit v2, then commit a rollback to v1 -> page is v1 (commit-order, not the max version)" do
      uri = spawn_session()
      token = test_token(uri)
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)

      _t1 = run_turn(uri, %{type: "text", props: %{text: "p1"}})
      _t2 = run_turn(uri, %{type: "text", props: %{text: "p2"}})

      {:ok, snap2} = CustomerFeed.snapshot(uri, token)
      assert snap2.page == %{type: "text", props: %{text: "p2"}}

      # ROLLBACK: a NEW commit re-approves the OLDER retained version 1
      # (Surface.handle_approve accepts any retained version). Constructed
      # manually because run_turn always produces a NEW version.
      rollback_turn = "#{URI.to_string(uri)}#turn-rollback"

      {:ok, _} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: rollback_turn,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: 1
        })

      {:ok, _} =
        Repo.insert(%CustomerOutbox{
          turn_id: rollback_turn,
          session_uri: URI.to_string(uri),
          workspace_uri: URI.to_string(workspace_uri),
          message_ids: [],
          surface_version: 1,
          committed_seq: nil,
          emitted_at: DateTime.utc_now()
        })

      {:ok, _} = Ezagent.Socialware.Settlement.mark_committed_for_test(rollback_turn)

      # The rollback committed LAST -> highest committed_seq -> page is v1.
      # max(version) would WRONGLY keep serving v2; commit-order is correct.
      assert Repo.get_by(CustomerOutbox, turn_id: rollback_turn).committed_seq == 3
      {:ok, snap1} = CustomerFeed.snapshot(uri, token)
      assert snap1.page == %{type: "text", props: %{text: "p1"}}
    end
  end

  describe "backfill_committed_seq! (codex rev3 HIGH): legacy committed rows get commit-order seq" do
    test "NULL-seq committed rows are numbered; tied committed_at -> higher version gets higher seq (not lexicographic)" do
      uri = spawn_session()
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)
      now = DateTime.utc_now()

      # Two LEGACY committed rows sharing committed_at; "#turn-9" (version 1) sorts
      # lexicographically AFTER "#turn-10" (version 2) — a raw turn_id tiebreak
      # would give #turn-9 the higher seq (wrong). The version tiebreak fixes it.
      legacy = [
        {"#{URI.to_string(uri)}#turn-9", 1},
        {"#{URI.to_string(uri)}#turn-10", 2}
      ]

      for {turn_id, ver} <- legacy do
        {:ok, _} =
          Ezagent.Socialware.Settlement.begin(%{
            turn_id: turn_id,
            session_uri: uri,
            workspace_uri: workspace_uri,
            target_message_ids: [],
            target_surface_version: ver
          })

        # Force committed status + identical committed_at, leaving committed_seq NULL
        # (the pre-migration legacy shape).
        from(s in SettlementRecord, where: s.turn_id == ^turn_id)
        |> Repo.update_all(set: [status: :committed, committed_at: now])

        {:ok, _} =
          Repo.insert(%CustomerOutbox{
            turn_id: turn_id,
            session_uri: URI.to_string(uri),
            workspace_uri: URI.to_string(workspace_uri),
            message_ids: [],
            surface_version: nil,
            committed_seq: nil,
            emitted_at: now
          })
      end

      :ok = Ezagent.Socialware.Settlement.backfill_committed_seq!()

      t9 = "#{URI.to_string(uri)}#turn-9"
      t10 = "#{URI.to_string(uri)}#turn-10"

      # version tiebreak: turn-10 (version 2) gets the HIGHER seq.
      assert Repo.get_by(CustomerOutbox, turn_id: t9).committed_seq <
               Repo.get_by(CustomerOutbox, turn_id: t10).committed_seq

      # surface_version backfilled from the settlement.
      assert Repo.get_by(CustomerOutbox, turn_id: t10).surface_version == 2
    end
  end
end
```

> **Note:** the pending-row scenarios are constructed manually (bypassing the normal dispatch commit path), then committed via the existing public `mark_committed_for_test/1` — which Task 3 Step 3 updates to ALSO assign `committed_seq` + `surface_version`, so it faithfully reproduces the real commit boundary. No separate seq test-helper is exposed.

- [ ] **Step 2: Run to verify they fail**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_cursor_test.exs -v 2>&1 | tail -20`
Expected: FAIL — `committed_seq` is nil (not assigned) + `committed_deliveries_since/2` undefined.

- [ ] **Step 3: Implement the atomic commit-seq assignment**

Edit `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex`:

(a) `emit_outbox_once/1` — add `surface_version` to the insert (committed_seq stays nil at insert):

```elixir
  defp emit_outbox_once(%SettlementRecord{} = settlement) do
    message_ids = message_ids(settlement.turn_id)

    {inserted, _} =
      Repo.insert_all(
        CustomerOutbox,
        [
          %{
            turn_id: settlement.turn_id,
            session_uri: settlement.session_uri,
            workspace_uri: settlement.workspace_uri,
            message_ids: message_ids,
            surface_version: settlement.target_surface_version,
            emitted_at: DateTime.utc_now()
          }
        ],
        on_conflict: :nothing,
        conflict_target: :turn_id
      )

    case inserted do
      1 -> {:ok, _s} = mark_subwrite(settlement, @outbox_emitted); {:ok, true}
      0 -> {:ok, _s} = mark_subwrite(settlement, @outbox_emitted); {:ok, false}
    end
  end
```

(b1) **Full no-op on re-commit (codex rev1 HIGH-2).** An already-`:committed` settlement MUST be a complete no-op — do NOT rewrite `committed_at`/`status`/`committed_seq`. Otherwise a delayed re-commit of an older turn bumps its `committed_at` to now, and `customer_page/1` (P2.5a, "latest committed by `committed_at desc`") would roll the customer page back to the older surface version. Add this guard at the TOP of `commit_after_pointer/2` (before `confirm_pointer_advanced`):

```elixir
  def commit_after_pointer(turn_id, approved_version) do
    case get(turn_id) do
      {:ok, %SettlementRecord{status: :committed}} ->
        # Already committed — FULL no-op. Preserve committed_at + committed_seq
        # so the durable cursor order and the page projection never disagree
        # (codex P2.5b HIGH). No re-broadcast.
        {:ok, %{status: :committed, message_ids: message_ids(turn_id), emitted?: false}}

      _ ->
        commit_pending_after_pointer(turn_id, approved_version)
    end
  end

  defp commit_pending_after_pointer(turn_id, approved_version) do
    # ... the EXISTING commit_after_pointer body (confirm_pointer_advanced ->
    # emit_outbox_once -> get -> committed_ready? -> the transaction below ->
    # broadcast), moved verbatim into this private fn ...
  end
```

(b2) In `commit_pending_after_pointer/2`, replace the bare `update_all(set: [status: :committed, committed_at: …])` block with an atomic transaction that ALSO assigns `committed_seq` + `surface_version`:

```elixir
      committed_at = DateTime.utc_now()
      message_ids = message_ids(turn_id)

      {:ok, _} =
        Repo.transaction(fn ->
          # `settlement` here is the freshly re-fetched record (it carries
          # target_surface_version) bound earlier in this body by `get(turn_id)`.
          assign_committed_seq(settlement)

          {1, _} =
            from(s in SettlementRecord, where: s.turn_id == ^turn_id)
            |> Repo.update_all(set: [status: :committed, committed_at: committed_at])
        end)
```

(c) Add the seq-assignment helper (idempotent — only assigns when the row's `committed_seq` is still nil) + the public test-only wrapper:

```elixir
  # P2.5b — assign the per-session monotonic COMMIT-ORDER cursor to this turn's
  # outbox row, IF not already assigned (idempotent re-commit). ALSO (re)writes
  # surface_version from the settlement — covers an UPGRADE-pending row inserted
  # before this migration with surface_version == NULL (codex rev1 HIGH-1): the
  # committed delivery must carry the page version P3 replays. Runs inside the
  # SocialwareSession GenServer (per-session serialized), so max+1 has no
  # concurrent writer; the (session_uri, committed_seq) unique index is a
  # let-it-crash backstop.
  defp assign_committed_seq(%SettlementRecord{turn_id: turn_id, session_uri: session_uri} = settlement) do
    case Repo.get_by(CustomerOutbox, turn_id: turn_id) do
      nil ->
        # No outbox row for this settlement (e.g. a settlement with no delivery,
        # or a test that did not emit one) — nothing to seq. Tolerated so the
        # commit path / mark_committed_for_test never MatchError (codex rev3 MEDIUM).
        :ok

      %CustomerOutbox{committed_seq: seq} when is_integer(seq) ->
        # Already assigned — idempotent re-commit no-op.
        :ok

      %CustomerOutbox{} ->
        next =
          (Repo.one(
             from(o in CustomerOutbox,
               where: o.session_uri == ^session_uri and not is_nil(o.committed_seq),
               select: max(o.committed_seq)
             )
           ) || 0) + 1

        {1, _} =
          from(o in CustomerOutbox, where: o.turn_id == ^turn_id)
          |> Repo.update_all(
            set: [committed_seq: next, surface_version: settlement.target_surface_version]
          )

        :ok
    end
  end

  @doc """
  P2.5b — one-time idempotent backfill (called by the migration): assign
  committed_seq + surface_version to EXISTING committed outbox rows whose
  committed_seq IS NULL. Per session, numbers rows in commit order: committed_at,
  then `target_surface_version` (the page-version order — a tied committed_at
  resolves so the HIGHER version gets the HIGHER seq, so the committed_seq page
  read picks it), then turn_id. Continues from any committed_seq already present.
  Safe to re-run (touches only NULL-seq committed rows). Permanent helper (kept so
  the historical migration replays on fresh DBs). NOTE: a legacy rollback committed
  at an identical microsecond is unrecoverable from stored data; only NEW commits
  get a true commit-order seq at the boundary.
  """
  @spec backfill_committed_seq!() :: :ok
  def backfill_committed_seq! do
    rows =
      from(o in CustomerOutbox,
        join: s in SettlementRecord,
        on: s.turn_id == o.turn_id,
        where: s.status == :committed and is_nil(o.committed_seq),
        order_by: [
          asc: o.session_uri,
          asc: s.committed_at,
          asc: coalesce(s.target_surface_version, 0),
          asc: o.turn_id
        ],
        select: %{
          turn_id: o.turn_id,
          session_uri: o.session_uri,
          target_surface_version: s.target_surface_version
        }
      )
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.session_uri)
    |> Enum.each(fn {session_uri, session_rows} ->
      start =
        (Repo.one(
           from(o in CustomerOutbox,
             where: o.session_uri == ^session_uri and not is_nil(o.committed_seq),
             select: max(o.committed_seq)
           )
         ) || 0)

      session_rows
      |> Enum.with_index(start + 1)
      |> Enum.each(fn {row, seq} ->
        {1, _} =
          from(o in CustomerOutbox, where: o.turn_id == ^row.turn_id)
          |> Repo.update_all(set: [committed_seq: seq, surface_version: row.target_surface_version])
      end)
    end)

    :ok
  end
```

> Also update `mark_committed_for_test/1` (the public full-commit test helper, `settlement.ex:131-143`) so it ALSO assigns the cursor + surface_version, faithful to the real commit path: after its `update_all(set: [status: :committed, committed_at: …])`, call `assign_committed_seq(get_record)` where `get_record` is the `%SettlementRecord{}` (re-fetch via `get/1` to get `target_surface_version`). Keep its return shape (`get(turn_id)`). Tests that manually construct a pending settlement + outbox row then commit it use ONLY `mark_committed_for_test/1` (it now does status + subwrites + seq + surface_version) — no separate seq helper is needed/exposed.

- [ ] **Step 4: NOW run the migration (codex rev5 — helper now exists)**

The Task 1 migration calls `Settlement.backfill_committed_seq!/0`, which exists as of this Task. Run it against the TEST DB:
Run: `MIX_ENV=test mix ecto.migrate 2>&1 | tail -15`
Expected: applies cleanly (fresh test DB → backfill no-op). NEVER run against dev/prod.

- [ ] **Step 4b: Run the cursor tests to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_cursor_test.exs -v 2>&1 | tail -20`
Expected: PASS — seq=1,2 in commit order; replay-since; pending invisible + late commit gets seq 3 (not skipped); upgrade-surface_version; re-commit no-op; tie; rollback; backfill.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_cursor_test.exs
git commit -m "feat(socialware/p2.5b): assign commit-order committed_seq atomically at the commit boundary

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `CustomerFeed.committed_deliveries_since/2` + `latest_cursor/1`

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`

(The cursor tests in Task 3 already exercise these — implement to make them pass. Order Task 4 BEFORE Task 3 Step 4's run, or implement both then run; the plan lists them separately for clarity but they are one red→green cycle.)

- [ ] **Step 1: Implement the replay primitives**

Add to `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex` (after `history/2`, before `approved_attachment?/2`). `import Ecto.Query`, `alias …CustomerOutbox`, `alias EzagentCore.Repo` — `CustomerOutbox` is NOT yet aliased in this module (P2.5a added `SettlementRecord`); add it:

```elixir
  # (extend the existing alias line)
  alias Ezagent.Socialware.{CustomerAuth, CustomerOutbox, SettlementRecord}
```

```elixir
  @doc """
  P2.5b — durable, cursor-addressable replay of committed customer deliveries.
  Returns committed outbox rows with `committed_seq > cursor` (ascending), each
  `%{cursor, turn_id, message_ids, surface_version}`. `committed_seq` is assigned
  at the commit boundary in commit order, so this never skips a late
  out-of-order commit. The durable source the P3 ExternalAdapter replays from;
  the PubSub `{:customer_delivery}` event is only an advisory wake-up.
  """
  @spec committed_deliveries_since(URI.t(), integer()) :: [
          %{cursor: integer(), turn_id: String.t(), message_ids: [String.t()], surface_version: integer() | nil}
        ]
  def committed_deliveries_since(%URI{} = session_uri, cursor) when is_integer(cursor) do
    session_str = URI.to_string(session_uri)

    from(o in CustomerOutbox,
      where: o.session_uri == ^session_str and not is_nil(o.committed_seq) and o.committed_seq > ^cursor,
      order_by: [asc: o.committed_seq],
      select: %{
        cursor: o.committed_seq,
        turn_id: o.turn_id,
        message_ids: o.message_ids,
        surface_version: o.surface_version
      }
    )
    |> Repo.all()
  end

  @doc "P2.5b — the highest committed-delivery cursor for a session (0 if none)."
  @spec latest_cursor(URI.t()) :: integer()
  def latest_cursor(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    from(o in CustomerOutbox,
      where: o.session_uri == ^session_str and not is_nil(o.committed_seq),
      select: max(o.committed_seq)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end
```

- [ ] **Step 1b: Unify the customer PAGE projection onto `committed_seq` (codex rev2 HIGH)**

P2.5a's `committed_surface_version/1` ordered by `s.committed_at desc, s.turn_id desc`. With fast commits sharing a `:utc_datetime_usec` and **non-padded** turn ids (`#turn-9` vs `#turn-10`), that lexicographic tiebreak can pick an OLDER turn — so the page projection and the `committed_seq` cursor replay can disagree. Make the page read from the SAME commit-order source as replay. Replace `committed_surface_version/1` (added in P2.5a) with an outbox-`committed_seq` read (the join to `SettlementRecord` is no longer needed — `committed_seq != nil` ⟺ committed):

```elixir
  # P2.5b — the committed page version = the latest page-bearing COMMITTED
  # delivery, ordered by the SAME commit-order cursor (committed_seq) that
  # committed_deliveries_since/2 replays — so the page projection and the durable
  # cursor can never disagree (codex rev2 HIGH: committed_at ties + non-padded
  # turn_id lexicographic order could otherwise pick an older turn).
  defp committed_surface_version(session_uri) do
    session_str = URI.to_string(session_uri)

    from(o in CustomerOutbox,
      where:
        o.session_uri == ^session_str and not is_nil(o.committed_seq) and
          not is_nil(o.surface_version),
      order_by: [desc: o.committed_seq],
      limit: 1,
      select: o.surface_version
    )
    |> Repo.one()
  end
```

After this, `SettlementRecord` may be unused in `customer_feed.ex` — if so, drop it from the alias to satisfy `--warnings-as-errors` (confirm with a compile). The alias becomes `alias Ezagent.Socialware.{CustomerAuth, CustomerOutbox}`.

- [ ] **Step 2: Compile + run the cursor tests (red→green with Task 3)**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_cursor_test.exs 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex
git commit -m "feat(socialware/p2.5b): CustomerFeed.committed_deliveries_since/2 + latest_cursor/1 (cursor replay)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Regression + arch gate

- [ ] **Step 1: Full socialware suite + the existing settlement/outbox tests**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -8`
Expected: 0 failures. The existing `outbox_test.exs` + any `mark_committed_for_test/1` users still pass (the helper now also assigns the seq — additive). The P2.5a page-gate tests are unaffected (`customer_page/1` reads the settlement, not the outbox).

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

1. **Cursor correctness (the whole point):** `committed_seq` assigned ONLY at commit, in commit order, per session. `not is_nil(committed_seq)` ⟺ committed. A pending row (NULL) is invisible; on commit it gets `max+1` (higher than all prior) → never skipped. The pending-then-late-commit test proves the rev2 hazard is gone by construction.
2. **Serialization assumption:** `commit_after_pointer/2` runs inside the single `SocialwareSession` GenServer → per-session commits serialized → `max+1` race-free. The `(session_uri, committed_seq)` unique index is a let-it-crash backstop, not a correctness crutch. Stated explicitly.
3. **Idempotent re-commit — FULL no-op (codex rev1 HIGH-2):** `commit_after_pointer/2` returns early (no `status`/`committed_at`/`committed_seq` rewrite) when the settlement is already `:committed`. This is what keeps the durable cursor order and the P2.5a `customer_page/1` projection (latest by `committed_at desc`) from disagreeing — a delayed re-commit of an older turn cannot roll the page back. Regression: commit t1, t2, re-commit t1 → t1.committed_at unchanged, page stays t2.
4. **Upgrade-safe + surface_version at commit (codex rev1 HIGH-1):** the migration backfills existing committed rows (per-session, commit-order). For a row that was PENDING at deploy (committed_seq + surface_version both NULL), the commit boundary's `assign_committed_seq/1` sets BOTH `committed_seq` AND `surface_version` (from `settlement.target_surface_version`) — so a committed delivery never has a cursor without its page version. Regression: pre-migration-shaped pending row (nil surface_version) → commit → replay returns target_surface_version. New columns nullable; pending rows stay NULL → invisible.
4a. **Rollback-correct (codex rev4 HIGH):** the page reads the max-`committed_seq` page-bearing outbox row's `surface_version` — i.e. it follows COMMIT ORDER, so a rollback (a later commit re-approving an older retained version) correctly makes the page that older version. A `max(version)` projection would be wrong here. Regression: commit v2, then commit a rollback to v1 → page is v1.
4c. **Backfill correctness (codex rev3 HIGH):** `backfill_committed_seq!/0` numbers legacy NULL-seq committed rows per session by `committed_at`, then `target_surface_version` (NOT raw turn_id — `#turn-9` would lexically beat `#turn-10`), then turn_id; and copies `surface_version`. Regression: two legacy committed rows sharing `committed_at` with adversarial turn ids → the higher version gets the higher seq. `assign_committed_seq/1` + `backfill` tolerate a missing outbox row (no MatchError — codex rev3 MEDIUM).
4b. **One commit-order source for page AND cursor (codex rev2 HIGH):** `customer_page/1`'s `committed_surface_version/1` is re-pointed from `SettlementRecord.committed_at desc, turn_id desc` (which ties on equal `:utc_datetime_usec` + non-padded turn_id lexicographic order, possibly picking an older turn) onto the outbox `committed_seq desc` — the exact order `committed_deliveries_since/2` replays. Page and cursor can no longer disagree. Regression: 10 turns, force turn-9 + turn-10 to share `committed_at`, assert page == version-10 (committed_seq 10), not version-9.
5. **Scope:** durable-source only. Post-parent-turn-commit ordering (rev4 HIGH) = P2.5c; #44 wire-schema folds into P3 prep. P2.5b DOES adjust `committed_surface_version/1` (P2.5a) — necessary to keep page+cursor consistent (4b).
6. **No core change:** only `ezagent_core/priv/repo/migrations` (column adds + backfill) + socialware library. Blast radius inside socialware.
7. **Placeholder scan:** the migration filename `<next>` must be resolved to a concrete timestamp in Task 1 Step 1. No other placeholders.

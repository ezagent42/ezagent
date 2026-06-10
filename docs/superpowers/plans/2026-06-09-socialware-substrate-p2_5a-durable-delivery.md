# Socialware Substrate P2.5a — Customer Page Commit-Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (project invariant `feedback_subagent_must_load_project_skills`).

**Goal:** Close the customer **page leak**: render the customer page from the **committed** surface version (recorded in the outbox and gated on `settlement.status == :committed`), never from the live `:surface.approved` pointer — which `turn.settle` advances via `:approve` BEFORE `:commit_settlement`, so a refetch in that window leaks an approved-but-uncommitted page.

**Architecture:** The narrowest correct slice of spec §6 P2.5 — **page commit-gating**, symmetric with the message gate that already works (`MessageStore.committed_customer_visible/2` joins `socialware_settlements` WHERE `status == "committed"`). The outbox gains a `surface_version` column recording WHICH surface version the settlement committed; `CustomerFeed.customer_page/1` reads the latest committed delivery's `surface_version` (outbox JOIN settlements WHERE committed) and renders THAT version's tree from the immutable `:surface.versions` map. No `ezagent_core` library change. **The cursor-addressable replay primitive (`committed_deliveries_since`) is explicitly DEFERRED to P2.5b** — its correctness depends on commit-ordering: an `id` cursor allocated at insert (pre-commit) can permanently skip an out-of-order-committed row (codex P2.5a rev2 CRITICAL). P2.5b makes the outbox insert + status flip atomic (id == commit order) and is where the correct commit-order cursor is introduced. Building the cursor here, before commit-ordering is sound, is the "don't migrate a consumer onto a signal before its correct form exists" anti-pattern (spec ANTI-PATTERNS).

**Tech Stack:** Elixir 1.19 / OTP 27, umbrella (`apps/ezagent_domain_socialware`, `apps/ezagent_core` migration only), Ecto (PostgreSQL + SQLite via exqlite — plain `add` column, portable), ExUnit. Run mix from the umbrella root with `MIX_ENV=test`.

**SAFETY (project invariants):** Migrations run ONLY against the **test DB** here (`MIX_ENV=test mix ecto.migrate`). NEVER run `mix ecto.migrate` against the live dev/prod DB (`feedback_destructive_migration_anti_pattern`). This migration is a non-destructive `add :surface_version` column (no table rebuild, no PK change, no data loss) — safe, but still flag any non-test migration to the operator.

---

## Background — grounded current state

**Current delivery pipeline (read before touching):**
- `Ezagent.Socialware.Settlement.commit_after_pointer/2` (`apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex:96-129`) — confirms the approved pointer, calls `emit_outbox_once/1` (idempotent `Repo.insert_all` on `CustomerOutbox`, `on_conflict: :nothing, conflict_target: :turn_id`) **then** `Repo.update_all(set: [status: :committed])`, **then** broadcasts `{:customer_delivery, …}`. NOTE: the outbox row is inserted BEFORE the status flip — so an outbox row can exist while its settlement is still `:pending` (partial-commit window). Any committed read MUST gate on `status == :committed`, not the mere existence of the outbox row.
- `emit_outbox_once/1` (`settlement.ex:161-190`) writes `%{turn_id, session_uri, workspace_uri, message_ids, emitted_at}` — **no surface version**.
- `Ezagent.Socialware.CustomerOutbox` (`apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex`) — `@primary_key {:turn_id, :string, []}`, fields `session_uri, workspace_uri, message_ids, emitted_at`.
- `Ezagent.Socialware.SettlementRecord` (`.../settlement_record.ex`) — `socialware_settlements`, PK `turn_id`, `target_surface_version :integer`, `status` is `Ecto.Enum, values: [:pending, :committed]`, `committed_at :utc_datetime_usec`.
- `Ezagent.Socialware.CustomerFeed.snapshot/2` (`customer_feed.ex:19-31`) → `%{messages: MessageStore.committed_customer_visible(session, 100), page: customer_page(session)}`.
- `CustomerFeed.customer_page/1` (`customer_feed.ex:157-162`) → `Surface.customer_tree(live :surface slice)` — **THE PAGE LEAK**: renders `surface.approved`'s tree, which `turn.settle` advances (`:approve`) before `:commit_settlement`.
- `MessageStore.committed_customer_visible/2` (`apps/ezagent_core/lib/ezagent/message_store.ex:220-240`) — already commit-gated: joins `socialware_settlements` WHERE `s.status == "committed"` AND `m.visibility == :customer_visible`. **Messages are already correct.**
- `Ezagent.Behavior.Surface` (`apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`) — `customer_tree(%{approved: nil}) -> nil`; `customer_tree(%{approved: v} = s) -> version_tree(v, s)`; private `version_tree/2`. The `:surface` slice retains ALL versions in `surface.versions` (immutable append; `create/1 -> %{versions: %{}, approved: nil, version_seq: 0}`), so an older committed version is still renderable.
- `Turn.settlement_attrs/3` (`turn.ex:335-346`) sets `target_surface_version: result.version`; `Settlement.begin/1` persists it on the record. So `settlement.target_surface_version` is non-nil exactly when the turn produced a page version, nil when only messages settle.

**The gap P2.5a closes:** the page leak. Fix: record the committed surface version in the outbox, and render the page from the latest COMMITTED delivery's version (status-gated), not the live approved pointer.

**Out of scope (deferred):**
- **Cursor-addressable replay (`committed_deliveries_since`, monotonic delivery cursor)** → **P2.5b**, after the commit-ordering fix makes a commit-order cursor correct (codex rev2 CRITICAL: a pre-commit-allocated id cursor can skip an out-of-order-committed row forever).
- **Post-parent-turn-commit ordering** (settlement casts firing before the parent Turn slice durably commits; rev4 HIGH) + **atomic outbox/commit** + **parent-commit-rollback test** + **wire-schema #44** → **P2.5b**.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/ezagent_core/priv/repo/migrations/20260618000600_socialware_outbox_surface_version.exs` | Create | `alter table(:socialware_customer_outbox) add :surface_version, :integer` (non-destructive). |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex` | Modify | Add `surface_version :integer` field (PK stays `turn_id`). |
| `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex` | Modify | Add `tree_for_version/2` (public) — render a SPECIFIC version's tree (not the live `approved` pointer). |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex` | Modify | `emit_outbox_once/1` writes `surface_version: settlement.target_surface_version`. |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex` | Modify | `customer_page/1` renders the latest COMMITTED delivery's `surface_version` (outbox JOIN settlements WHERE status==:committed), not the live approved pointer. |
| `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs` | Create | committed-page test + leak test (approve, no commit) + partial-commit gate test (outbox row present, settlement pending) + wake-up-loss test (commit, no broadcast → snapshot still has page). |

No `ezagent_core` library changes (migration only).

---

## Task 1: Migration — outbox `surface_version` column

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260618000600_socialware_outbox_surface_version.exs`

- [ ] **Step 1: Write the migration**

The version `20260618000600` is AFTER `20260618000400` (which creates the table). Non-destructive `add`.

```elixir
defmodule EzagentCore.Repo.Migrations.SocialwareOutboxSurfaceVersion do
  use Ecto.Migration

  # P2.5a — record the COMMITTED surface (page) version on each customer-delivery
  # outbox row so the customer page is rendered from the committed version, never
  # the live approved-but-uncommitted :surface pointer. Non-destructive add;
  # nil for deliveries that settle messages only (no page version).
  def change do
    alter table(:socialware_customer_outbox) do
      add :surface_version, :integer
    end
  end
end
```

- [ ] **Step 2: Run the migration against the TEST DB only**

Run: `MIX_ENV=test mix ecto.migrate 2>&1 | tail -10`
Expected: applies cleanly; `socialware_customer_outbox` gains a nullable `surface_version` column. (NEVER run against dev/prod — `feedback_destructive_migration_anti_pattern`.)

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/20260618000600_socialware_outbox_surface_version.exs
git commit -m "feat(socialware/p2.5a): outbox surface_version column migration

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `CustomerOutbox` schema — `surface_version` field

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex`

- [ ] **Step 1: Add the field**

Edit the file to add `surface_version`:

```elixir
defmodule Ezagent.Socialware.CustomerOutbox do
  use Ecto.Schema

  @primary_key {:turn_id, :string, []}

  schema "socialware_customer_outbox" do
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:message_ids, {:array, :string}, default: [])
    # P2.5a — the COMMITTED page version this delivery carries (nil = no page,
    # messages only). Read back via CustomerFeed only when the owning settlement
    # is :committed (the outbox row is written BEFORE the status flip).
    field(:surface_version, :integer)
    field(:emitted_at, :utc_datetime_usec)
  end
end
```

- [ ] **Step 2: Compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tail -10`
Expected: compiles clean.

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex
git commit -m "feat(socialware/p2.5a): CustomerOutbox surface_version field

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `Surface.tree_for_version/2` — render a specific committed version

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs` (existing — add a describe block)

- [ ] **Step 1: Write the failing test**

Add to `apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs`, after the last existing test, before the final `end`:

```elixir
  describe "tree_for_version/2" do
    test "returns the tree for an explicit version regardless of the approved pointer" do
      surface = %{
        versions: %{
          1 => %{tree: %{type: "text", props: %{text: "v1"}}},
          2 => %{tree: %{type: "text", props: %{text: "v2"}}}
        },
        approved: 2
      }

      assert Ezagent.Behavior.Surface.tree_for_version(surface, 1) ==
               %{type: "text", props: %{text: "v1"}}

      assert Ezagent.Behavior.Surface.tree_for_version(surface, 2) ==
               %{type: "text", props: %{text: "v2"}}
    end

    test "returns nil for a missing version or nil version" do
      surface = %{versions: %{1 => %{tree: %{type: "text"}}}, approved: 1}
      assert Ezagent.Behavior.Surface.tree_for_version(surface, 99) == nil
      assert Ezagent.Behavior.Surface.tree_for_version(surface, nil) == nil
      assert Ezagent.Behavior.Surface.tree_for_version(%{}, 1) == nil
    end
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs -v 2>&1 | tail -15`
Expected: FAIL — `function Ezagent.Behavior.Surface.tree_for_version/2 is undefined`.

- [ ] **Step 3: Implement `tree_for_version/2`**

Edit `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`. After the `def customer_tree(_surface), do: nil` line and before `@spec latest_version`, insert:

```elixir
  @doc """
  P2.5a — render a SPECIFIC version's tree, independent of the live `approved`
  pointer. The committed customer page is rendered from the version recorded in
  the committed outbox (NOT `surface.approved`, which may have advanced past the
  last committed delivery). Returns `nil` for a missing/nil version.
  """
  @spec tree_for_version(map(), integer() | nil) :: map() | nil
  def tree_for_version(_surface, nil), do: nil

  def tree_for_version(%{versions: versions}, version) when is_map(versions) do
    case Map.fetch(versions, version) do
      {:ok, %{tree: tree}} -> tree
      _ -> nil
    end
  end

  def tree_for_version(_surface, _version), do: nil
```

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs -v 2>&1 | tail -15`
Expected: PASS — existing Surface tests + the two new ones.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs
git commit -m "feat(socialware/p2.5a): Surface.tree_for_version/2 — render a specific committed version

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Record the committed surface version in the outbox

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs` (create; expanded in Task 5)

- [ ] **Step 1: Create the durable-delivery test file with the seeding harness + first test**

```elixir
defmodule Ezagent.Socialware.CustomerDeliveryDurableTest do
  @moduledoc """
  P2.5a — the customer PAGE is commit-gated: the outbox records the committed
  surface version; the page is rendered from the committed version (never the
  live approved-but-uncommitted slice); a pending settlement's outbox row is not
  exposed; dropping the wake-up still delivers via the durable snapshot.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.{CustomerFeed, CustomerOutbox}
  alias EzagentCore.Repo

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "p2-5a-#{System.unique_integer([:positive])}"
    )
  end

  defp agent_uri(name), do: Ezagent.URI.entity(:team_alpha, :agent, name)

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: target(session_uri, behavior, action),
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

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp spawn_session do
    uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(uri))
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: uri})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  # Issue a valid customer-feed token (Phoenix.Token-signed over
  # {session_uri, workspace_uri}; CustomerFeed.snapshot/2 -> authorize/3 accepts
  # it — verified against customer_auth.ex:12-42).
  defp test_token(session_uri) do
    {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(session_uri)
    Ezagent.Socialware.CustomerAuth.issue_token(session_uri, workspace_uri)
  end

  # Full turn: open -> dispatch -> deliver(page) -> compose -> settle
  # (auto-approve + commit). Returns the turn_id; waits for the outbox row.
  defp run_turn(session_uri, page_tree) do
    {:ok, %{turn_id: turn_id}} =
      dispatch(session_uri, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    {:ok, _} =
      dispatch(session_uri, :turn, :dispatch, %{
        turn_id: turn_id,
        subtasks: [%{id: :page, mention: agent_uri("page"), prompt: "render"}]
      })

    {:ok, _} =
      dispatch(session_uri, :turn, :deliver, %{
        turn_id: turn_id,
        subtask_id: :page,
        card_ref: %{kind: :page, tree: page_tree}
      })

    {:ok, %{version: _version}} =
      dispatch(session_uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

    {:ok, %{status: :settled}} =
      dispatch(session_uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn -> Repo.get_by(CustomerOutbox, turn_id: turn_id) != nil end)
    turn_id
  end

  describe "outbox records the committed surface version" do
    test "the outbox row carries the surface_version that was approved+committed" do
      uri = spawn_session()
      turn_id = run_turn(uri, %{type: "text", props: %{text: "committed page"}})

      outbox = Repo.get_by(CustomerOutbox, turn_id: turn_id)
      assert outbox.surface_version == 1
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -20`
Expected: FAIL — `outbox.surface_version == 1` fails (currently `nil`; `emit_outbox_once/1` does not write it).

- [ ] **Step 3: Write the surface_version into the outbox**

Edit `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex`. In `emit_outbox_once/1`, add `surface_version` to the inserted map:

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
      1 ->
        {:ok, _settlement} = mark_subwrite(settlement, @outbox_emitted)
        {:ok, true}

      0 ->
        {:ok, _settlement} = mark_subwrite(settlement, @outbox_emitted)
        {:ok, false}
    end
  end
```

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -15`
Expected: PASS — `outbox.surface_version == 1`.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs
git commit -m "feat(socialware/p2.5a): record committed surface_version in the outbox

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Commit-gate the customer page

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs`

- [ ] **Step 1: Write the failing tests**

Add these `describe` blocks to the durable-delivery test (created in Task 4), before the final `end`:

```elixir
  describe "committed page is rendered from the committed version" do
    test "after commit, snapshot.page is the committed surface version tree" do
      page_tree = %{type: "text", props: %{text: "committed page"}}
      uri = spawn_session()
      token = test_token(uri)
      _turn_id = run_turn(uri, page_tree)

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == page_tree
    end
  end

  describe "page commit-gating (leak test)" do
    test "snapshot exposes NEITHER page NOR messages when surface is approved but settlement not committed" do
      page_tree = %{type: "text", props: %{text: "draft page"}}
      uri = spawn_session()
      token = test_token(uri)

      # open -> dispatch -> deliver -> compose, then APPROVE the surface WITHOUT
      # committing the settlement (the pre-fix leak path).
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

      {:ok, %{version: version}} =
        dispatch(uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

      {:ok, _} = dispatch(uri, :surface, :approve, %{version: version})

      wait_until(fn ->
        {:ok, surface} = Ezagent.Kind.get_slice(uri, :surface)
        surface.approved == version
      end)

      assert Repo.get_by(CustomerOutbox, turn_id: turn_id) == nil

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == nil, "approved-but-uncommitted page must NOT leak"
      assert snapshot.messages == []
    end
  end

  describe "partial-commit gate (codex CRITICAL): outbox row present but settlement pending" do
    test "a PENDING settlement's outbox row is NOT rendered as the page" do
      page_tree = %{type: "text", props: %{text: "pending page"}}
      uri = spawn_session()
      token = test_token(uri)
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)

      # Make the surface hold an APPROVED v1 (so the version tree IS renderable
      # if the gate were broken): open -> dispatch -> deliver -> compose -> approve.
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

      {:ok, %{version: version}} =
        dispatch(uri, :turn, :compose, %{turn_id: turn_id, result_refs: []})

      {:ok, _} = dispatch(uri, :surface, :approve, %{version: version})

      # PENDING settlement + an outbox row referencing it — the partial-commit
      # window (emit_outbox_once ran, status flip to :committed has NOT).
      {:ok, _} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: turn_id,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: version
        })

      {:ok, _} =
        Repo.insert(%CustomerOutbox{
          turn_id: turn_id,
          session_uri: URI.to_string(uri),
          workspace_uri: URI.to_string(workspace_uri),
          message_ids: [],
          surface_version: version,
          emitted_at: DateTime.utc_now()
        })

      # Settlement still :pending -> the join-on-status==:committed gate hides it.
      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == nil
    end
  end

  describe "wake-up loss" do
    test "a committed page is visible via the durable snapshot even if no PubSub event was delivered" do
      page_tree = %{type: "text", props: %{text: "delivered despite lost wake-up"}}
      uri = spawn_session()
      token = test_token(uri)

      # run_turn commits; we never subscribe to / receive the {:customer_delivery}
      # event — the wake-up is "lost". A fresh snapshot (== reconnect) still has it.
      _turn_id = run_turn(uri, page_tree)

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == page_tree
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -25`
Expected: FAIL — the leak test + partial-commit test fail because `customer_page/1` reads the live approved pointer (renders the page with no committed settlement).

- [ ] **Step 3: Commit-gate `customer_page/1`**

Edit `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`:

(a) Add at the top, after the existing aliases:

```elixir
  import Ecto.Query
  alias Ezagent.Socialware.{CustomerOutbox, SettlementRecord}
  alias EzagentCore.Repo
```

(b) Replace `customer_page/1` (currently `customer_feed.ex:157-162`):

```elixir
  # P2.5a — render the customer page from the COMMITTED surface version, NOT the
  # live `:surface.approved` pointer. `turn.settle` dispatches `:approve`
  # (advancing the live pointer) BEFORE `:commit_settlement` writes the outbox +
  # flips status, so reading the live pointer leaks an approved-but-uncommitted
  # page. The committed version is the latest outbox delivery whose settlement is
  # :committed (the outbox row is written BEFORE the status flip — codex
  # CRITICAL — so we MUST gate on status, mirroring committed_customer_visible).
  defp customer_page(session_uri) do
    case committed_surface_version(session_uri) do
      nil ->
        nil

      version ->
        case Ezagent.Kind.get_slice(session_uri, :surface) do
          {:ok, surface} -> Surface.tree_for_version(surface, version)
          _ -> nil
        end
    end
  end

  # The surface_version of the most-recently-COMMITTED outbox delivery that
  # carries a page (surface_version not null). Joins SettlementRecord and
  # requires status == :committed. Ordered by the settlement commit time
  # (committed_at) descending. nil → no committed page.
  defp committed_surface_version(session_uri) do
    session_str = URI.to_string(session_uri)

    from(o in CustomerOutbox,
      join: s in SettlementRecord,
      on: s.turn_id == o.turn_id,
      where:
        o.session_uri == ^session_str and s.status == :committed and
          not is_nil(o.surface_version),
      order_by: [desc: s.committed_at, desc: o.turn_id],
      limit: 1,
      select: o.surface_version
    )
    |> Repo.one()
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -20`
Expected: PASS — committed-page, leak, partial-commit, wake-up-loss tests all green.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs
git commit -m "feat(socialware/p2.5a): commit-gate the customer page (render committed surface version)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Regression + arch gate

**Files:** none (verification-only). Per `feedback_completion_requires_invariant_test`, the leak + partial-commit + wake-up-loss tests are the architectural gate proving P2.5a's page-commit-gating goal; this task confirms no regression.

- [ ] **Step 1: Full socialware + web + core message suites**

Run (each 0 failures):
```bash
MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -8
MIX_ENV=test mix test apps/ezagent_web/test 2>&1 | tail -8
MIX_ENV=test mix test apps/ezagent_core/test/ezagent/message_store_test.exs 2>&1 | tail -8
```
Expected: all green. If an EXISTING socialware test asserted the old live-approved-pointer page (the leak), it was asserting buggy behavior — update it to the committed-gate semantics with a comment (and note it in the commit). Confirm `turn_customer_feed_integration_test.exs` (the turn→feed integration) still passes; its turns go through full settle+commit so the committed page should match.

- [ ] **Step 2: Arch fitness gates**

Run (each exit 0):
```bash
MIX_ENV=test mix compile --warnings-as-errors --force 2>&1 | tail -5
MIX_ENV=test mix ezagent.arch.scan 2>&1 | grep -E "FAIL|gt_1000"
MIX_ENV=test mix ezagent.check_invariants 2>&1 | tail -4
```
Expected: no FAIL; `oversized_modules_gt_1000: count=0`; invariants clean.

- [ ] **Step 3: Final commit (only if test-fixture updates were needed)**

```bash
git add -A
git commit -m "test(socialware/p2.5a): update fixtures to committed-page gate semantics

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (run before handing to codex)

1. **Spec coverage:** P2.5a covers the socialware-local **page commit-gating** sub-point of spec §6 P2.5 (record committed surface version + render the page from it, status-gated). The **cursor-addressable replay** and **post-parent-turn-commit ordering** + **#44 wire-schema** are explicitly DEFERRED to **P2.5b** — intentional, because the cursor's correctness depends on the commit-ordering fix (codex rev2 CRITICAL: a pre-commit id cursor can skip an out-of-order-committed row).
2. **Placeholder scan:** none. `test_token/1` uses the verified real API `CustomerAuth.issue_token/3`.
3. **Type consistency:** `surface_version` integer-or-nil across migration, schema, settlement write (`settlement.target_surface_version`), and `committed_surface_version/1` (`not is_nil(o.surface_version)`). `status == :committed` compares the `Ecto.Enum` atom (consistent with the schema's `values: [:pending, :committed]`).
4. **Ambiguity — page version selection:** `committed_surface_version/1` picks the committed delivery with the latest `committed_at` (tiebreak by turn_id), filtered to `surface_version not null` (a messages-only commit must not clear a previously-committed page). Made explicit in the query.
5. **No core change:** only `ezagent_core/priv/repo/migrations` (a column add) — no `ezagent_core` library code, keeping the blast radius inside socialware.

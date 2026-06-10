# Socialware Substrate P2.5a — Durable Customer-Delivery (outbox cursor + page commit-gating) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (project invariant `feedback_subagent_must_load_project_skills`).

**Goal:** Make the socialware customer delivery a durable, cursor-addressable, commit-gated source of truth: the committed outbox records BOTH the committed message ids AND the committed surface (page) version, is addressable by a monotonic cursor for replay, and the customer PAGE is rendered from the committed surface version — never the live approved-but-not-committed `:surface` slice.

**Architecture:** This is the **socialware/web-local** half of spec §6 P2.5 (the durable-source + page commit-gating + cursor-replay contract). It does NOT touch `ezagent_core` — the post-parent-turn-commit ordering fix (rev4 HIGH) is the separate **P2.5b** plan. Here: extend `socialware_customer_outbox` with a surrogate monotonic `id` cursor + a `surface_version` column; `Settlement.commit_after_pointer` writes the committed surface version transactionally with the outbox row; `CustomerFeed.customer_page/1` renders the committed surface version (looked up from the outbox) instead of the live `:surface` approved pointer; add `CustomerFeed.committed_deliveries_since/2` as the cursor-addressable durable replay primitive (P3's ExternalAdapter consumes it). The CustomerChannel keeps its existing full-gated-snapshot-on-signal shape (which is already durable-replay for messages); the page now rides the same commit gate.

**Tech Stack:** Elixir 1.19 / OTP 27, umbrella (`apps/ezagent_domain_socialware`, `apps/ezagent_web`, `apps/ezagent_core` migrations only), Ecto (PostgreSQL + SQLite via exqlite — migration uses a portable surrogate `:id` PK), ExUnit. Run mix from the umbrella root with `MIX_ENV=test`.

**SAFETY (project invariants):** Migrations run ONLY against the **test DB** in this plan (`MIX_ENV=test mix ecto.migrate`). NEVER run `mix ecto.migrate` against the live dev/prod DB (`feedback_destructive_migration_anti_pattern`). The outbox table rebuild (PK change) drops + recreates `socialware_customer_outbox`; this is acceptable because the outbox is an ephemeral delivery-staging table on a pre-production feature, and all E2E runs on a fresh-seeded disposable stack (`feedback_e2e_in_docker_fresh_seed`). Flag this rebuild to the operator before any non-test environment migration.

---

## Background — grounded current state

**Current delivery pipeline (read before touching):**
- `Ezagent.Socialware.Settlement.commit_after_pointer/2` (`apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex:96-129`) — confirms the approved pointer, calls `emit_outbox_once/1` (idempotent `Repo.insert_all` on `CustomerOutbox`, `on_conflict: :nothing, conflict_target: :turn_id`), marks `status: :committed`, then `Phoenix.PubSub.broadcast({:customer_delivery, %{message_ids: ...}})`.
- `emit_outbox_once/1` (`settlement.ex:161-190`) writes `%{turn_id, session_uri, workspace_uri, message_ids, emitted_at}` — **no surface version**.
- `Ezagent.Socialware.CustomerOutbox` (`apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex`) — `@primary_key {:turn_id, :string, []}`, fields `session_uri, workspace_uri, message_ids, emitted_at`. **No cursor, no surface_version.**
- `Ezagent.Socialware.CustomerFeed.snapshot/2` (`customer_feed.ex:19-31`) → `%{messages: MessageStore.committed_customer_visible(session, 100), page: customer_page(session)}`.
- `CustomerFeed.customer_page/1` (`customer_feed.ex:157-162`) → `Surface.customer_tree(live :surface slice)` — **THE PAGE LEAK**: `Surface.customer_tree/1` renders `surface.approved`'s tree, but Turn settle dispatches `:approve` BEFORE `:commit_settlement`, so a refetch between them exposes the approved-but-not-committed page.
- `MessageStore.committed_customer_visible/2` (`apps/ezagent_core/lib/ezagent/message_store.ex:220-240`) — already commit-gated: joins `socialware_settlements` with `s.status == "committed"` AND `m.visibility == :customer_visible`. **Messages are already correct.**
- `EzagentWeb.Socialware.CustomerChannel` (`apps/ezagent_web/lib/ezagent_web/socialware/customer_channel.ex`) — on join: full gated `snapshot`; on `{:customer_delivery, _}`: re-fetches the full gated `snapshot` and pushes `"snapshot"`. This full-snapshot-on-signal IS durable replay for messages (it reads the committed store, not the lost event payload).
- `Ezagent.Behavior.Surface` (`apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`) — `customer_tree(%{approved: nil}) -> nil`; `customer_tree(%{approved: v} = s) -> version_tree(v, s)`; `latest_version/1`; private `version_tree/2`. The `:surface` slice retains ALL versions in `surface.versions` (immutable append; `create/1 -> %{versions: %{}, approved: nil, version_seq: 0}`).
- Outbox migration shape: `apps/ezagent_core/priv/repo/migrations/20260618000400_add_message_visibility_and_socialware_settlements.exs` (the `socialware_customer_outbox` block, PK = turn_id referencing settlements).

**The two gaps P2.5a closes:**
1. **Page leak** — `customer_page/1` reads the live approved pointer, not the committed version. Fix: record the committed surface version in the outbox at commit, and render the page from THAT version.
2. **No cursor-addressable durable source** — the outbox is keyed only by turn_id with no total order. Fix: surrogate monotonic `id` PK (portable autoincrement) + a `committed_deliveries_since/2` replay primitive.

**Out of scope (P2.5b — separate plan):** the post-parent-turn-commit ordering fix in `Ezagent.Kind.Server` (settlement casts firing before the parent Turn slice durably commits) + the parent-commit-rollback test + wire-schema regularization (#44). P2.5a makes the customer feed correct w.r.t. the EXISTING commit path; P2.5b hardens WHEN the commit path runs relative to the parent turn.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/ezagent_core/priv/repo/migrations/20260610000000_socialware_outbox_cursor_and_surface_version.exs` | Create | Rebuild `socialware_customer_outbox` with surrogate `:id` bigserial PK (the cursor) + `turn_id` unique index + new `surface_version :integer` column. |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex` | Modify | Default `:id` PK (cursor); `turn_id` becomes a plain field (unique index); add `surface_version :integer`. |
| `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex` | Modify | Add `tree_for_version/2` (public) — render a SPECIFIC version's tree (not the live `approved` pointer). |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex` | Modify | `emit_outbox_once/1` writes `surface_version: settlement.target_surface_version` transactionally with the outbox row. |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex` | Modify | `customer_page/1` renders the committed surface version (from the outbox), not the live approved pointer; add `committed_deliveries_since/2` cursor-replay primitive + `latest_cursor/1`. |
| `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs` | Create | Leak test + wake-up-loss test + cursor-replay test + page-commit-gating test. |

No `ezagent_core` library changes (migration only).

---

## Task 1: Migration — outbox surrogate cursor + surface_version

**Files:**
- Create: `apps/ezagent_core/priv/repo/migrations/20260610000000_socialware_outbox_cursor_and_surface_version.exs`

- [ ] **Step 1: Write the migration**

Create the file with this content. The rebuild is portable across PostgreSQL + SQLite (both autoincrement the default integer `:id` PK). `turn_id` keeps a unique index so `Settlement`'s `on_conflict: :nothing, conflict_target: :turn_id` idempotency is preserved.

```elixir
defmodule EzagentCore.Repo.Migrations.SocialwareOutboxCursorAndSurfaceVersion do
  use Ecto.Migration

  # P2.5a — give the customer-delivery outbox a monotonic cursor (the default
  # `:id` bigserial PK, portable across PG + SQLite) for durable replay, and a
  # `surface_version` column so the COMMITTED page version is recorded
  # transactionally with the delivery (closes the page-leak). The old table was
  # keyed by turn_id only; we rebuild it (drop + create) — the outbox is an
  # ephemeral delivery-staging table on a pre-production feature, so no data is
  # preserved. Nothing references this table (the FK direction is
  # outbox -> settlements), so the drop is safe.
  def up do
    drop table(:socialware_customer_outbox)

    create table(:socialware_customer_outbox) do
      add :turn_id,
          references(:socialware_settlements,
            column: :turn_id,
            type: :string,
            on_delete: :delete_all
          ),
          null: false

      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :message_ids, {:array, :string}, null: false
      add :surface_version, :integer
      add :emitted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:socialware_customer_outbox, [:turn_id],
             name: :socialware_customer_outbox_turn_id_index
           )

    create index(:socialware_customer_outbox, [:session_uri, :id],
             name: :socialware_customer_outbox_session_cursor_index
           )
  end

  def down do
    drop table(:socialware_customer_outbox)

    create table(:socialware_customer_outbox, primary_key: false) do
      add :turn_id,
          references(:socialware_settlements,
            column: :turn_id,
            type: :string,
            on_delete: :delete_all
          ),
          primary_key: true

      add :session_uri, :string, null: false
      add :workspace_uri, :string, null: false
      add :message_ids, {:array, :string}, null: false
      add :emitted_at, :utc_datetime_usec, null: false
    end
  end
end
```

- [ ] **Step 2: Run the migration against the TEST DB only**

Run: `MIX_ENV=test mix ecto.migrate 2>&1 | tail -15`
Expected: migration applies cleanly; `socialware_customer_outbox` rebuilt with an `id` PK. (NEVER run against dev/prod — `feedback_destructive_migration_anti_pattern`.)

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_core/priv/repo/migrations/20260610000000_socialware_outbox_cursor_and_surface_version.exs
git commit -m "feat(socialware/p2.5a): outbox surrogate cursor + surface_version migration

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `CustomerOutbox` schema — cursor PK + surface_version

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex`

- [ ] **Step 1: Rewrite the schema**

Replace the whole file with:

```elixir
defmodule Ezagent.Socialware.CustomerOutbox do
  use Ecto.Schema

  # P2.5a — the default `:id` integer PK is the monotonic delivery CURSOR used
  # for durable replay (CustomerFeed.committed_deliveries_since/2). `turn_id` is
  # a unique index (idempotency key for emit_outbox_once/1). `surface_version`
  # is the COMMITTED page version, recorded transactionally with the delivery so
  # the customer page is never read from the live approved-but-uncommitted slice.
  schema "socialware_customer_outbox" do
    field(:turn_id, :string)
    field(:session_uri, :string)
    field(:workspace_uri, :string)
    field(:message_ids, {:array, :string}, default: [])
    field(:surface_version, :integer)
    field(:emitted_at, :utc_datetime_usec)
  end
end
```

- [ ] **Step 2: Compile**

Run: `MIX_ENV=test mix compile --warnings-as-errors 2>&1 | tail -10`
Expected: compiles clean. (`@primary_key` default is `{:id, :id, autogenerate: true}` — no explicit declaration needed.)

- [ ] **Step 3: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_outbox.ex
git commit -m "feat(socialware/p2.5a): CustomerOutbox surrogate id cursor + surface_version field

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `Surface.tree_for_version/2` — render a specific committed version

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs` (existing — add a describe block)

- [ ] **Step 1: Write the failing test**

Add to `apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs`, inside the top-level `describe` area (after the last existing test, before the final `end`):

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

Edit `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`. After the `customer_tree/1` clauses (the `def customer_tree(_surface), do: nil` line) and before `@spec latest_version`, insert:

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
Expected: PASS — all existing Surface tests + the two new `tree_for_version/2` tests.

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

- [ ] **Step 1: Write the failing test (in the durable-delivery test, created here, expanded in Task 6)**

Create `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs` with the seeding harness + the first test. (Tasks 5/6 add more `test` blocks to this same file.)

```elixir
defmodule Ezagent.Socialware.CustomerDeliveryDurableTest do
  @moduledoc """
  P2.5a — the customer delivery is a durable, cursor-addressable, commit-gated
  source: the outbox records the committed surface version; the customer page is
  rendered from the committed version (never the live approved-but-uncommitted
  slice); replay works by cursor; dropping the wake-up still delivers.
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

  # Run a full turn: open -> dispatch -> deliver(page) -> compose -> settle
  # (auto-approve + commit). Returns the turn_id.
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

    wait_until(fn ->
      Repo.get_by(CustomerOutbox, turn_id: turn_id) != nil
    end)

    turn_id
  end

  describe "outbox records the committed surface version" do
    test "the outbox row carries the surface_version that was approved+committed" do
      page_tree = %{type: "text", props: %{text: "committed page"}}
      uri = spawn_session()
      turn_id = run_turn(uri, page_tree)

      outbox = Repo.get_by(CustomerOutbox, turn_id: turn_id)
      assert outbox.surface_version == 1
      assert is_integer(outbox.id)
    end
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -20`
Expected: FAIL — `outbox.surface_version == 1` fails because `emit_outbox_once/1` does not yet write `surface_version` (it is `nil`).

- [ ] **Step 3: Write the surface_version into the outbox**

Edit `apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex`. In `emit_outbox_once/1` (line ~161-190), add `surface_version` to the inserted map:

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

(`settlement.target_surface_version` is already populated by `Turn.settlement_attrs/3` → `target_surface_version: result.version` and persisted on `begin/1`.)

- [ ] **Step 4: Run to verify it passes**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -15`
Expected: PASS — `outbox.surface_version == 1` and `outbox.id` is an integer.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs
git commit -m "feat(socialware/p2.5a): record committed surface_version in the outbox

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Page commit-gating + cursor-replay primitives in `CustomerFeed`

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`

- [ ] **Step 1: Write the failing tests**

Add these `describe` blocks to `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs` (the file created in Task 4), before the final `end`:

```elixir
  describe "page commit-gating (leak test)" do
    test "snapshot exposes NEITHER page NOR messages until the settlement commits" do
      page_tree = %{type: "text", props: %{text: "draft page"}}
      uri = spawn_session()
      token = test_token(uri)

      # Drive open -> dispatch -> deliver -> compose, then APPROVE the surface
      # WITHOUT committing the settlement (skip turn.settle's commit path).
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

      # Approve the surface directly (advances the LIVE :surface.approved pointer)
      # but do NOT commit the settlement — the pre-fix leak path.
      {:ok, _} = dispatch(uri, :surface, :approve, %{version: version})

      wait_until(fn ->
        {:ok, surface} = Ezagent.Kind.get_slice(uri, :surface)
        surface.approved == version
      end)

      # No committed outbox row -> no committed delivery.
      assert Repo.get_by(CustomerOutbox, turn_id: turn_id) == nil

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == nil, "approved-but-uncommitted page must NOT leak"
      assert snapshot.messages == []
    end
  end

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

  describe "committed_deliveries_since/2 + wake-up-loss" do
    test "replays committed deliveries by cursor; later commits have higher cursors" do
      uri = spawn_session()
      t1 = run_turn(uri, %{type: "text", props: %{text: "page-1"}})
      t2 = run_turn(uri, %{type: "text", props: %{text: "page-2"}})

      all = CustomerFeed.committed_deliveries_since(uri, 0)
      assert length(all) == 2
      [d1, d2] = all
      assert d1.turn_id == t1
      assert d2.turn_id == t2
      assert d1.cursor < d2.cursor
      assert d2.surface_version == 2

      # Replay from after the first delivery returns only the second.
      after_first = CustomerFeed.committed_deliveries_since(uri, d1.cursor)
      assert Enum.map(after_first, & &1.turn_id) == [t2]
    end

    test "wake-up loss: a committed delivery is visible via the durable snapshot even if no PubSub event was delivered" do
      page_tree = %{type: "text", props: %{text: "delivered despite lost wake-up"}}
      uri = spawn_session()
      token = test_token(uri)

      # run_turn commits the settlement; we never subscribe to / deliver the
      # {:customer_delivery} PubSub event — i.e. the wake-up is "lost".
      _turn_id = run_turn(uri, page_tree)

      # A fresh snapshot (== reconnect) still returns the committed page.
      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == page_tree
    end
  end
```

Add this private helper to the test module (near `spawn_session`): a customer token for the session, issued via the exact path `CustomerFeed.snapshot/2`'s `CustomerAuth.authorize/3` verifies (`CustomerAuth.issue_token/3` signs the same `{session_uri, workspace_uri}` payload `authorize/3` checks — verified against `customer_auth.ex:12-42`):

```elixir
  # Issue a valid customer-feed token for `session_uri` (Phoenix.Token-signed
  # over {session_uri, workspace_uri}; CustomerFeed.snapshot/2 -> authorize/3
  # accepts it).
  defp test_token(session_uri) do
    {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(session_uri)
    Ezagent.Socialware.CustomerAuth.issue_token(session_uri, workspace_uri)
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -25`
Expected: FAIL — `committed_deliveries_since/2` undefined; the leak test fails because `customer_page/1` currently reads the live approved pointer (returns the page even with no committed outbox).

- [ ] **Step 3: Implement page commit-gating + the replay primitive**

Edit `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`:

(a) Add `import Ecto.Query` + `alias EzagentCore.Repo` + `alias Ezagent.Socialware.CustomerOutbox` at the top (after the existing aliases):

```elixir
  import Ecto.Query
  alias Ezagent.Socialware.CustomerOutbox
  alias EzagentCore.Repo
```

(b) Replace `customer_page/1` (currently `customer_feed.ex:157-162`) with the committed-version render:

```elixir
  # P2.5a — render the customer page from the COMMITTED surface version recorded
  # in the outbox, NOT the live `:surface.approved` pointer. `turn.settle`
  # dispatches `:approve` (advancing the live pointer) BEFORE `:commit_settlement`
  # writes the outbox, so reading the live pointer would leak an
  # approved-but-uncommitted page. With no committed delivery, the page is nil.
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

  # The surface_version of the most-recent committed outbox delivery that
  # actually carries a page (surface_version not null). nil → no committed page.
  defp committed_surface_version(session_uri) do
    session_str = URI.to_string(session_uri)

    from(o in CustomerOutbox,
      where: o.session_uri == ^session_str and not is_nil(o.surface_version),
      order_by: [desc: o.id],
      limit: 1,
      select: o.surface_version
    )
    |> Repo.one()
  end
```

(c) Add the public cursor-replay primitive + `latest_cursor/1` (after `history/2`, before `approved_attachment?/2`):

```elixir
  @doc """
  P2.5a — durable, cursor-addressable replay of committed customer deliveries.
  Returns committed outbox rows with `id > cursor` (ascending), each as
  `%{cursor, turn_id, message_ids, surface_version}`. This is the durable source
  the P3 ExternalAdapter replays from; the PubSub `{:customer_delivery}` event
  is only an advisory wake-up that triggers a replay — losing it never loses a
  delivery (the next replay/reconnect catches up).

  Authorization is the caller's responsibility for the gated routes; this is the
  raw durable read (used by adapters that have already established the session).
  """
  @spec committed_deliveries_since(URI.t(), integer()) :: [
          %{cursor: integer(), turn_id: String.t(), message_ids: [String.t()], surface_version: integer() | nil}
        ]
  def committed_deliveries_since(%URI{} = session_uri, cursor) when is_integer(cursor) do
    session_str = URI.to_string(session_uri)

    from(o in CustomerOutbox,
      where: o.session_uri == ^session_str and o.id > ^cursor,
      order_by: [asc: o.id],
      select: %{
        cursor: o.id,
        turn_id: o.turn_id,
        message_ids: o.message_ids,
        surface_version: o.surface_version
      }
    )
    |> Repo.all()
  end

  @doc "P2.5a — the highest committed-delivery cursor for a session (0 if none)."
  @spec latest_cursor(URI.t()) :: integer()
  def latest_cursor(%URI{} = session_uri) do
    session_str = URI.to_string(session_uri)

    from(o in CustomerOutbox,
      where: o.session_uri == ^session_str,
      select: max(o.id)
    )
    |> Repo.one()
    |> Kernel.||(0)
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs -v 2>&1 | tail -20`
Expected: PASS — leak test (no page/messages pre-commit), committed-page test (page == committed tree), cursor-replay test, wake-up-loss test.

- [ ] **Step 5: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex apps/ezagent_domain_socialware/test/ezagent/socialware/customer_delivery_durable_test.exs
git commit -m "feat(socialware/p2.5a): commit-gate the customer page + cursor-replay primitive

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Regression + arch gate

**Files:** none (verification-only). Per `feedback_completion_requires_invariant_test`, the leak + wake-up-loss + cursor-replay tests above are the architectural gate that proves P2.5a's durable-delivery goal; this task confirms no regression.

- [ ] **Step 1: Full socialware + web + core message suites**

Run (each 0 failures):
```bash
MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -8
MIX_ENV=test mix test apps/ezagent_web/test 2>&1 | tail -8
MIX_ENV=test mix test apps/ezagent_core/test/ezagent/message_store_test.exs 2>&1 | tail -8
```
Expected: all green. The existing socialware surface/settlement/customer-feed tests must still pass (the page now reads the committed version — confirm no existing test relied on the live-approved-pointer leak; if one does, it was asserting the buggy behavior and must be updated to the committed-gate semantics, with a comment).

- [ ] **Step 2: Arch fitness gates**

Run (each exit 0):
```bash
MIX_ENV=test mix compile --warnings-as-errors --force 2>&1 | tail -5
MIX_ENV=test mix ezagent.arch.scan 2>&1 | grep -E "FAIL|gt_1000"
MIX_ENV=test mix ezagent.check_invariants 2>&1 | tail -4
```
Expected: no FAIL; `oversized_modules_gt_1000: count=0`; invariants clean.

- [ ] **Step 3: Final commit (if any test-fixture updates were needed)**

```bash
git add -A
git commit -m "test(socialware/p2.5a): update fixtures to committed-page gate semantics

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review (run before handing to codex)

1. **Spec coverage:** P2.5a covers the spec §6 P2.5 sub-points that are socialware/web-local: durable outbox covering BOTH message ids AND committed surface version (Task 4); page commit-gating (Task 5); cursor-addressable replay + advisory-wake-up-loss resilience (Task 5). The post-parent-turn-commit ordering (rev4 HIGH) + wire-schema (#44) are explicitly deferred to **P2.5b** — flagged here so coverage is intentional, not a gap.
2. **Placeholder scan:** the only "confirm the real API" note is `test_token/1` (CustomerAuth mint) — the implementer MUST read `customer_auth.ex` for the exact mint signature before finalizing (the gated `snapshot/2` authorize path must accept the token). Everything else is concrete.
3. **Type consistency:** outbox `id` (integer cursor) used consistently in `committed_deliveries_since/2` (`o.id > cursor`), `latest_cursor/1` (`max(o.id)`), and the migration (`[:session_uri, :id]` index). `surface_version` integer-or-nil consistent across migration, schema, settlement write, and `committed_surface_version/1`.
4. **Ambiguity — page version selection:** `committed_surface_version/1` picks the MAX-id committed outbox row WITH a non-nil surface_version (a turn may commit messages without a page version → null surface_version → must not clear the page). Made explicit in the query (`not is_nil(o.surface_version)`).

# Socialware Substrate P2.5a — Customer Page Commit-Gating Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every subagent that touches `apps/**/*.ex` MUST load `Skill: ezagent-developer` + `Skill: elixir-phoenix-helper` (project invariant `feedback_subagent_must_load_project_skills`).

**Goal:** Close the customer **page leak**: render the customer page from the **committed** surface version (the latest `socialware_settlements` row with `status == :committed`), never from the live `:surface.approved` pointer — which `turn.settle` advances via `:approve` BEFORE `:commit_settlement`, so a refetch in that window leaks an approved-but-uncommitted page.

**Architecture:** The narrowest correct slice of spec §6 P2.5 — **page commit-gating**, symmetric with the message gate that already works (`MessageStore.committed_customer_visible/2` joins `socialware_settlements` WHERE `status == "committed"`). The committed page version is **already** recorded on the commit record: `SettlementRecord.target_surface_version` (set by `Turn.settlement_attrs/3`, persisted by `Settlement.begin/1`, authoritative once `status == :committed`). So `CustomerFeed.customer_page/1` reads the latest committed settlement's `target_surface_version` and renders THAT version's tree from the immutable `:surface.versions` map — **no schema change, no migration, no outbox change, upgrade-safe** (operates on existing data).

**Cold-path durability (codex P2.5a rev4 HIGH + MEDIUM).** "Durable delivery" must survive a BEAM restart / reaped session, so two reads in `CustomerFeed` are made cold-safe in this plan:
- **Surface read:** `customer_page/1` previously called `Ezagent.Kind.get_slice/2`, which returns `{:error, :not_found}` when the session process is absent (it does NOT lazy-spawn). The committed surface tree must come from the durable snapshot when the process is down. We add a `surface_slice/1` helper: try `get_slice/2` (live, fast), and on `:not_found` fall back to `Ezagent.Kind.StateRebuilder.rebuild/1` (reads `kind_snapshots`) + the public `Ezagent.Kind.normalize_slice_view/1` (the snapshot stores the two-container Lifecycle slice; `normalize_slice_view/1` flattens it exactly as `get_slice/2` does).
- **Workspace auth:** `CustomerFeed.workspace/1` previously used `Ezagent.WorkspaceRegistry.lookup/1` (volatile ETS — empty after restart → a valid token is rejected). The workspace is structural in `session://<workspace>/<template>/<name>`; switch to `Ezagent.Persistence.workspace_uri_for/1` (the same structural derivation the message gate already uses), so cold reconnects authorize.

The outbox's `surface_version` column + the cursor-addressable replay primitive (`committed_deliveries_since`) are **DEFERRED to P2.5b**: their correctness depends on the commit-ordering fix (atomic outbox-insert + status-flip → a commit-order cursor), and an `id` cursor allocated pre-commit can permanently skip an out-of-order-committed row (codex P2.5a rev2 CRITICAL). Building them here, before commit-ordering is sound, is the "don't migrate a consumer onto a signal before its correct form exists" anti-pattern (spec ANTI-PATTERNS).

**Tech Stack:** Elixir 1.19 / OTP 27, umbrella (`apps/ezagent_domain_socialware`), Ecto query (read-path only — NO migration), ExUnit. Run mix from the umbrella root with `MIX_ENV=test`.

**SAFETY:** No migration, no schema change — pure read-path + a pure-function helper. Nothing destructive; nothing touches `ezagent_core`.

---

## Background — grounded current state

**Current delivery pipeline (read before touching):**
- `Ezagent.Socialware.Settlement.commit_after_pointer/2` (`apps/ezagent_domain_socialware/lib/ezagent/socialware/settlement.ex:96-129`) — confirms the approved pointer, `emit_outbox_once/1`, then `Repo.update_all(set: [status: :committed, committed_at: committed_at])`, then broadcasts `{:customer_delivery, …}`. The status flip (and `committed_at`) is the commit boundary.
- `Ezagent.Socialware.SettlementRecord` (`.../settlement_record.ex`) — table `socialware_settlements`, PK `turn_id`, fields incl. `session_uri :string`, `target_surface_version :integer`, `status` = `Ecto.Enum, values: [:pending, :committed]`, `committed_at :utc_datetime_usec`. **`target_surface_version` is the committed page version** (nil when the turn settled messages only).
- `Turn.settlement_attrs/3` (`turn.ex:335-346`) → `target_surface_version: result.version` (the version `compose` produced via `:put_version`); `Settlement.begin/1` persists it. So `target_surface_version` is non-nil exactly when the turn produced a page version.
- `Ezagent.Socialware.CustomerFeed.snapshot/2` (`customer_feed.ex:19-31`) → `%{messages: MessageStore.committed_customer_visible(session, 100), page: customer_page(session)}`.
- `CustomerFeed.customer_page/1` (`customer_feed.ex:157-162`) → `Surface.customer_tree(live :surface slice)` — **THE PAGE LEAK**: renders `surface.approved`'s tree, which `turn.settle` advances (`:approve`) before `:commit_settlement`.
- `MessageStore.committed_customer_visible/2` (`apps/ezagent_core/lib/ezagent/message_store.ex:220-240`) — already commit-gated (`s.status == "committed"` AND `m.visibility == :customer_visible`). **Messages are already correct.**
- `Ezagent.Behavior.Surface` (`apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`) — `customer_tree(%{approved: v} = s) -> version_tree(v, s)`; private `version_tree/2`. The `:surface` slice retains ALL versions in `surface.versions` (immutable append; `create/1 -> %{versions: %{}, approved: nil, version_seq: 0}`), so the committed (possibly older) version is still renderable.

**The gap P2.5a closes:** the page leak. Fix: render the page from the latest COMMITTED settlement's `target_surface_version`, status-gated — not the live approved pointer.

**Out of scope (deferred to P2.5b):**
- The durable **outbox `surface_version` column** + **cursor-addressable replay** (`committed_deliveries_since`, monotonic delivery cursor) — needs the commit-order cursor that only the atomic outbox/commit restructure provides (codex rev2 CRITICAL).
- **Post-parent-turn-commit ordering** (settlement casts firing before the parent Turn slice durably commits; rev4 HIGH) + **atomic outbox/commit** + **parent-commit-rollback test** + **wire-schema #44**.

---

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex` | Modify | Add `tree_for_version/2` (public) — render a SPECIFIC version's tree (not the live `approved` pointer). |
| `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex` | Modify | `customer_page/1` renders the latest COMMITTED settlement's `target_surface_version` (not the live approved pointer); cold-safe `surface_slice/1` (snapshot fallback); `workspace/1` derives the workspace structurally (not the volatile registry). |
| `apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs` | Modify | `tree_for_version/2` unit tests. |
| `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs` | Create | committed-page + leak (approve, no commit) + partial-commit (pending settlement → nil) + wake-up-loss + cold-read (session terminated → snapshot still serves page) + cold-reconnect-auth (no registry binding → still authorizes) tests. |
| `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_feed_approved_attachment_test.exs` | Modify | Add a cold no-registry `authorized_attachment_path/4` test (proves `workspace/1` returns a `%URI{}` usable by `EzURI.workspace_name/1`). |

No migration. No `ezagent_core` change.

---

## Task 1: `Surface.tree_for_version/2` — render a specific committed version

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/behavior/surface.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/behavior/surface_test.exs`

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
  pointer. The committed customer page is rendered from the version recorded on
  the committed settlement (NOT `surface.approved`, which may have advanced past
  the last committed delivery). Returns `nil` for a missing/nil version.
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

## Task 2: Commit-gate the customer page

**Files:**
- Modify: `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`
- Test: `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs` (create)

- [ ] **Step 1: Write the failing tests**

Create `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs`:

```elixir
defmodule Ezagent.Socialware.CustomerPageCommitGateTest do
  @moduledoc """
  P2.5a — the customer PAGE is commit-gated: it renders from the latest COMMITTED
  settlement's surface version (never the live approved-but-uncommitted slice). A
  pending settlement does not expose a page; dropping the {:customer_delivery}
  wake-up still delivers via the durable snapshot.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.CustomerFeed

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "p2-5a-#{System.unique_integer([:positive])}")
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
    if fun.(), do: :ok, else: (Process.sleep(20); wait_until(fun, attempts - 1))
  end

  defp spawn_session do
    uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(uri))
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: uri})
    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  # Derive the workspace STRUCTURALLY (same as the production snapshot/auth path),
  # so the token's workspace matches what CustomerFeed.workspace/1 derives — even
  # after the volatile WorkspaceRegistry binding is dropped.
  defp test_token(session_uri) do
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(session_uri)
    Ezagent.Socialware.CustomerAuth.issue_token(session_uri, workspace_uri)
  end

  # open -> dispatch -> deliver(page) -> compose; returns {turn_id, version}.
  # Does NOT settle (caller chooses approve-only vs full settle).
  defp compose_page(uri, page_tree) do
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

    {turn_id, version}
  end

  defp settle(uri, turn_id) do
    {:ok, %{status: :settled}} = dispatch(uri, :turn, :settle, %{turn_id: turn_id})

    wait_until(fn ->
      case Ezagent.Socialware.Settlement.get(turn_id) do
        {:ok, %{status: :committed}} -> true
        _ -> false
      end
    end)
  end

  describe "committed page renders from the committed version" do
    test "after a full settle+commit, snapshot.page is the committed surface tree" do
      page_tree = %{type: "text", props: %{text: "committed page"}}
      uri = spawn_session()
      token = test_token(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == page_tree
    end
  end

  describe "page commit-gating (leak test)" do
    test "approved-but-uncommitted page does NOT leak (no settlement at all)" do
      page_tree = %{type: "text", props: %{text: "draft page"}}
      uri = spawn_session()
      token = test_token(uri)
      {_turn_id, version} = compose_page(uri, page_tree)

      # Approve the surface (advances the LIVE pointer) but never settle/commit.
      {:ok, _} = dispatch(uri, :surface, :approve, %{version: version})

      wait_until(fn ->
        {:ok, surface} = Ezagent.Kind.get_slice(uri, :surface)
        surface.approved == version
      end)

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == nil, "approved-but-uncommitted page must NOT leak"
      assert snapshot.messages == []
    end
  end

  describe "partial-commit gate: settlement pending" do
    test "a PENDING settlement (target version set, surface approved) does NOT expose a page" do
      page_tree = %{type: "text", props: %{text: "pending page"}}
      uri = spawn_session()
      token = test_token(uri)
      {:ok, workspace_uri} = Ezagent.WorkspaceRegistry.lookup(uri)
      {turn_id, version} = compose_page(uri, page_tree)

      {:ok, _} = dispatch(uri, :surface, :approve, %{version: version})

      # A PENDING settlement carrying the target version (status not flipped).
      {:ok, settlement} =
        Ezagent.Socialware.Settlement.begin(%{
          turn_id: turn_id,
          session_uri: uri,
          workspace_uri: workspace_uri,
          target_message_ids: [],
          target_surface_version: version
        })

      assert settlement.status == :pending

      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == nil
    end
  end

  describe "wake-up loss" do
    test "a committed page is visible via the durable snapshot even with no PubSub event" do
      page_tree = %{type: "text", props: %{text: "delivered despite lost wake-up"}}
      uri = spawn_session()
      token = test_token(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      # We never subscribed to / received {:customer_delivery}; a fresh snapshot
      # (== reconnect) still returns the committed page from the durable record.
      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == page_tree
    end
  end

  describe "cold-read durability (codex rev4 HIGH): committed page survives a stopped session" do
    test "after the live session process is terminated, snapshot still returns the committed page" do
      page_tree = %{type: "text", props: %{text: "cold page"}}
      uri = spawn_session()
      token = test_token(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      # The snapshot must be durable before we drop the process.
      wait_until(fn -> KindSnapshot.get(URI.to_string(uri)) != nil end)

      {:ok, pid} = Ezagent.KindRegistry.lookup(uri)

      :ok =
        DynamicSupervisor.terminate_child(
          EzagentDomainSocialware.SocialwareSessionSupervisor,
          pid
        )

      wait_until(fn -> Ezagent.KindRegistry.lookup(uri) == :error end)

      # COLD path: no live process; the page is served from the durable snapshot.
      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == page_tree
    end
  end

  describe "cold-reconnect auth (codex rev4 MEDIUM): structural workspace, no registry binding" do
    test "snapshot authorizes a valid token even when the WorkspaceRegistry binding is gone" do
      page_tree = %{type: "text", props: %{text: "structural page"}}
      uri = spawn_session()
      token = test_token(uri)
      {turn_id, _version} = compose_page(uri, page_tree)
      settle(uri, turn_id)

      # Drop the volatile registry binding (simulating a restart where ETS is empty).
      :ok = Ezagent.WorkspaceRegistry.unbind(uri)
      assert Ezagent.WorkspaceRegistry.lookup(uri) == :error

      # Auth derives the workspace structurally -> still authorizes + returns the page.
      {:ok, snapshot} = CustomerFeed.snapshot(uri, token)
      assert snapshot.page == page_tree
    end
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs -v 2>&1 | tail -25`
Expected: FAIL — the leak + partial-commit tests fail because `customer_page/1` reads the live approved pointer (renders the page with no committed settlement).

- [ ] **Step 3: Commit-gate `customer_page/1`**

Edit `apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex`:

(a) Add at the top, after the existing aliases:

```elixir
  import Ecto.Query
  alias Ezagent.Socialware.SettlementRecord
  alias EzagentCore.Repo
```

(b) Replace `customer_page/1` (currently `customer_feed.ex:157-162`):

```elixir
  # P2.5a — render the customer page from the COMMITTED surface version, NOT the
  # live `:surface.approved` pointer. `turn.settle` dispatches `:approve`
  # (advancing the live pointer) BEFORE `:commit_settlement` flips the settlement
  # status, so reading the live pointer leaks an approved-but-uncommitted page.
  # The committed version is the latest committed settlement's
  # `target_surface_version` (mirrors the message gate, which requires
  # status == :committed). The :surface slice retains every version tree, so the
  # committed (possibly older) version is still renderable.
  defp customer_page(session_uri) do
    case committed_surface_version(session_uri) do
      nil -> nil
      version -> Surface.tree_for_version(surface_slice(session_uri), version)
    end
  end

  # The target_surface_version of the most-recently-COMMITTED settlement that
  # carries a page (target_surface_version not null). nil → no committed page.
  defp committed_surface_version(session_uri) do
    session_str = URI.to_string(session_uri)

    from(s in SettlementRecord,
      where:
        s.session_uri == ^session_str and s.status == :committed and
          not is_nil(s.target_surface_version),
      order_by: [desc: s.committed_at, desc: s.turn_id],
      limit: 1,
      select: s.target_surface_version
    )
    |> Repo.one()
  end

  # P2.5a (codex rev4 HIGH) — COLD-SAFE surface read. `get_slice/2` needs a live
  # session process (it does NOT lazy-spawn); after a BEAM restart / reaped
  # session the committed page must still render from the durable snapshot. Try
  # the live slice first; on `:not_found` fall back to the snapshot via
  # StateRebuilder.rebuild/1 + the public normalize_slice_view/1 (the snapshot
  # stores the two-container Lifecycle slice; normalize flattens it exactly as
  # get_slice/2 does). Returns `%{}` if neither path yields a slice.
  defp surface_slice(session_uri) do
    case Ezagent.Kind.get_slice(session_uri, :surface) do
      {:ok, surface} when is_map(surface) ->
        surface

      _ ->
        case Ezagent.Kind.StateRebuilder.rebuild(URI.to_string(session_uri)) do
          {:ok, state, _from} ->
            Ezagent.Kind.normalize_slice_view(Map.get(state, :surface, %{}))

          _ ->
            %{}
        end
    end
  end
```

(c) Make workspace auth cold-safe — replace `workspace/1` (currently `customer_feed.ex:150-155`, which uses `Ezagent.WorkspaceRegistry.lookup/1`, volatile ETS lost on restart) with the structural derivation the message gate already uses:

```elixir
  # P2.5a (codex rev4 MEDIUM) — derive the workspace STRUCTURALLY from the
  # session URI (session://<workspace>/<template>/<name>), not the volatile
  # WorkspaceRegistry ETS cache (empty after a restart → a still-valid customer
  # token would be wrongly rejected on cold reconnect). Mirrors
  # MessageStore.committed_customer_visible/2, which already resolves the
  # workspace via Ezagent.Persistence. Returns a `%URI{}` (parsed from the
  # structural string) to preserve the URI-struct contract the previous
  # WorkspaceRegistry.lookup/1 provided — `authorized_attachment_path/4` calls
  # `EzURI.workspace_name/1`, which has ONLY `%URI{}` heads (codex rev5 HIGH).
  defp workspace(session_uri) do
    case Ezagent.Persistence.workspace_uri_for(session_uri) do
      {:ok, workspace_str} -> {:ok, EzURI.new!(workspace_str)}
      {:error, _} -> {:error, :unbound_session}
    end
  end
```

> `Persistence.workspace_uri_for/1` returns `{:ok, workspace_uri_string}` (e.g. `"workspace://team_alpha"`) for a `session://` URI; `EzURI.new!/1` round-trips it to a `%URI{}`. `CustomerAuth.authorize/3` stringifies its workspace arg before comparing (`uri_to_string/1`, `customer_auth.ex:34`), so a `%URI{}` matches a token signed with the equivalent string. `EzURI.workspace_name/1` (only `%URI{}` heads) and any other `%URI{}`-expecting caller of `workspace/1`'s result are satisfied. (`EzURI` is the existing `alias Ezagent.URI, as: EzURI` at the top of `customer_feed.ex`.)

- [ ] **Step 4: Run to verify they pass**

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs -v 2>&1 | tail -20`
Expected: PASS — committed-page, leak, partial-commit, wake-up-loss all green.

- [ ] **Step 5: Add the cold attachment-path regression (codex rev5 HIGH)**

The workspace change touches `authorized_attachment_path/4` (it calls `EzURI.workspace_name/1`, `%URI{}`-only). Add this test to the EXISTING `apps/ezagent_domain_socialware/test/ezagent/socialware/customer_feed_approved_attachment_test.exs` (it already has `commit_message_with_attachment/3`, `upload_uri/2`, and `alias Ezagent.URI, as: EzURI`), before its final `end`:

```elixir
  test "authorized_attachment_path resolves a committed attachment with NO WorkspaceRegistry binding (cold reconnect; codex rev5)",
       ctx do
    ws_name = Ezagent.URI.workspace_name!(ctx.workspace)
    upload = upload_uri(ws_name, "uuid-cold.pdf")
    _ = commit_message_with_attachment(ctx, upload, :customer_visible)

    # Token signed with the STRUCTURAL workspace (what the cold path derives).
    structural_ws = Ezagent.Persistence.workspace_uri_for!(ctx.session)
    token = CustomerAuth.issue_token(ctx.session, structural_ws)

    # Drop the volatile registry binding (== restart with empty ETS).
    :ok = Ezagent.WorkspaceRegistry.unbind(ctx.session)
    assert Ezagent.WorkspaceRegistry.lookup(ctx.session) == :error

    # workspace/1 must yield a %URI{} that EzURI.workspace_name/1 accepts (no
    # FunctionClauseError) AND auth must pass on the structurally-derived ws.
    resolve_fun = fn ^upload, %{workspace: ws} -> {:ok, "/tmp/#{ws}/cold.pdf"} end

    assert {:ok, path} =
             CustomerFeed.authorized_attachment_path(ctx.session, token, upload, resolve_fun)

    assert String.ends_with?(path, "/cold.pdf")
  end
```

Run: `MIX_ENV=test mix test apps/ezagent_domain_socialware/test/ezagent/socialware/customer_feed_approved_attachment_test.exs -v 2>&1 | tail -15`
Expected: PASS — all existing approved-attachment tests (unchanged behavior, now via structural workspace) + the new cold no-registry one. (Pre-fix, returning a string from `workspace/1` would raise `FunctionClauseError` in `EzURI.workspace_name/1`.)

- [ ] **Step 6: Commit**

```bash
git add apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed.ex apps/ezagent_domain_socialware/test/ezagent/socialware/customer_page_commit_gate_test.exs apps/ezagent_domain_socialware/test/ezagent/socialware/customer_feed_approved_attachment_test.exs
git commit -m "feat(socialware/p2.5a): commit-gate the customer page + cold-safe surface read & structural workspace

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Regression + arch gate

**Files:** none (verification-only). Per `feedback_completion_requires_invariant_test`, the leak + partial-commit + wake-up-loss tests are the architectural gate proving P2.5a's page-commit-gating goal; this task confirms no regression.

- [ ] **Step 1: Full socialware + web suites**

Run (each 0 failures):
```bash
MIX_ENV=test mix test apps/ezagent_domain_socialware/test 2>&1 | tail -8
MIX_ENV=test mix test apps/ezagent_web/test 2>&1 | tail -8
```
Expected: all green. If an EXISTING test asserted the old live-approved-pointer page (the leak), it was asserting buggy behavior — update it to the committed-gate semantics with a comment (note it in the commit). Confirm `turn_customer_feed_integration_test.exs` (turn→feed integration) still passes; its turns go through full settle+commit so the committed page matches.

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

1. **Spec coverage:** P2.5a covers the socialware-local **page commit-gating** sub-point of spec §6 P2.5 (render the page from the committed surface version, status-gated). The **durable outbox surface_version column + cursor-addressable replay** and **post-parent-turn-commit ordering** + **#44 wire-schema** are explicitly DEFERRED to **P2.5b** (the cursor needs commit-ordering to be correct; codex rev2 CRITICAL).
2. **Upgrade-safe (codex rev3 HIGH closed):** no migration, no new nullable column to be null on existing rows. The read operates on `SettlementRecord.target_surface_version`, which already exists and is populated for committed settlements — existing committed pages keep rendering.
2b. **Cold-path durable (codex rev4 HIGH + MEDIUM closed):** `surface_slice/1` falls back to `StateRebuilder.rebuild/1` + `normalize_slice_view/1` when the session process is absent (committed page survives a BEAM restart / reaped session); `workspace/1` derives the workspace structurally via `Persistence.workspace_uri_for/1` (cold reconnects authorize without the volatile registry). Covered by the cold-read + cold-reconnect-auth tests.
3. **Placeholder scan:** none. `test_token/1` uses the verified real API `CustomerAuth.issue_token/3`.
4. **Type consistency:** `target_surface_version` integer-or-nil across the read (`not is_nil(s.target_surface_version)`) and `Surface.tree_for_version/2`. `status == :committed` compares the `Ecto.Enum` atom (consistent with the schema `values: [:pending, :committed]`).
5. **Ambiguity — page version selection:** `committed_surface_version/1` picks the committed settlement with the latest `committed_at` (tiebreak by turn_id), filtered to `target_surface_version not null` (a messages-only commit must not clear a previously-committed page). Explicit in the query.
6. **No core / no schema change:** only two socialware library files + tests; blast radius is inside `ezagent_domain_socialware`.

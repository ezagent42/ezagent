defmodule Ezagent.ActionSet.Publisher.SessionImplMigrationParityTest do
  @moduledoc """
  Phase 2-a r3 (2026-05-28) — migration parity tests for
  `Ezagent.ActionSet.Publisher.SessionImpl` after the SPEC 2026-05-28
  new-action-grammar migration.

  Covers the three actions (:subscribe_from / :snapshot / :history)
  via their `handle_<action>/2` shape, asserting:
  - Slice-state reads via ctx[:read] (persistent) + ctx.transients
    (subscribers / monitors)
  - Effects produced match expected shape (:set for persistent state
    mutations; :set_transient for the transient subscriber/monitor maps)
  - Error paths return the expected typed errors

  ## Lifecycle migration (SPEC 2026-05-29) — accessor updates

  After the `use Ezagent.ActionSet` → `use Ezagent.Lifecycle` migration:
  - `init_slice/1` now returns the two-container `%{state:, transients:}`
    shape; persistent fields (`ring`/`cursor`/`retention`) live under
    `.state`, the transient maps (`subscribers`/`monitors`) under
    `.transients` (filled by `activate/2`, EMPTY at `create`).
  - `post_init/2` is macro-emitted and returns `{:continue,
    :ezagent_activate}` (the macro's unified activate continuation), NOT
    the old `:subscribe_to_self_slice_change`.
  - `reconcile_after_load/2` is GONE — its subscriber/monitor clear is
    subsumed by the transient container (they start empty every
    `activate/2`). The two reconcile tests are replaced by a `create/1`
    persistent-only assertion + an `activate/2` empty-transients
    assertion that prove the same invariant structurally.
  - `subscribe_from` now produces `{:set_transient, ...}` (not `{:set,
    ...}`) for the subscriber/monitor maps; the handler reads them from
    `ctx.transients`.
  """

  use ExUnit.Case, async: true

  alias Ezagent.ActionSet.Publisher.SessionImpl
  alias Ezagent.Publisher.Event

  defp empty_slice(extras \\ %{}) do
    Map.merge(
      %{
        ring: [],
        cursor: 0,
        retention: 100,
        subscribers: %{},
        monitors: %{}
      },
      extras
    )
  end

  # Lifecycle: persistent fields read via `:read`; transient maps
  # (subscribers / monitors) read via `:transients`. The flat parity
  # slice co-locates both, so expose the same flat map as `:transients`.
  defp ctx_for(slice, extras \\ %{}) do
    Map.merge(
      %{
        read: fn key, default -> Map.get(slice, key, default) end,
        transients: slice,
        self_uri: Ezagent.URI.new!("session://team-alpha/default/parity"),
        caller: nil,
        authenticated_principal: nil,
        caps: MapSet.new()
      },
      extras
    )
  end

  describe "new-contract surface" do
    test "is a new-style Behavior" do
      assert SessionImpl.__behavior__?() == true
    end

    test "declares the three actions" do
      assert Enum.sort(SessionImpl.__action_names__()) ==
               [:history, :snapshot, :subscribe_from]
    end

    test "state_slice/0 is :publisher" do
      assert SessionImpl.state_slice() == :publisher
    end

    # Lifecycle: `create/1` builds ONLY the persistent fields; the
    # transient subscriber/monitor maps are NOT in `state` — `activate/2`
    # fills them empty on every start.
    test "create/1 with default retention (persistent fields only)" do
      assert {:ok, state} = SessionImpl.create(%{})
      assert state.ring == []
      assert state.cursor == 0
      assert state.retention == SessionImpl.default_retention()
      refute Map.has_key?(state, :subscribers)
      refute Map.has_key?(state, :monitors)
    end

    test "init_slice/1 wraps create/1 in the two-container shape (transients empty)" do
      slice = SessionImpl.init_slice(%{})
      assert slice.state.ring == []
      assert slice.state.cursor == 0
      assert slice.transients == %{}
    end

    test "create/1 with custom retention" do
      assert {:ok, %{retention: 50}} = SessionImpl.create(%{publisher_retention: 50})
    end

    test "post_init/2 returns the macro activate continuation" do
      assert {:continue, :ezagent_activate} = SessionImpl.post_init(%{}, %{})
    end

    # reconcile_after_load/2 is GONE (subsumed by the transient container).
    # The same invariant — subscribers/monitors never carry stale handles
    # across a restart — is now structural: they live in `transients`,
    # which `activate/2` rebuilds EMPTY every start. These two tests prove
    # it directly.
    test "create/1 does NOT carry the transient bookkeeping maps" do
      assert {:ok, state} = SessionImpl.create(%{})
      refute Map.has_key?(state, :subscribers)
      refute Map.has_key?(state, :monitors)
    end

    test "activate/2 rebuilds subscribers + monitors EMPTY (no stale-handle carry)" do
      ctx = %{self_uri: Ezagent.URI.new!("session://team-alpha/default/parity")}
      assert {:ok, transients} = SessionImpl.activate(%{ring: [], cursor: 0, retention: 100}, ctx)
      assert transients.subscribers == %{}
      assert transients.monitors == %{}
    end
  end

  describe "handle_snapshot/2 — read-only over current slice" do
    test "empty ring returns nil state + cursor 0" do
      slice = empty_slice()
      ctx = ctx_for(slice)

      assert {:ok, %{cursor: 0, state: nil}, []} = SessionImpl.handle_snapshot(%{}, ctx)
    end

    test "populated ring returns latest event's payload + current cursor" do
      ev = %Event{
        cursor: 3,
        publisher_uri: Ezagent.URI.new!("session://x/y/z"),
        slice_key: :session,
        event_at: DateTime.utc_now(),
        payload: %{new_slice: %{members: %{}}}
      }

      slice = empty_slice(%{ring: [ev], cursor: 3})
      ctx = ctx_for(slice)

      assert {:ok, %{cursor: 3, state: %{new_slice: _}}, []} =
               SessionImpl.handle_snapshot(%{}, ctx)
    end

    test "no :set effects (read-only)" do
      ctx = ctx_for(empty_slice())
      assert {:ok, _, []} = SessionImpl.handle_snapshot(%{}, ctx)
    end
  end

  describe "handle_history/2 — read-only window query" do
    test "empty ring + default window returns no events" do
      ctx = ctx_for(empty_slice())
      assert {:ok, %{events: []}, []} = SessionImpl.handle_history(%{}, ctx)
    end

    test "invalid cursor type → typed error" do
      ctx = ctx_for(empty_slice())

      assert {:error, {:invalid_cursor, "not_a_cursor"}} =
               SessionImpl.handle_history(%{from: "not_a_cursor"}, ctx)
    end
  end

  describe "handle_subscribe_from/2 — :set_transient effects for subscribers + monitors" do
    test "requires a real pid arg" do
      ctx = ctx_for(empty_slice())

      assert_raise ArgumentError, fn ->
        SessionImpl.handle_subscribe_from(%{subscriber_pid: :not_a_pid}, ctx)
      end
    end

    # Lifecycle: subscribers/monitors are TRANSIENTS — written via
    # `{:set_transient, ...}`, never persisted (SPEC §0.1 / §7 OQ-2).
    test "subscribing a fresh pid produces two :set_transient effects (subscribers + monitors)" do
      ctx = ctx_for(empty_slice())

      assert {:ok, %{cursor: 0}, effects} =
               SessionImpl.handle_subscribe_from(%{subscriber_pid: self()}, ctx)

      assert Enum.any?(effects, fn
               {:set_transient, :subscribers, m} -> is_map(m) and Map.has_key?(m, self())
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:set_transient, :monitors, m} -> is_map(m)
               _ -> false
             end)
    end

    test "invalid cursor → typed error, no effects" do
      ctx = ctx_for(empty_slice())

      assert {:error, _} =
               SessionImpl.handle_subscribe_from(
                 %{subscriber_pid: self(), cursor: -1},
                 ctx
               )
    end
  end

  describe "data_owner/1" do
    test ":any returns :any" do
      assert SessionImpl.data_owner(:any) == :any
    end

    test "within_workspace returns :any (workspace admin grants)" do
      ws = Ezagent.URI.new!("workspace://team-alpha")
      assert SessionImpl.data_owner({:within_workspace, ws}) == :any
    end

    test "non-session URI returns :no_owner" do
      assert SessionImpl.data_owner(Ezagent.URI.new!("entity://x/user/y")) == :no_owner
    end
  end
end

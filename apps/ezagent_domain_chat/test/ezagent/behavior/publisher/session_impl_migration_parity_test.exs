defmodule Ezagent.Behavior.Publisher.SessionImplMigrationParityTest do
  @moduledoc """
  Phase 2-a r3 (2026-05-28) — migration parity tests for
  `Ezagent.Behavior.Publisher.SessionImpl` after the SPEC 2026-05-28
  new-action-grammar migration.

  Covers the three actions (:subscribe_from / :snapshot / :history)
  via their `handle_<action>/2` shape, asserting:
  - Slice-state reads via ctx[:read]
  - Effects produced match expected shape (:set for state mutations)
  - Error paths return the expected typed errors
  - reconcile_after_load + on_ready + post_init contracts
  """

  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Publisher.SessionImpl
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

  defp ctx_for(slice, extras \\ %{}) do
    Map.merge(
      %{
        read: fn key, default -> Map.get(slice, key, default) end,
        self_uri: URI.parse("session://default/team-alpha/parity"),
        caller: nil,
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

    test "init_slice/1 with default retention" do
      slice = SessionImpl.init_slice(%{})
      assert slice.ring == []
      assert slice.cursor == 0
      assert slice.retention == SessionImpl.default_retention()
      assert slice.subscribers == %{}
      assert slice.monitors == %{}
    end

    test "init_slice/1 with custom retention" do
      assert SessionImpl.init_slice(%{publisher_retention: 50}).retention == 50
    end

    test "post_init/2 returns continuation atom" do
      assert {:continue, :subscribe_to_self_slice_change} =
               SessionImpl.post_init(%{}, %{})
    end

    test "reconcile_after_load/2 clears transient subscribers + monitors" do
      slice = empty_slice(%{subscribers: %{:fake_pid => :fake_ref}, monitors: %{:fake_ref => :fake_pid}, cursor: 42, ring: [:e1]})
      reconciled = SessionImpl.reconcile_after_load(URI.parse("session://x/y/z"), slice)

      # Transient fields cleared.
      assert reconciled.subscribers == %{}
      assert reconciled.monitors == %{}
      # Durable fields preserved.
      assert reconciled.cursor == 42
      assert reconciled.ring == [:e1]
    end

    test "reconcile_after_load/2 is idempotent" do
      slice = empty_slice()
      once = SessionImpl.reconcile_after_load(URI.parse("session://x/y/z"), slice)
      twice = SessionImpl.reconcile_after_load(URI.parse("session://x/y/z"), once)
      assert once == twice
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
        publisher_uri: URI.parse("session://x/y/z"),
        slice_key: :chat,
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

  describe "handle_subscribe_from/2 — :set effects for subscribers + monitors" do
    test "requires a real pid arg" do
      ctx = ctx_for(empty_slice())

      assert_raise ArgumentError, fn ->
        SessionImpl.handle_subscribe_from(%{subscriber_pid: :not_a_pid}, ctx)
      end
    end

    test "subscribing a fresh pid produces two :set effects (subscribers + monitors)" do
      ctx = ctx_for(empty_slice())

      assert {:ok, %{cursor: 0}, effects} =
               SessionImpl.handle_subscribe_from(%{subscriber_pid: self()}, ctx)

      # Both bookkeeping maps get a :set effect.
      assert Enum.any?(effects, fn
               {:set, :subscribers, m} -> is_map(m) and Map.has_key?(m, self())
               _ -> false
             end)

      assert Enum.any?(effects, fn
               {:set, :monitors, m} -> is_map(m)
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
      ws = URI.parse("workspace://team-alpha")
      assert SessionImpl.data_owner({:within_workspace, ws}) == :any
    end

    test "non-session URI returns :no_owner" do
      assert SessionImpl.data_owner(URI.parse("entity://user/x/y")) == :no_owner
    end
  end
end

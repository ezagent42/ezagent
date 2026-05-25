defmodule Ezagent.NotificationsTest do
  @moduledoc """
  Tests for `Ezagent.Notifications` — unified user-inbox primitive.

  Covers:
  - notify/2 with system caps broadcasts the tagged envelope
  - notify/2 with empty caps raises Unauthorized
  - notify/2 with correct :notify cap succeeds
  - notify/2 with malformed notification raises ArgumentError
  - subscribe/2 receives broadcasts; cap-gated identically
  - non-User URI raises ArgumentError
  """

  use ExUnit.Case, async: false

  alias Ezagent.{Capability, Notifications}

  defp unique_user_uri(suffix),
    do:
      URI.parse(
        "entity://user/default/notif_test_#{suffix}_#{System.unique_integer([:positive])}"
      )

  defp sample_notification do
    %{
      type: :test_event,
      body: %{n: 1},
      source: __MODULE__
    }
  end

  describe "notify/2 — broadcast + envelope shape" do
    test "system caller broadcasts the tagged envelope" do
      uri = unique_user_uri("sys_broadcast")
      :ok = Notifications.subscribe(uri, %{caps: :system})

      :ok = Notifications.notify(uri, sample_notification(), %{caps: :system})

      assert_receive {:notification, recv_uri, %{type: :test_event, body: %{n: 1}}}, 1_000
      assert URI.to_string(recv_uri) == URI.to_string(uri)
    end

    test "default ctx (system) succeeds without explicit ctx arg" do
      uri = unique_user_uri("default_ctx")
      :ok = Notifications.subscribe(uri, %{caps: :system})

      # notify/2 default ctx is %{caps: :system}
      :ok = Notifications.notify(uri, sample_notification())

      assert_receive {:notification, _, _}, 1_000
    end
  end

  describe "notify/2 — cap gating" do
    test "non-system caller without :notify cap raises Unauthorized" do
      uri = unique_user_uri("notify_denied")

      assert_raise Ezagent.Capability.Unauthorized, fn ->
        Notifications.notify(uri, sample_notification(), %{caps: MapSet.new()})
      end
    end

    test "non-system caller with correct :notify cap succeeds" do
      uri = unique_user_uri("notify_ok")
      ws = URI.parse("workspace://default")

      notify_cap = %Capability{
        kind: :user,
        behavior: Ezagent.Behavior.Notifications,
        instance: :any,
        workspace_uri: ws,
        granted_by: Ezagent.Entity.User.admin_uri(),
        granted_at: ~U[2026-01-01 00:00:00Z]
      }

      :ok = Notifications.subscribe(uri, %{caps: :system})

      :ok =
        Notifications.notify(
          uri,
          sample_notification(),
          %{caps: MapSet.new([notify_cap])}
        )

      assert_receive {:notification, _, _}, 1_000
    end
  end

  describe "subscribe/2 — cap gating" do
    test "non-system caller without :subscribe cap raises Unauthorized" do
      uri = unique_user_uri("sub_denied")

      assert_raise Ezagent.Capability.Unauthorized, fn ->
        Notifications.subscribe(uri, %{caps: MapSet.new()})
      end
    end
  end

  describe "validation" do
    test "malformed notification (missing :type) raises ArgumentError" do
      uri = unique_user_uri("bad_shape")

      assert_raise ArgumentError, ~r/notification must be a map/, fn ->
        Notifications.notify(uri, %{body: %{}, source: __MODULE__}, %{caps: :system})
      end
    end

    test "non-User URI raises ArgumentError" do
      assert_raise ArgumentError, ~r/only entity:\/\/user/, fn ->
        Notifications.notify(
          "session://default/default/x",
          sample_notification(),
          %{caps: :system}
        )
      end
    end
  end

  describe "topic/1" do
    test "wraps URI in esr:user:...:events" do
      uri = URI.parse("entity://user/default/topic_test")
      assert Notifications.topic(uri) == "esr:user:entity://user/default/topic_test:events"
    end
  end

  # PR-N2 (SPEC v2 §3, Allen 2026-05-24) — subscriber-side dual
  # topic helper. Mirrors `subscribe/2` shape but targets the new
  # `esr:entity:<uri>:slice_changed` topic with NO cap check
  # (SPEC §2.3 self-serve subscribers).
  describe "subscribe_slice_change/1 — PR-N2 transition helper" do
    test "subscribes the caller to Ezagent.SliceChange.topic/1" do
      uri = unique_user_uri("slice_sub")

      assert :ok = Notifications.subscribe_slice_change(uri)

      # PR-N3 (Allen 2026-05-25) — `enabled?/0` is now an unconditional
      # `true`; the legacy config-knob force-on no longer applies.
      # PR-N3 codex r2 HIGH-1 (Allen 2026-05-25) — emit/1 broadcasts
      # the security-minimal envelope (5 fields), NOT the fat producer
      # event. Assertion shape updates accordingly. The invariant test
      # `slice_change_event_carries_no_slice_content_test.exs` is the
      # canonical envelope-shape gate; this test only proves the
      # subscribe-helper wires to the same topic.
      producer_event = %{
        self_uri: uri,
        kind_module: __MODULE__,
        action: :pr_n2_unit,
        slice_key: :test,
        old_slice: %{n: 1},
        new_slice: %{n: 2},
        result: nil,
        caller: nil,
        at: DateTime.utc_now()
      }

      :ok = Ezagent.SliceChange.emit(producer_event)

      assert_receive {:slice_changed, broadcast_event}, 500
      assert broadcast_event.uri == uri
      assert broadcast_event.slice_key == :test
      assert is_integer(broadcast_event.cursor)
      assert %DateTime{} = broadcast_event.event_at
      assert broadcast_event.result_summary == :ok
    end

    test "accepts a String URI argument (mirrors subscribe/2 polymorphism)" do
      uri_str = "entity://user/default/slice_sub_str_#{System.unique_integer([:positive])}"

      assert :ok = Notifications.subscribe_slice_change(uri_str)
      assert :ok = Notifications.unsubscribe_slice_change(uri_str)
    end

    test "delegates topic to Ezagent.SliceChange.topic/1 (no shape drift)" do
      uri = URI.parse("entity://user/default/topic_delegate_test")

      # Subscribe via the helper, then sanity-check we can also drive
      # the underlying PubSub with the SAME topic string — if the
      # helper ever computed a different topic shape, this test
      # would diverge.
      assert :ok = Notifications.subscribe_slice_change(uri)

      :ok =
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          Ezagent.SliceChange.topic(uri),
          {:slice_changed, %{probe: true}}
        )

      assert_receive {:slice_changed, %{probe: true}}, 500
    end

    test "unsubscribe_slice_change/1 stops further deliveries" do
      uri = unique_user_uri("slice_unsub")

      :ok = Notifications.subscribe_slice_change(uri)
      :ok = Notifications.unsubscribe_slice_change(uri)

      :ok =
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          Ezagent.SliceChange.topic(uri),
          {:slice_changed, %{should_not_arrive: true}}
        )

      refute_receive {:slice_changed, %{should_not_arrive: true}}, 100
    end
  end
end

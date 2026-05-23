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
end

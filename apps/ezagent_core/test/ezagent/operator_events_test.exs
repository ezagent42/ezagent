defmodule Ezagent.OperatorEventsTest do
  @moduledoc """
  Unit test for the canonical operator warning/event seam
  (`Ezagent.OperatorEvents`) — the ONE write API for operator-facing events.
  """
  use ExUnit.Case, async: false

  alias Ezagent.OperatorEvents

  setup do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, OperatorEvents.topic())
    :ok
  end

  describe "emit/1" do
    test "broadcasts {:operator_event, event} on the canonical topic" do
      assert {:ok, event} =
               OperatorEvents.emit(%{
                 severity: :warning,
                 source: :some_subsystem,
                 message: "something operator-relevant happened",
                 meta: %{target_uri: "entity://team-alpha/agent/x"}
               })

      assert_receive {:operator_event, ^event}
      assert event.severity == :warning
      assert event.source == :some_subsystem
      assert event.message == "something operator-relevant happened"
      assert event.meta == %{target_uri: "entity://team-alpha/agent/x"}
      assert %DateTime{} = event.at
    end

    test "fires [:ezagent, :operator, :event] telemetry (the Audit-sink hook)" do
      handler = "operator-events-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:ezagent, :operator, :event],
        fn name, measurements, metadata, _ ->
          send(test_pid, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _event} = OperatorEvents.warn(:cap_delivery_outbox, "dead row")

      assert_receive {:telemetry, [:ezagent, :operator, :event], %{count: 1}, metadata}
      assert metadata.severity == :warning
      assert metadata.source == :cap_delivery_outbox
      assert metadata.message == "dead row"
    end

    test "accepts a string source and string severity" do
      assert {:ok, event} =
               OperatorEvents.emit(%{severity: "error", source: "external", message: "boom"})

      assert event.severity == :error
      assert event.source == "external"
    end

    test "rejects an invalid severity" do
      assert {:error, {:invalid_severity, _}} =
               OperatorEvents.emit(%{severity: :catastrophe, source: :x, message: "m"})
    end

    test "rejects a missing/blank source or message (fail-closed on malformed input)" do
      assert {:error, {:missing_field, :source}} =
               OperatorEvents.emit(%{severity: :info, message: "m"})

      assert {:error, {:missing_field, :message}} =
               OperatorEvents.emit(%{severity: :info, source: :x})

      assert {:error, {:missing_field, :message}} =
               OperatorEvents.emit(%{severity: :info, source: :x, message: ""})
    end

    test "normalizes a non-map meta to an empty map" do
      assert {:ok, event} =
               OperatorEvents.emit(%{severity: :info, source: :x, message: "m", meta: :not_a_map})

      assert event.meta == %{}
    end
  end

  describe "convenience helpers" do
    test "warn/error/info set the severity and default meta to %{}" do
      assert {:ok, %{severity: :warning, meta: %{}}} = OperatorEvents.warn(:s, "w")
      assert {:ok, %{severity: :error, meta: %{}}} = OperatorEvents.error(:s, "e")
      assert {:ok, %{severity: :info, meta: %{}}} = OperatorEvents.info(:s, "i")

      assert_receive {:operator_event, %{severity: :warning}}
      assert_receive {:operator_event, %{severity: :error}}
      assert_receive {:operator_event, %{severity: :info}}
    end
  end
end

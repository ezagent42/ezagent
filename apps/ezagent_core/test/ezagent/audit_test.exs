defmodule Ezagent.AuditTest do
  use ExUnit.Case

  setup do
    # Make sure the handler is attached (Application.start should have
    # done this; re-attach is idempotent).
    :ok = Ezagent.Audit.attach()
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, Ezagent.Audit.stream_topic())
    :ok
  end

  test "[:ezagent, :invoke, :stop] is broadcast to esr:audit:stream" do
    target = URI.parse("entity://agent/team-alpha/test_audit-test")

    :telemetry.execute(
      [:ezagent, :invoke, :stop],
      %{duration_us: 123},
      %{
        target: target,
        caller: URI.parse("entity://user/system/admin"),
        action: :test,
        kind_module: Foo,
        behavior_module: Bar,
        behavior_name: :foo
      }
    )

    assert_receive {:audit_event, event}, 500
    assert event.event == [:ezagent, :invoke, :stop]
    assert event.measurements == %{duration_us: 123}
    assert event.metadata.target == "entity://agent/team-alpha/test_audit-test"
  end

  test "[:ezagent, :invoke, :error] is also broadcast" do
    target = URI.parse("entity://agent/team-alpha/test_audit-test")

    :telemetry.execute(
      [:ezagent, :invoke, :error],
      %{duration_us: 7},
      %{target: target, caller: URI.parse("entity://user/system/admin"), reason: :test_failure}
    )

    assert_receive {:audit_event, event}, 500
    assert event.event == [:ezagent, :invoke, :error]
  end

  test "stream_topic/0 is the canonical audit topic name" do
    assert Ezagent.Audit.stream_topic() == "esr:audit:stream"
  end
end

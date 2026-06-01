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

  # Phase 4 Item 4 regression test (2026-05-28).
  #
  # `Ezagent.Cmd.new/4` defaults `ctx.caller` to the atom `:system` for
  # system-originated dispatches. Pre-fix, the audit telemetry handler
  # crashed on first such event (`Ezagent.Audit.uri_to_str(:system)` had
  # no clause), and `:telemetry` then detached the handler — silently
  # disabling the audit log for the rest of the node's lifetime.
  #
  # Symptom (now blocked): scenario_30 had to call
  # `:telemetry.detach("esr-audit")` in its setup to keep the handler
  # alive across system-caller flows. The fix canonicalizes `:system`
  # to `"system://anonymous"` at `uri_to_str/1` so the handler stays
  # attached AND the row routes to `workspace://system` via the
  # `system_scoped_uri?/1` allowlist.
  test ":invoke :stop with caller: :system does NOT crash the audit handler" do
    target = URI.parse("entity://agent/system/sys-caller-test")

    # Capture handler-detach events so a crash would surface clearly
    # instead of silently disabling future audit rows.
    parent = self()
    detach_ref = make_ref()

    :telemetry.attach(
      "audit-detach-watcher-#{inspect(detach_ref)}",
      [:telemetry, :handler, :failure],
      fn _event, _meas, meta, _config ->
        send(parent, {:audit_handler_failed, detach_ref, meta})
      end,
      nil
    )

    :telemetry.execute(
      [:ezagent, :invoke, :stop],
      %{duration_us: 42},
      %{
        target: target,
        caller: :system,
        action: :test,
        kind_module: Foo,
        behavior_module: Bar,
        behavior_name: :foo
      }
    )

    # The audit stream broadcast should still arrive — handler stayed attached.
    assert_receive {:audit_event, event}, 500
    assert event.event == [:ezagent, :invoke, :stop]

    # And no `[:telemetry, :handler, :failure]` event should have fired
    # for the `esr-audit` handler.
    refute_receive {:audit_handler_failed, ^detach_ref, _meta}, 100

    :telemetry.detach("audit-detach-watcher-#{inspect(detach_ref)}")
  end
end

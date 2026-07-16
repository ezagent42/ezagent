defmodule Ezagent.DLQTest do
  use ExUnit.Case
  alias Ezagent.DLQ

  setup do
    # Sandbox checkout — DLQ.put writes to SQLite directly.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
  end

  test "reasons/0 enumerates the valid reason atoms" do
    reasons = DLQ.reasons()
    assert :behavior_exception in reasons
    assert :unroutable in reasons
    assert :no_actor in reasons
    assert :idempotency_duplicate_marker in reasons
  end

  test "put/2 writes a row + emits telemetry" do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "dlq-test-#{System.unique_integer([:positive])}",
      [:ezagent, :dlq, :write],
      fn _event, _meas, meta, _config -> send(test_pid, {ref, meta}) end,
      nil
    )

    payload = %Ezagent.Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.new!("entity://team-alpha/agent/echo_dlq-test?action=echo.say"),
      mode: :call,
      args: %{msg: "lost"},
      ctx: %{
        caller: Ezagent.URI.new!("entity://system/user/admin"),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: :ignore
      }
    }

    assert :ok = DLQ.put(:unroutable, payload)
    assert_receive {^ref, %{reason: :unroutable}}, 500

    # Verify the row landed in SQLite.
    rows = EzagentCore.Repo.query!("SELECT reason FROM dlq ORDER BY id DESC LIMIT 1").rows
    assert [["unroutable"]] = rows
  end

  test "put/2 rejects invalid reasons (function clause)" do
    assert_raise FunctionClauseError, fn ->
      DLQ.put(:not_a_real_reason, %{})
    end
  end
end

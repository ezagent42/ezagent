defmodule Ezagent.Kind.ReadyTransitionMarkFailedDrainTest do
  @moduledoc """
  R5 (doc §8.1 silent-drop) — when a target's readiness gate is marked `:failed`
  (its transport never joined), any `:cast` invocations still buffered in
  `PendingDelivery` for it MUST be drained to the DLQ (reason `:never_ready`) with
  telemetry, not silently dropped.

  Before the fix `mark_failed/1` only flipped `ReadyGate`; the buffer rotted in
  ETS — never delivered, never dead-lettered, never logged (Invariant #9 /
  Decision #67 "overflow falls to DLQ"). This is the drain counterpart of
  `drain_pending_then_mark_ready/2` (which re-dispatches on `:ready`).
  """
  # Not async — shares the global ReadyGate / PendingDelivery ETS tables.
  use ExUnit.Case

  alias Ezagent.Kind.ReadyTransition
  alias Ezagent.PendingDelivery
  alias Ezagent.ReadyGate

  setup do
    # DLQ.put writes to SQLite directly.
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

    uri =
      "entity://team-alpha/agent/never_ready-drain-test-#{System.unique_integer([:positive])}"

    :ok = ReadyGate.put(uri, :not_ready)
    on_exit(fn -> PendingDelivery.flush(uri) end)
    {:ok, uri: uri}
  end

  defp buffered_invocation(uri) do
    %Ezagent.Invocation{
      target: Ezagent.URI.new!("#{uri}?action=identity.grant_cap"),
      mode: :cast,
      args: %{cap: "recipe"},
      ctx: %{
        caller: Ezagent.URI.new!("entity://system/user/admin"),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: :ignore
      }
    }
  end

  test "mark_failed drains buffered casts to the DLQ (reason :never_ready) + telemetry", %{
    uri: uri
  } do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "rt-drain-#{System.unique_integer([:positive])}",
      [:ezagent, :ready_transition, :mark_failed_drained],
      fn _event, meas, meta, _cfg -> send(test_pid, {ref, meas, meta}) end,
      nil
    )

    :ok = PendingDelivery.buffer(uri, buffered_invocation(uri))
    :ok = PendingDelivery.buffer(uri, buffered_invocation(uri))
    assert PendingDelivery.buffer_size(uri) == 2

    assert :ok = ReadyTransition.mark_failed(uri)

    # gate flipped
    assert ReadyGate.status(uri) == :failed

    # buffer drained (no rotting entries)
    assert PendingDelivery.buffer_size(uri) == 0

    # each buffered cast dead-lettered as :never_ready
    rows =
      EzagentCore.Repo.query!("SELECT reason FROM dlq WHERE reason = 'never_ready'").rows

    assert length(rows) == 2

    # loud telemetry with the drained count
    assert_receive {^ref, %{count: 2}, %{uri: drained_uri}}, 500
    assert drained_uri == uri
  end

  test "mark_failed with an empty buffer just flips the gate — no DLQ row, no telemetry", %{
    uri: uri
  } do
    test_pid = self()
    ref = make_ref()

    :telemetry.attach(
      "rt-drain-empty-#{System.unique_integer([:positive])}",
      [:ezagent, :ready_transition, :mark_failed_drained],
      fn _event, meas, meta, _cfg -> send(test_pid, {ref, meas, meta}) end,
      nil
    )

    before =
      EzagentCore.Repo.query!("SELECT count(*) FROM dlq WHERE reason = 'never_ready'").rows

    assert :ok = ReadyTransition.mark_failed(uri)
    assert ReadyGate.status(uri) == :failed

    after_ =
      EzagentCore.Repo.query!("SELECT count(*) FROM dlq WHERE reason = 'never_ready'").rows

    assert before == after_
    refute_receive {^ref, _, _}, 100
  end

  test "accepts a %URI{} (the transport-readiness timeout path passes a struct)", %{uri: uri_str} do
    uri = Ezagent.URI.new!(uri_str)
    :ok = PendingDelivery.buffer(uri_str, buffered_invocation(uri_str))

    assert :ok = ReadyTransition.mark_failed(uri)
    assert ReadyGate.status(uri_str) == :failed
    assert PendingDelivery.buffer_size(uri_str) == 0
  end
end

defmodule Ezagent.Kind.ReadyTransitionMarkFailedDrainTest do
  @moduledoc """
  R5 (doc §8.1 silent-drop) — when a target's readiness gate is marked `:failed`
  (its transport never joined), any `:cast` invocations still buffered in
  `PendingDelivery` for it MUST be drained to the DLQ (reason `:never_ready`) with
  telemetry, not silently dropped. S7 pins this with a real delegated
  `identity.absorb_cap` artifact, not a generic filler cast.

  Before the fix `mark_failed/1` only flipped `ReadyGate`; the buffer rotted in
  ETS — never delivered, never dead-lettered, never logged (Invariant #9 /
  Decision #67 "overflow falls to DLQ"). This is the drain counterpart of
  `drain_pending_then_mark_ready/2` (which re-dispatches on `:ready`).
  """
  # Not async — shares the global ReadyGate / PendingDelivery ETS tables.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Kind.ReadyTransition
  alias Ezagent.PendingDelivery
  alias Ezagent.ReadyGate

  setup do
    uri =
      "entity://team-alpha/agent/never_ready-drain-test-#{System.unique_integer([:positive])}"

    :ok = ReadyGate.put(uri, :not_ready)
    on_exit(fn -> PendingDelivery.flush(uri) end)
    {:ok, uri: uri}
  end

  defp buffered_invocation(uri) do
    instance = Ezagent.URI.new!(uri)

    artifact = %Ezagent.Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: instance,
      workspace_uri: Ezagent.Capability.workspace_of(instance),
      granted_by: Ezagent.Entity.User.admin_uri(),
      granted_at: DateTime.utc_now()
    }

    %Ezagent.Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(instance, :identity, :absorb_cap),
      mode: :cast,
      args: %{artifact: artifact},
      ctx: %{
        caller: :vm_internal,
        caps: MapSet.new(),
        reply: :ignore
      }
    }
  end

  test "mark_failed drains buffered casts to the DLQ (reason :never_ready) + telemetry", %{
    uri: uri
  } do
    test_pid = self()
    ref = make_ref()
    handler_id = "rt-drain-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:ezagent, :ready_transition, :mark_failed_drained],
      fn _event, meas, meta, _cfg -> send(test_pid, {ref, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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
      EzagentCore.Repo.query!("SELECT reason, payload FROM dlq WHERE reason = 'never_ready'").rows

    assert length(rows) == 2

    assert Enum.all?(rows, fn ["never_ready", payload_json] ->
             payload = Jason.decode!(payload_json)

             payload["mode"] == "cast" and
               String.contains?(payload["target"], "action=identity.absorb_cap") and
               get_in(payload, ["args", "artifact", "granted_by"]) ==
                 "entity://system/user/admin"
           end)

    # loud telemetry with the drained count
    assert_receive {^ref, %{count: 2}, %{uri: drained_uri}}, 500
    assert drained_uri == uri
  end

  test "mark_failed with an empty buffer just flips the gate — no DLQ row, no telemetry", %{
    uri: uri
  } do
    test_pid = self()
    ref = make_ref()
    handler_id = "rt-drain-empty-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:ezagent, :ready_transition, :mark_failed_drained],
      fn _event, meas, meta, _cfg -> send(test_pid, {ref, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

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

  test "definitive Kind.terminate drains authority before the same URI can reincarnate", %{
    uri: uri_str
  } do
    uri = Ezagent.URI.new!(uri_str)

    {:ok, old_pid} =
      DynamicSupervisor.start_child(
        Ezagent.KindSupervisor,
        {Ezagent.Kind.Server, {Ezagent.Test.TestKind, %{uri: uri}}}
      )

    assert Process.alive?(old_pid)
    assert eventually(fn -> ReadyGate.status(uri) == :ready end)
    :ok = ReadyGate.put(uri, :not_ready)
    :ok = PendingDelivery.buffer(uri, buffered_invocation(uri_str))

    before_count = never_ready_count()

    assert :ok = Ezagent.Kind.terminate(uri)
    refute Process.alive?(old_pid)
    assert PendingDelivery.buffer_size(uri) == 0
    assert never_ready_count() == before_count + 1

    {:ok, new_pid} =
      DynamicSupervisor.start_child(
        Ezagent.KindSupervisor,
        {Ezagent.Kind.Server, {Ezagent.Test.TestKind, %{uri: uri}}}
      )

    on_exit(fn ->
      if Process.alive?(new_pid), do: Ezagent.Kind.terminate(uri)
    end)

    assert Process.alive?(new_pid)
    assert PendingDelivery.buffer_size(uri) == 0
  end

  test "an entry accepted by a crashed Kind is rejected before a replacement can drain it", %{
    uri: uri_str
  } do
    old_pid = register_forwarding_kind(uri_str)
    :ok = ReadyGate.put(uri_str, :not_ready)

    assert :ok =
             PendingDelivery.buffer_if_not_ready(
               uri_str,
               buffered_invocation(uri_str),
               old_pid
             )

    Process.exit(old_pid, :kill)
    assert eventually(fn -> Ezagent.KindRegistry.lookup(uri_str) == :error end)

    replacement_pid = register_forwarding_kind(uri_str)
    on_exit(fn -> Process.exit(replacement_pid, :kill) end)
    :ok = ReadyGate.put(uri_str, :not_ready)
    before_count = stale_incarnation_count()

    assert :ready = ReadyTransition.drain_pending_then_mark_ready(uri_str, replacement_pid)
    assert ReadyGate.status(uri_str) == :ready
    assert PendingDelivery.buffer_size(uri_str) == 0
    refute_receive {:replacement_received, _message}, 100
    assert stale_incarnation_count() == before_count + 1

    assert [[payload_json]] =
             EzagentCore.Repo.query!(
               "SELECT payload FROM dlq WHERE reason = 'stale_incarnation' ORDER BY id DESC LIMIT 1"
             ).rows

    assert Jason.decode!(payload_json)["target"] =~ "action=identity.absorb_cap"
  end

  defp never_ready_count do
    [[count]] =
      EzagentCore.Repo.query!("SELECT count(*) FROM dlq WHERE reason = 'never_ready'").rows

    count
  end

  defp stale_incarnation_count do
    [[count]] =
      EzagentCore.Repo.query!("SELECT count(*) FROM dlq WHERE reason = 'stale_incarnation'").rows

    count
  end

  defp register_forwarding_kind(uri) do
    test_pid = self()

    pid =
      spawn(fn ->
        :ok = Ezagent.KindRegistry.put_new(uri)
        send(test_pid, {:forwarding_kind_registered, self()})
        forwarding_kind_loop(test_pid)
      end)

    assert_receive {:forwarding_kind_registered, ^pid}, 1_000
    pid
  end

  defp forwarding_kind_loop(test_pid) do
    receive do
      message ->
        send(test_pid, {:replacement_received, message})
        forwarding_kind_loop(test_pid)
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end

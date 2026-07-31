defmodule Ezagent.Cap.DeliveryOutboxDeadOperatorEventTest do
  @moduledoc """
  A capability delivery going `:dead` (retry exhausted / permanent failure)
  was COMPLETELY SILENT before this seam — `handle_failure_result({:dead, …})`
  just forgot the target and returned `:ok`. It is now the first emitter on
  the canonical operator warning/event seam (`Ezagent.OperatorEvents`).

  This test drives the REAL `:dead` path (`record_handler_failure/2` with a
  permanent reason) and asserts an operator-visible warning is emitted. The
  companion `Ezagent.World.OperatorStreamsGateTest` proves the operator gate
  (a non-operator / caller-less socket does NOT receive it).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Delivery
  alias Ezagent.Cap.DeliveryOutbox
  alias Ezagent.Invocation
  alias Ezagent.OperatorEvents
  alias EzagentCore.Repo

  test "a :dead row emits an operator-visible warning naming the target" do
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, OperatorEvents.topic())

    target = Ezagent.URI.user("team-alpha", "dead-emit-#{System.unique_integer([:positive])}")
    target_str = URI.to_string(target)
    claim_token = "claim-#{System.unique_integer([:positive])}"

    delivery = insert_claimed_pending!(target_str, claim_token)

    invocation = %Invocation{
      origin: :trusted_internal,
      target: Ezagent.URI.with_action(target, :identity, :absorb_cap),
      mode: :cast,
      args: %{},
      ctx: %{cap_delivery_id: delivery.id, cap_delivery_claim_token: claim_token}
    }

    # `:missing_cap` classifies as PERMANENT → the row is marked :dead →
    # handle_failure_result({:dead, target_uri}) fires the operator event.
    assert :ok = DeliveryOutbox.record_handler_failure(invocation, :missing_cap)

    assert_receive {:operator_event, event}
    assert event.severity == :warning
    assert event.source == :cap_delivery_outbox
    assert event.message =~ "permanently failed"
    assert event.meta.target_uri == target_str

    assert Repo.get!(Delivery, delivery.id).status == :dead
  end

  defp insert_claimed_pending!(target_str, claim_token) do
    %Delivery{}
    |> Delivery.changeset(%{
      workspace_uri: Ezagent.Persistence.workspace_uri_for!(target_str),
      target_uri: target_str,
      op: :absorb_cap,
      payload: :erlang.term_to_binary(%{placeholder: true}),
      payload_identity: "dead-emit-#{System.unique_integer([:positive])}",
      status: :pending,
      attempts: 3,
      next_retry_at: DateTime.utc_now(),
      claim_token: claim_token,
      lease_until: DateTime.add(DateTime.utc_now(), 60, :second)
    })
    |> Repo.insert!()
  end
end

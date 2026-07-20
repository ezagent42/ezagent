defmodule EzagentDomainInstanceMessage.Integration.DeliveryBufferFullDropTest do
  @moduledoc """
  PR #1259 codex review item 2 — a receive fan-out to a `:not_ready` member
  whose `PendingDelivery` buffer is at cap is a REAL drop and must be treated
  as one at the session-delivery layer:

    * `dispatch_receive_call/3` sees `{:error, :buffer_full}` (surfaced by
      `Ezagent.Invocation` instead of the pre-fix silent `:ok`),
    * the message is NOT ReadMarker-marked `:delivered`,
    * the drop is loudly logged AND recorded as a `routing_traces` row
      (`rule_id: "delivery_dropped"`, `drop_reason: "buffer_full"`) so
      `Trace.journey(msg.id)` shows it.
  """

  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.ActionSet.Session.Delivery
  alias Ezagent.Message

  defp u(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp fill_to_capacity(uri, i \\ 1) do
    case Ezagent.PendingDelivery.buffer(uri, {:filler, i}) do
      :ok -> fill_to_capacity(uri, i + 1)
      {:error, :buffer_full} -> :ok
    end
  end

  test "receive fan-out into a full buffer → not marked delivered + delivery_dropped trace row" do
    ws = u("bufdrop")
    workspace_uri = Ezagent.URI.new!("workspace://#{ws}")
    session_uri = Ezagent.URI.new!("session://#{ws}/default/#{u("sess")}")
    sender_uri = Ezagent.URI.new!("entity://#{ws}/user/#{u("sender")}")
    recipient_uri = Ezagent.URI.new!("entity://#{ws}/agent/#{u("member")}")

    # Live recipient Kind (so `ensure_live` no-ops) held at `:not_ready`
    # (the cold-provision window), buffer at cap.
    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: recipient_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    on_exit(fn -> _ = Ezagent.Kind.terminate(recipient_uri) end)

    # The trace row derives its workspace from the session's binding.
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> Ezagent.WorkspaceRegistry.unbind(session_uri) end)

    :ok = Ezagent.ReadyGate.put(recipient_uri, :not_ready)

    # Agent startup may already have queued legitimate asynchronous follow-up
    # work while the Kind is held at :not_ready. Fill the remaining capacity
    # instead of assuming this shared delivery boundary starts empty.
    :ok = fill_to_capacity(recipient_uri)

    assert Ezagent.PendingDelivery.buffer_size(recipient_uri) ==
             Ezagent.PendingDelivery.max_per_uri()

    on_exit(fn ->
      _ = Ezagent.PendingDelivery.flush(recipient_uri)
      _ = Ezagent.ReadyGate.mark_ready(recipient_uri)
    end)

    msg = Message.new(sender_uri, %{text: "overflow me", attachments: []})

    log =
      capture_log(fn ->
        assert {:error, :buffer_full} =
                 Delivery.dispatch_receive_call(recipient_uri, msg, session_uri)
      end)

    # Loudly attributable at the delivery layer.
    assert log =~ "receive fan-out DROPPED"
    assert log =~ URI.to_string(recipient_uri)
    assert log =~ msg.id

    # NOT marked delivered (pre-fix regression: the silent `:ok` marked it).
    assert Ezagent.Session.ReadMarker.last_read(session_uri, recipient_uri, :delivered) == nil

    # The drop shows up in the message's routing journey.
    journey = Ezagent.Routing.Trace.journey(msg.id)

    assert Enum.any?(journey, fn t ->
             t.rule_id == "delivery_dropped" and t.drop_reason == "buffer_full" and
               URI.to_string(recipient_uri) in t.receivers
           end),
           "expected a delivery_dropped/buffer_full trace row; got #{inspect(journey)}"
  end
end

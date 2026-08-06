defmodule EzagentDomainInstanceMessage.SessionIngressTestBehavior do
  @moduledoc false

  use Ezagent.Lifecycle, state_slice: :session_ingress_test

  action(:capture_inbound,
    args: %{message: :map, session_uri: :uri},
    returns: %{accepted: :boolean},
    caps: [:capture_inbound],
    modes: [:cast],
    description: "Capture a generic Session ingress payload in integration tests"
  )

  @impl Ezagent.Lifecycle
  def create(_args) do
    {:ok,
     %{
       count: 0,
       last_message_id: nil,
       last_session_uri: nil,
       last_cap: nil,
       last_caller: nil,
       last_reply: nil
     }}
  end

  @doc false
  def handle_capture_inbound(
        %{message: %Ezagent.Message{} = message, session_uri: session_uri},
        ctx
      ) do
    [cap] = MapSet.to_list(ctx.caps)

    cap_summary = %{
      count: MapSet.size(ctx.caps),
      kind: cap.kind,
      behavior: cap.behavior,
      action: cap.action,
      instance: cap.instance,
      workspace_uri: cap.workspace_uri,
      grantee_uri: cap.grantee_uri,
      target_signed?: Ezagent.Cap.validate_for_current_target(cap, session_uri) == :ok
    }

    {:ok, %{accepted: true},
     [
       {:set, :count, ctx.read.(:count, 0) + 1},
       {:set, :last_message_id, message.id},
       {:set, :last_session_uri, session_uri},
       {:set, :last_cap, cap_summary},
       {:set, :last_caller, ctx.caller},
       {:set, :last_reply, ctx.reply}
     ]}
  end
end

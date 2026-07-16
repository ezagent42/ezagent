defmodule Ezagent.Kind.RuntimePhase3dTest do
  @moduledoc """
  Runtime authorization invariant: every cap-gated dispatch reaches the
  target Kind verifier and emits an explicit accepted or rejected outcome.
  """

  use EzagentCore.DataCase, async: false

  @moduletag :umbrella_only

  alias Ezagent.Invocation

  setup do
    test_pid = self()
    handler_id = "target-verifier-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ezagent, :cap, :verify, :accepted],
        [:ezagent, :cap, :verify, :rejected]
      ],
      fn event, _measurements, metadata, _config ->
        send(test_pid, {:verify_event, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "empty cap set is rejected fail-loud and emits verifier telemetry" do
    {target, message} = live_call_target()
    presenter = Ezagent.URI.new!("entity://team-alpha/user/verifier-nobody")

    assert {:error, :missing_cap} = dispatch(target, message, presenter, MapSet.new())

    assert_receive {:verify_event, [:ezagent, :cap, :verify, :rejected], metadata}, 500
    assert metadata.target == target
    assert metadata.action == :send
    assert metadata.presenter == presenter
    assert metadata.reason == :missing_cap
  end

  test "target-minted cap is accepted and emits verifier telemetry" do
    {target, message} = live_call_target()
    presenter = Ezagent.Entity.User.admin_uri()
    signed = signed_action_cap!(target, presenter)
    flush_verify_events()

    refute match?(
             {:error, reason} when reason in [:missing_cap, :invalid_cap_signature],
             dispatch(target, message, presenter, MapSet.new([signed]))
           )

    assert_receive {:verify_event, [:ezagent, :cap, :verify, :accepted], metadata}, 500
    assert metadata.target == target
    assert metadata.presenter == presenter
  end

  defp live_call_target do
    short = "phase3d_#{System.unique_integer([:positive])}"

    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        short,
        Ezagent.Entity.User.admin_uri(),
        template_name: "default"
      )

    message = Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "x", attachments: []})
    {Ezagent.URI.with_action(session_uri, :session, :send), message}
  end

  defp dispatch(target, message, presenter, caps) do
    Invocation.dispatch(%Invocation{
      origin: :authenticated_external,
      target: target,
      mode: :call,
      args: %{message: message},
      ctx: %{caller: presenter, caps: caps, reply: :ignore}
    })
  end

  defp flush_verify_events do
    receive do
      {:verify_event, _, _} -> flush_verify_events()
    after
      0 -> :ok
    end
  end
end

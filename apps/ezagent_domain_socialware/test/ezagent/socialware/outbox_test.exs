defmodule Ezagent.Socialware.OutboxTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.{ExternalFeed, Settlement}

  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "outbox-owner")

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "outbox-#{System.unique_integer([:positive])}")
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    target = target(session_uri, behavior, action)
    caller = owner()

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        authenticated_principal: caller,
        caps: Ezagent.Socialware.TestCapHelper.lifecycle_caps(session_uri, caller, target),
        reply: {:caller_inbox, self()}
      }
    })
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner(),
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, ExternalFeed.topic(session))

    %{session: session, workspace: workspace}
  end

  test "external delivery signal is ids-only and emitted after committed", ctx do
    assert {:ok, %{version: version}} =
             dispatch(ctx.session, :surface, :put_version, %{
               turn_id: "turn-outbox",
               tree: %{type: "text", props: %{text: "page"}}
             })

    msg =
      Message.new(Ezagent.URI.entity(:team_alpha, :agent, "orchestrator"), %{
        text: "deliverable",
        attachments: []
      })

    assert {:ok, msg} = MessageStore.write(msg, ctx.session)

    assert {:ok, _settlement} =
             Settlement.begin(%{
               turn_id: "turn-outbox",
               session_uri: ctx.session,
               workspace_uri: ctx.workspace,
               target_message_ids: [msg.id],
               target_surface_version: version,
               expected_prior_approved: nil
             })

    assert {:ok, _settlement} = Settlement.flip_visibility("turn-outbox")
    refute_receive {:external_delivery, _payload}, 50

    assert {:ok, %{approved: ^version}} =
             dispatch(ctx.session, :surface, :approve, %{version: version})

    assert {:ok, %{status: :committed}} =
             dispatch(ctx.session, :surface, :commit_settlement, %{turn_id: "turn-outbox"})

    assert_receive {:external_delivery, %{message_ids: [message_id]}}, 500
    assert message_id == msg.id
    refute_receive {:external_delivery, _payload}, 50

    assert {:ok, %{status: :committed}} =
             dispatch(ctx.session, :surface, :commit_settlement, %{turn_id: "turn-outbox"})

    refute_receive {:external_delivery, _payload}, 50
  end
end

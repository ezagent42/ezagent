defmodule EzagentDomainSocialware.Integration.TurnExternalFeedIntegrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.{ExternalFeed}

  @owner Ezagent.URI.entity(:team_alpha, :user, "turn-feed-owner")

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "turn-feed-#{System.unique_integer([:positive])}"
    )
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    target = target(session_uri, behavior, action)
    caller = User.admin_uri()

    Invocation.dispatch(%Invocation{origin: :trusted_internal,
      target: target,
      mode: :call,
      args: args,
      ctx: %{
        caller: caller,
        caps:
          Ezagent.Socialware.TestCapHelper.lifecycle_caps(session_uri, caller, target),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session,
        owner_uri: @owner,
        behaviors: Ezagent.Entity.Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, ExternalFeed.topic(session))

    %{session: session, caller: @owner}
  end

  test "turn.settle commits external-visible chat and approved page together", ctx do
    page_tree = %{type: "text", props: %{text: "settled page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{status: :composing, version: version, message_ids: [message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "settled answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    wait_until(fn ->
      {:ok, surface} = Ezagent.Kind.get_slice(ctx.session, :surface)
      Map.has_key?(surface.versions, version)
    end)

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert snapshot.messages == []
    assert snapshot.page == nil

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    assert_receive {:external_delivery, %{message_ids: [^message_id]}}, 500

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert Enum.any?(snapshot.messages, &message_text?(&1, "settled answer"))
    assert snapshot.page == page_tree
  end

  test "copilot draft stays internal until settle approval", ctx do
    page_tree = %{type: "text", props: %{text: "held page"}}

    assert {:ok, %{turn_id: turn_id}} =
             dispatch(ctx.session, :turn, :open, %{trigger: %{message_id: "m1"}, opened_at: 1})

    assert {:ok, %{message_ids: [message_id]}} =
             dispatch(ctx.session, :turn, :compose, %{
               turn_id: turn_id,
               result_refs: [
                 %{kind: :chat, text: "draft answer"},
                 %{kind: :page, tree: page_tree}
               ]
             })

    assert {:ok, %{status: :awaiting_human}} =
             dispatch(ctx.session, :turn, :claim, %{
               turn_id: turn_id,
               by: Ezagent.URI.entity(:team_alpha, :user, "operator")
             })

    assert {:ok, loaded} = MessageStore.by_id(message_id)
    assert loaded.visibility == :internal

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert snapshot.messages == []
    assert snapshot.page == nil

    assert {:ok, %{status: :settled}} = dispatch(ctx.session, :turn, :settle, %{turn_id: turn_id})

    assert_receive {:external_delivery, %{message_ids: [^message_id]}}, 500

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert Enum.any?(snapshot.messages, &message_text?(&1, "draft answer"))
    assert snapshot.page == page_tree
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end
end

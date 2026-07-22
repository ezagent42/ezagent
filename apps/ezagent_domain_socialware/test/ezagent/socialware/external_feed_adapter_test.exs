defmodule Ezagent.Socialware.ExternalFeedAdapterTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.ExternalMirror.{Adapter, AdapterRegistry, BindingRegistry}
  alias Ezagent.Socialware.{ExternalFeedAdapter, Settlement}

  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "efa-owner")
  @sender Ezagent.URI.entity(:team_alpha, :agent, "efa-bot")

  setup do
    session =
      Ezagent.URI.session(:team_alpha, :socialware, "efa-#{System.unique_integer([:positive])}")

    workspace = Ezagent.Capability.workspace_of(session)

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner(),
        behaviors: Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    %{session: session, workspace: workspace}
  end

  test "declares a cursor-replay participatory pull adapter" do
    assert ExternalFeedAdapter.adapter_kind() == :pull
    assert Adapter.kind_of(ExternalFeedAdapter) == :pull
    assert ExternalFeedAdapter.adapter_id() == "external_feed"
    assert ExternalFeedAdapter.delivery_discipline() == :cursor_replay
    assert ExternalFeedAdapter.participation_profile() == :participatory
    assert is_binary(ExternalFeedAdapter.display_name())
    assert is_binary(ExternalFeedAdapter.description())
  end

  test "is a bare pull declaration and registers without a binding" do
    refute function_exported?(ExternalFeedAdapter, :binding_module, 0)
    refute function_exported?(ExternalFeedAdapter, :target_ownership_check, 2)
    refute function_exported?(ExternalFeedAdapter, :event_to_payload, 1)

    assert AdapterRegistry.register(ExternalFeedAdapter) in [:ok, {:ok, :already_present}]
    assert {:ok, ExternalFeedAdapter} = AdapterRegistry.lookup("external_feed")
    assert :error = BindingRegistry.lookup("external_feed")
  end

  test "live_topics returns external delivery plus session event topics", %{session: session} do
    assert ExternalFeedAdapter.live_topics(session) == [
             Ezagent.Session.ExternalDelivery.topic(session),
             Ezagent.ActionSet.Session.Delivery.session_events_topic(session)
           ]
  end

  test "render, join_with_cursor, and replay delegate to ExternalFeed", ctx do
    committed = commit_message(ctx, "adapter-visible")

    rendered =
      Adapter.render(ExternalFeedAdapter, ctx.session, %{
        caller: owner(),
        authenticated_principal: owner()
      })

    assert Enum.any?(rendered.messages, &(&1.id == committed.id))

    assert {:ok, %{snapshot: join_snapshot, cursor: join_cursor}} =
             ExternalFeedAdapter.join_with_cursor(ctx.session, owner())

    assert Enum.any?(join_snapshot.messages, &(&1.id == committed.id))
    assert is_integer(join_cursor)

    assert {:ok, %{snapshot: replay_snapshot, cursor: replay_cursor}} =
             ExternalFeedAdapter.replay(ctx.session, owner(), 0)

    assert Enum.any?(replay_snapshot.messages, &(&1.id == committed.id))
    assert is_integer(replay_cursor)
  end

  test "non-member reads fail closed", ctx do
    stranger = Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "efa-stranger")

    assert {:error, :unauthorized} = ExternalFeedAdapter.join_with_cursor(ctx.session, stranger)
    assert {:error, :unauthorized} = ExternalFeedAdapter.replay(ctx.session, stranger, 0)
  end

  defp commit_message(ctx, text) do
    message = Message.new(@sender, %{text: text, attachments: []}, visibility: :external_visible)
    {:ok, written} = MessageStore.write(message, ctx.session)

    turn_id = "efa-turn-#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             Settlement.begin(%{
               turn_id: turn_id,
               session_uri: ctx.session,
               workspace_uri: ctx.workspace,
               target_message_ids: [written.id],
               target_surface_version: nil,
               expected_prior_approved: nil
             })

    assert {:ok, _} = Settlement.mark_committed_for_test(turn_id)
    written
  end
end

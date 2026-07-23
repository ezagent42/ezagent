defmodule Ezagent.Socialware.ChatFeedAdapterTest do
  @moduledoc """
  P4-2 — the chat feed is a SECOND registered `:pull` `ExternalAdapter`
  (`adapter_id: "chat_feed"`), declared as a BARE module (no binding), mirroring
  `CustomerFeedAdapter`. It shares the P3-2 SPA + Channel; only the source
  (chat `inserted_at` cursor) + authority (chat membership) differ.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ExternalMirror.{Adapter, AdapterRegistry, BindingRegistry}
  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.ChatFeedAdapter

  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "cfa-owner")
  @sender Ezagent.URI.entity(:team_alpha, :agent, "cfa-bot")

  test "declares adapter_kind :pull and the id/name/description trio" do
    assert ChatFeedAdapter.adapter_kind() == :pull
    assert Adapter.kind_of(ChatFeedAdapter) == :pull
    assert ChatFeedAdapter.adapter_id() == "chat_feed"
    assert is_binary(ChatFeedAdapter.display_name())
    assert is_binary(ChatFeedAdapter.description())
  end

  test "is a bare pull declaration — NO binding_module/0, no transport callbacks" do
    refute function_exported?(ChatFeedAdapter, :binding_module, 0)
    refute function_exported?(ChatFeedAdapter, :target_ownership_check, 2)
    refute function_exported?(ChatFeedAdapter, :event_to_payload, 1)
    assert function_exported?(ChatFeedAdapter, :render, 2)
    assert function_exported?(ChatFeedAdapter, :render_authorized, 2)
    assert function_exported?(ChatFeedAdapter, :live_topics, 1)
    assert ChatFeedAdapter.delivery_discipline() == :snapshot_refresh
    assert ChatFeedAdapter.participation_profile() == :read_only
    assert function_exported?(ChatFeedAdapter, :cap_subject, 0)
  end

  test "registers WITHOUT a binding and resolves via lookup" do
    assert AdapterRegistry.register(ChatFeedAdapter) in [:ok, {:ok, :already_present}]
    assert {:ok, ChatFeedAdapter} = AdapterRegistry.lookup("chat_feed")
    assert :error = BindingRegistry.lookup("chat_feed")
  end

  test "install hook registers the allow_chat_feed cap subject on Ezagent.Entity.Session" do
    assert AdapterRegistry.register(ChatFeedAdapter) in [:ok, {:ok, :already_present}]

    assert {:ok, %{behavior: Ezagent.Socialware.ChatFeedAdapter.Allow}} =
             Ezagent.CapabilityRegistry.lookup_subject(
               Ezagent.Entity.Session,
               :allow_chat_feed
             )
  end

  describe "render/2 routes the chat projection (caller-gated)" do
    setup do
      # `Adapter.render/3` gates on `function_exported?(ChatFeedAdapter, :render, 2)`,
      # which is `false` for a module whose BEAM is not yet LOADED — a run-order
      # flake (the module is only `alias`ed, not necessarily loaded, when this
      # describe runs first). Force-load it so the export check is deterministic.
      Code.ensure_loaded!(ChatFeedAdapter)

      session =
        Ezagent.URI.session(:team_alpha, :default, "cfa-#{System.unique_integer([:positive])}")

      workspace = Ezagent.Capability.workspace_of(session)

      {:ok, _pid} =
        Ezagent.Socialware.TestCapHelper.spawn_session(%{
          uri: session,
          owner_uri: owner(),
          behaviors: Ezagent.Entity.Session.behaviors()
        })

      :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

      msg =
        Message.new(@sender, %{text: "hi there", attachments: []}, visibility: :external_visible)

      {:ok, _} = MessageStore.write(msg, session)
      %{session: session}
    end

    test "render for an owner returns the chat_tree page + messages", %{session: session} do
      rendered =
        Adapter.render(ChatFeedAdapter, session, %{
          caller: owner(),
          authenticated_principal: owner()
        })

      assert Map.has_key?(rendered, :page)
      assert rendered.page.type == "container"
      assert Enum.any?(rendered.page.children, &(&1.props.text == "hi there"))
      assert Enum.any?(rendered.messages, &(message_text(&1) == "hi there"))
    end

    test "render for a non-member returns the empty/denied projection", %{session: session} do
      stranger = Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "cfa-stranger")

      rendered =
        Adapter.render(ChatFeedAdapter, session, %{
          caller: stranger,
          authenticated_principal: stranger
        })

      assert rendered == %{
               messages: [],
               page: %{type: "container", props: %{layout: "stack"}, children: []}
             }
    end

    test "render_authorized returns ok for a member and unauthorized for a non-member", %{
      session: session
    } do
      assert {:ok, snapshot} = ChatFeedAdapter.render_authorized(session, owner())
      assert Enum.any?(snapshot.messages, &(message_text(&1) == "hi there"))

      stranger = Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "cfa-stranger-authorized")
      assert {:error, :unauthorized} = ChatFeedAdapter.render_authorized(session, stranger)
    end

    test "live_topics returns the session events topic", %{session: session} do
      assert ChatFeedAdapter.live_topics(session) == [
               Ezagent.ActionSet.Session.Delivery.session_events_topic(session)
             ]
    end

    test "render with a nil/malformed caller returns the empty/denied projection", %{
      session: session
    } do
      assert Adapter.render(ChatFeedAdapter, session, %{caller: nil}).messages == []
      assert Adapter.render(ChatFeedAdapter, session, %{}).messages == []
    end
  end

  defp message_text(%Message{body: body}), do: Map.get(body, "text") || Map.get(body, :text)
end

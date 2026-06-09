defmodule Ezagent.Socialware.CustomerLeakTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.SocialwareSession
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed, Settlement}

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "customer-leak-#{System.unique_integer([:positive])}"
    )
  end

  defp sender_uri, do: Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")

  setup do
    session = session_uri()
    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)

    token = CustomerAuth.issue_token(session, workspace)
    %{session: session, workspace: workspace, token: token}
  end

  test "operator-only never reaches a CUSTOMER route; operator route still sees it", ctx do
    msg =
      Message.new(sender_uri(), %{text: "draft suggestion", attachments: []},
        visibility: :operator_only
      )

    assert {:ok, _written} = MessageStore.write(msg, ctx.session)

    assert {:ok, snapshot} = CustomerFeed.snapshot(ctx.session, ctx.token)
    assert {:ok, history} = CustomerFeed.history(ctx.session, ctx.token)

    refute Enum.any?(snapshot.messages, &message_text?(&1, "draft suggestion"))
    refute Enum.any?(history.messages, &message_text?(&1, "draft suggestion"))

    assert Enum.any?(
             MessageStore.recent_in_session(ctx.session, 10),
             &message_text?(&1, "draft suggestion")
           )
  end

  test "customer route returns only committed customer-visible messages", ctx do
    committed =
      Message.new(sender_uri(), %{text: "committed answer", attachments: []},
        visibility: :customer_visible
      )

    uncommitted =
      Message.new(sender_uri(), %{text: "uncommitted answer", attachments: []},
        visibility: :customer_visible
      )

    assert {:ok, committed} = MessageStore.write(committed, ctx.session)
    assert {:ok, _uncommitted} = MessageStore.write(uncommitted, ctx.session)

    assert {:ok, _} =
             Settlement.begin(%{
               turn_id: "turn-committed",
               session_uri: ctx.session,
               workspace_uri: ctx.workspace,
               target_message_ids: [committed.id],
               target_surface_version: nil,
               expected_prior_approved: nil
             })

    assert {:ok, _} = Settlement.mark_committed_for_test("turn-committed")

    assert {:ok, snapshot} = CustomerFeed.snapshot(ctx.session, ctx.token)
    assert Enum.any?(snapshot.messages, &message_text?(&1, "committed answer"))
    refute Enum.any?(snapshot.messages, &message_text?(&1, "uncommitted answer"))
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end
end

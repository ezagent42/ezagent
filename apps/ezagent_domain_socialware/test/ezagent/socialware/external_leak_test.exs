defmodule Ezagent.Socialware.ExternalLeakTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Message, MessageStore}
  alias Ezagent.Entity.Session
  alias Ezagent.Socialware.{ExternalFeed, Settlement}

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "external-leak-#{System.unique_integer([:positive])}"
    )
  end

  defp sender_uri, do: Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")

  # The external read is now authorized by LIVE membership (anon-user/member),
  # not an identity-less token. A viewer reads as the session owner/member; the
  # boundary assertions (internal never leaks; only committed external) are
  # byte-equivalent — only the AUTH carrier changed from a token to a principal.
  defp owner, do: Ezagent.Socialware.TestCapHelper.owner(:team_alpha, "external-leak-owner")

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

    %{session: session, workspace: workspace, caller: owner()}
  end

  test "internal content never reaches an external route; internal route still sees it", ctx do
    msg =
      Message.new(sender_uri(), %{text: "draft suggestion", attachments: []},
        visibility: :internal
      )

    assert {:ok, _written} = MessageStore.write(msg, ctx.session)

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert {:ok, history} = ExternalFeed.history(ctx.session, ctx.caller)

    refute Enum.any?(snapshot.messages, &message_text?(&1, "draft suggestion"))
    refute Enum.any?(history.messages, &message_text?(&1, "draft suggestion"))

    assert Enum.any?(
             MessageStore.recent_in_session(ctx.session, 10),
             &message_text?(&1, "draft suggestion")
           )
  end

  test "external route returns only committed external-visible messages", ctx do
    committed =
      Message.new(sender_uri(), %{text: "committed answer", attachments: []},
        visibility: :external_visible
      )

    uncommitted =
      Message.new(sender_uri(), %{text: "uncommitted answer", attachments: []},
        visibility: :external_visible
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

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert Enum.any?(snapshot.messages, &message_text?(&1, "committed answer"))
    refute Enum.any?(snapshot.messages, &message_text?(&1, "uncommitted answer"))
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end
end

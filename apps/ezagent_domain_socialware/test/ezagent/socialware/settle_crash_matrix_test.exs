defmodule Ezagent.Socialware.SettleCrashMatrixTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, Message, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.{ExternalFeed, Settlement}

  @owner Ezagent.URI.entity(:team_alpha, :user, "settle-crash-owner")

  defp session_uri do
    Ezagent.URI.session(
      :team_alpha,
      :socialware,
      "crash-matrix-#{System.unique_integer([:positive])}"
    )
  end

  defp sender_uri, do: Ezagent.URI.entity(:team_alpha, :agent, "orchestrator")

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

    %{session: session, workspace: workspace, caller: @owner}
  end

  test "customer never sees chat without its page, or an uncommitted turn", ctx do
    page_tree = %{type: "text", props: %{text: "approved page"}}

    assert {:ok, %{version: version}} =
             dispatch(ctx.session, :surface, :put_version, %{
               turn_id: "turn-crash",
               tree: page_tree
             })

    msg =
      Message.new(sender_uri(), %{text: "answer bubble", attachments: []},
        visibility: :internal
      )

    assert {:ok, msg} = MessageStore.write(msg, ctx.session)

    assert {:ok, _settlement} =
             Settlement.begin(%{
               turn_id: "turn-crash",
               session_uri: ctx.session,
               workspace_uri: ctx.workspace,
               target_message_ids: [msg.id],
               target_surface_version: version,
               expected_prior_approved: nil
             })

    assert {:ok, _settlement} = Settlement.flip_visibility("turn-crash")

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert snapshot.messages == []
    assert snapshot.page == nil

    assert {:ok, %{approved: ^version}} =
             dispatch(ctx.session, :surface, :approve, %{version: version})

    assert {:ok, %{status: :committed}} =
             dispatch(ctx.session, :surface, :commit_settlement, %{turn_id: "turn-crash"})

    assert {:ok, snapshot} = ExternalFeed.snapshot(ctx.session, ctx.caller)
    assert Enum.any?(snapshot.messages, &message_text?(&1, "answer bubble"))
    assert snapshot.page == page_tree
  end

  test "CAS conflict records conflict instead of clobbering a moved pointer", ctx do
    assert {:ok, %{version: first}} =
             dispatch(ctx.session, :surface, :put_version, %{
               turn_id: "turn-other",
               tree: %{type: "text", props: %{text: "already approved"}}
             })

    assert {:ok, %{approved: ^first}} =
             dispatch(ctx.session, :surface, :approve, %{version: first})

    msg =
      Message.new(sender_uri(), %{text: "late answer", attachments: []},
        visibility: :external_visible
      )

    assert {:ok, msg} = MessageStore.write(msg, ctx.session)

    assert {:ok, _settlement} =
             Settlement.begin(%{
               turn_id: "turn-late",
               session_uri: ctx.session,
               workspace_uri: ctx.workspace,
               target_message_ids: [msg.id],
               target_surface_version: first,
               expected_prior_approved: nil
             })

    assert {:error, :approved_pointer_conflict} =
             Settlement.mark_pointer_advanced("turn-late", first)

    assert {:ok, settlement} = Settlement.get("turn-late")
    assert settlement.status == :pending
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
  end
end

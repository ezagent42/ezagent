defmodule EzagentPluginAutoservice.CustomerLiveFeedTest do
  @moduledoc """
  Task 7 — repoint `customer_live` message source to the visibility-gated
  `CustomerFeed` (DD5-b).

  autoservice does NOT depend on `:ezagent_web`, so a full
  `Phoenix.LiveViewTest` mount/render is not available here. The message-loading
  path is therefore extracted into `CustomerLive.load_customer_messages/2`
  (delegating to `CustomerFeed.snapshot/2`) and tested directly: the helper must
  return the customer-visible message but NOT an operator_only draft. The full
  mount/render is verified at the live/web tier.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation
  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginAutoservice.CustomerLive
  alias EzagentPluginAutoservice.SocialwareCSTurnAdapter, as: Adapter

  defp ctx do
    %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  defp target(session_uri, behavior, action) do
    Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=#{behavior}.#{action}")
  end

  defp dispatch(session_uri, behavior, action, args) do
    Invocation.dispatch(%Invocation{
      target: target(session_uri, behavior, action),
      mode: :call,
      args: args,
      ctx: %{
        caller: User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  defp row_text?(row, text), do: row.text == text

  setup do
    session =
      Ezagent.URI.session(
        :team_alpha,
        :cs,
        "cs-feed-#{System.unique_integer([:positive])}"
      )

    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    token = CustomerAuth.issue_token(session, workspace)

    %{session: session, workspace: workspace, token: token}
  end

  describe "load_customer_messages/2 (the customer_live message source)" do
    test "returns customer-visible rows but NOT operator_only drafts", ctx do
      viewer = User.admin_uri()

      # 1) A settled, customer-visible reply via the CS turn adapter.
      assert {:ok, turn} = Adapter.customer_message(ctx.session, "i need help", ctx())
      assert :ok = Adapter.bot_reply(ctx.session, turn, "visible answer", ctx())

      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(ctx.session, ctx.token)
          Enum.any?(snap.messages, &(Map.get(&1.body, "text") == "visible answer"))
        end,
        100
      )

      # 2) An operator_only draft: open + compose, then claim (human handoff)
      #    flips the draft to :operator_only. Without a settle it never becomes
      #    customer-visible, so the customer must NOT see it.
      assert {:ok, %{turn_id: draft_turn}} =
               dispatch(ctx.session, :turn, :open, %{
                 trigger: %{message_id: "draft-trigger"},
                 opened_at: 1
               })

      assert {:ok, %{message_ids: [draft_msg_id]}} =
               dispatch(ctx.session, :turn, :compose, %{
                 turn_id: draft_turn,
                 result_refs: [%{kind: :chat, text: "operator secret draft"}]
               })

      assert {:ok, %{status: :awaiting_human}} =
               dispatch(ctx.session, :turn, :claim, %{
                 turn_id: draft_turn,
                 by: Ezagent.URI.user(:team_alpha, "operator")
               })

      assert {:ok, loaded} = Ezagent.MessageStore.by_id(draft_msg_id)
      assert loaded.visibility == :operator_only

      # The helper is the customer_live source of truth.
      rows = CustomerLive.load_customer_messages(ctx.session, ctx.token, viewer)

      assert Enum.any?(rows, &row_text?(&1, "visible answer")),
             "expected the customer-visible reply in the feed rows"

      refute Enum.any?(rows, &row_text?(&1, "operator secret draft")),
             "operator_only draft must NOT leak into the customer feed rows"
    end

    test "returns [] for an unauthorized token", ctx do
      bad_token = CustomerAuth.issue_token(ctx.session, ctx.workspace, expires_in_ms: -1)

      assert CustomerLive.load_customer_messages(ctx.session, bad_token, User.admin_uri()) == []
    end
  end
end

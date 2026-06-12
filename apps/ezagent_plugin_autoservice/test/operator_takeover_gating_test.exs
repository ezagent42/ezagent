defmodule EzagentPluginAutoservice.OperatorTakeoverGatingTest do
  @moduledoc """
  End-to-end proof that an operator takeover reply is GATED: while the operator
  has only composed + claimed (no settle), the reply is held `:operator_only` and
  does NOT appear in the customer's gated `CustomerFeed`. After settle, it flips
  `:customer_visible` AND its settlement commits, so it NOW appears in the feed.

  This is the no-leak invariant for B-minimal: operator replies reach the
  customer ONLY through the Turn (compose operator_only → settle → committed
  customer_visible → CustomerFeed), never via `chat.send`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, MessageStore}
  alias Ezagent.Entity.SocialwareSession
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed, Settlement}

  @operator_reply "您好，这是人工客服为您处理的回复。"

  # The operator-takeover lifecycle dispatch. We dispatch the Turn actions
  # directly (the same proven pattern as the socialware turn integration tests)
  # because the `system://turn-adapter` principal that `TurnAdapter` uses holds
  # only `cap(:session, Chat, :any)` — it does NOT authorize the Turn behavior's
  # `:open`/`:compose`/`:claim`/`:settle` caps, so `TurnAdapter.*` returns
  # `{:error, :unauthorized}` against a live session. (See the report — this is a
  # real turn-adapter caps gap, orthogonal to the gating fix under test.) The
  # gating semantics proven here are identical regardless of which authority
  # drives the lifecycle.
  defp turn_dispatch(session_uri, action, args) do
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=turn.#{action}"),
      mode: :call,
      args: args,
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: Ezagent.SystemPrincipal.caps("system://bootstrap"),
        reply: {:caller_inbox, self()}
      }
    })
  end

  defp open_turn(session_uri, customer_uri, text) do
    turn_dispatch(session_uri, :open, %{
      trigger: %{msg: text, from: customer_uri},
      opened_at: System.system_time(:second)
    })
  end

  defp compose_turn(session_uri, turn_id, agent_uri, text) do
    turn_dispatch(session_uri, :compose, %{
      turn_id: turn_id,
      result_refs: [%{kind: :chat, agent: agent_uri, text: text}]
    })
  end

  defp claim_turn(session_uri, turn_id, operator_uri) do
    turn_dispatch(session_uri, :claim, %{turn_id: turn_id, by: operator_uri})
  end

  defp settle_turn(session_uri, turn_id) do
    turn_dispatch(session_uri, :settle, %{turn_id: turn_id})
  end

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :socialware, "takeover-#{System.unique_integer([:positive])}")
  end

  defp customer_uri, do: Ezagent.URI.entity(:team_alpha, :user, "cust-#{System.unique_integer([:positive])}")
  defp operator_uri, do: Ezagent.URI.entity(:team_alpha, :user, "op-#{System.unique_integer([:positive])}")

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

  # The gated customer view: only committed + customer_visible messages.
  defp feed_texts(session_uri, token) do
    {:ok, %{messages: messages}} = CustomerFeed.snapshot(session_uri, token)
    Enum.map(messages, fn m -> m.body[:text] || m.body["text"] end)
  end

  test "operator reply is hidden from CustomerFeed until settle (no chat.send leak)" do
    session_uri = session_uri()
    op_uri = operator_uri()
    cust_uri = customer_uri()

    :ok = KindSnapshot.delete(URI.to_string(session_uri))

    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session_uri})
    workspace_uri = Ezagent.Capability.workspace_of(session_uri)
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

    # Mint a real customer feed token (the customer's authority on the feed).
    token = CustomerAuth.issue_token(session_uri, workspace_uri)

    # Sanity: feed is empty before any turn.
    assert feed_texts(session_uri, token) == []

    # --- Operator takeover: open → compose(REAL reply) → claim ---
    assert {:ok, %{turn_id: turn_id}} = open_turn(session_uri, cust_uri, "我需要帮助")

    assert {:ok, _} = compose_turn(session_uri, turn_id, op_uri, @operator_reply)

    assert {:ok, _} = claim_turn(session_uri, turn_id, op_uri)

    # The composed message exists, written for this session...
    [msg | _] =
      session_uri
      |> MessageStore.recent_in_session(50)
      |> Enum.filter(fn m -> (m.body[:text] || m.body["text"]) == @operator_reply end)

    # ...but claim held it operator_only (the hold_visibility step)...
    assert msg.visibility == :operator_only

    # ...and the settlement is not yet committed...
    assert Settlement.get(turn_id) == :error or
             match?({:ok, %{status: s}} when s != :committed, Settlement.get(turn_id))

    # ...so the GATED customer feed does NOT show the operator reply. (no leak)
    refute @operator_reply in feed_texts(session_uri, token)

    # --- Operator settles: reply flips customer_visible + settlement commits ---
    assert {:ok, _} = settle_turn(session_uri, turn_id)

    # settle dispatches approve + commit_settlement as :dispatch_after_commit, so
    # wait for the settlement to reach :committed.
    wait_until(fn ->
      match?({:ok, %{status: :committed}}, Settlement.get(turn_id))
    end)

    # The message is now customer_visible.
    assert {:ok, %{visibility: :customer_visible}} = MessageStore.by_id(msg.id)

    # ...and the GATED customer feed NOW shows the operator reply.
    assert @operator_reply in feed_texts(session_uri, token)
  end
end

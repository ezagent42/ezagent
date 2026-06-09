defmodule EzagentPluginAutoservice.SocialwareCSTurnTest do
  @moduledoc """
  Task 5 — CS turn adapter (DD1).

  Turns a single-bot CS exchange into socialware Turn semantics so the customer
  sees the bot reply through the visibility-gated `CustomerFeed`:

    * a **customer** message → `turn.open` (degenerate turn, no subtasks),
    * the bot reply (coalesced over an idle window W) → `turn.compose` (result_ref
      `%{kind: :chat, text: <reply>}`, turn in `:auto` mode → `:customer_visible`)
      then `turn.settle` → Settlement commits → `CustomerFeed.snapshot/2` returns it.

  The real bot is a live cc agent, unavailable in a unit test. So the adapter's
  CORE is directly callable — the test drives `customer_message/3` then
  `bot_reply/4` synchronously, asserts the feed shows the reply after settle. The
  idle window is exercised separately at W=0 (flush-now) so no real sleep is needed.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginAutoservice.SocialwareCSTurnAdapter, as: Adapter

  defp ctx do
    %{
      caller: User.admin_uri(),
      caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
    }
  end

  defp message_text?(message, text) do
    Map.get(message.body, "text") == text or Map.get(message.body, :text) == text
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

  setup do
    session =
      Ezagent.URI.session(
        :team_alpha,
        :cs,
        "cs-turn-#{System.unique_integer([:positive])}"
      )

    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    token = CustomerAuth.issue_token(session, workspace)

    %{session: session, workspace: workspace, token: token}
  end

  describe "functional core: customer_message/3 -> bot_reply/4" do
    test "customer message then bot reply settles a customer-visible reply", ctx do
      # Before any turn, the customer feed is empty.
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(ctx.session, ctx.token)

      # A customer message opens a degenerate turn.
      assert {:ok, turn} = Adapter.customer_message(ctx.session, "i need help", ctx())
      assert is_binary(turn.turn_id)

      # The bot reply drives compose -> settle and lands customer-visible.
      assert :ok = Adapter.bot_reply(ctx.session, turn, "here is your answer", ctx())

      # Settlement commit is async (turn.settle dispatches commit_settlement);
      # wait for the reply to surface in the customer feed.
      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(ctx.session, ctx.token)
          Enum.any?(snap.messages, &message_text?(&1, "here is your answer"))
        end,
        100
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(ctx.session, ctx.token)
      assert Enum.any?(snapshot.messages, &message_text?(&1, "here is your answer"))
    end
  end

  describe "process: subscribes, classifies sender, coalesces (W=0)" do
    test "customer msg opens turn, bot msgs coalesce + settle to the feed", ctx do
      customer = Ezagent.URI.user(:team_alpha, "cust-#{System.unique_integer([:positive])}")
      bot = Ezagent.URI.agent(:team_alpha, "cs-bot-#{System.unique_integer([:positive])}")

      # W=0 → the adapter flushes on the FIRST bot message (deterministic, no sleep).
      {:ok, _pid} =
        Adapter.start_link(
          session_uri: ctx.session,
          customer_uri: customer,
          ctx: ctx(),
          idle_window_ms: 0
        )

      topic = Ezagent.Behavior.Chat.session_events_topic(ctx.session)

      # Synthetic customer message → turn.open.
      cust_msg = Ezagent.Message.new(customer, %{text: "help me"})
      Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic, {:chat_message, ctx.session, cust_msg})

      # Synthetic bot reply → coalesce (W=0 flush) → compose + settle.
      bot_msg = Ezagent.Message.new(bot, %{text: "the bot answer"})
      Phoenix.PubSub.broadcast(EzagentCore.PubSub, topic, {:chat_message, ctx.session, bot_msg})

      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(ctx.session, ctx.token)
          Enum.any?(snap.messages, &message_text?(&1, "the bot answer"))
        end,
        100
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(ctx.session, ctx.token)
      assert Enum.any?(snapshot.messages, &message_text?(&1, "the bot answer"))
    end
  end
end

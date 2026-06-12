defmodule EzagentPluginAutoservice.TurnDriverTest do
  @moduledoc """
  TurnDriver — functional dispatch tests.

  Each test drives `turn.open` / `turn.compose` / `turn.settle` / `turn.claim`
  on a real SocialwareSession via the sanctioned Invocation path and asserts
  outcomes through `CustomerFeed.snapshot/2` (the same surface the Stage-1
  adapter tests used). No GenServer, no PubSub subscriptions — pure
  function-per-action dispatch.

  Setup mirrors the Stage-1 adapter test:
    - `Ezagent.Kind.spawn(SocialwareSession, %{uri: session})`
    - `Ezagent.WorkspaceRegistry.bind(session, workspace)`
    - `CustomerAuth.issue_token/2` for feed queries
    - Privileged ctx: `%{caller: User.admin_uri(), caps: SystemPrincipal.caps("system://bootstrap")}`
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{SocialwareSession, User}
  alias Ezagent.Socialware.{CustomerAuth, CustomerFeed}
  alias EzagentPluginAutoservice.TurnDriver

  # Privileged turn-driving ctx — mirrors Stage-1 adapter test ctx/0.
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
        "turn-driver-#{System.unique_integer([:positive])}"
      )

    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    token = CustomerAuth.issue_token(session, workspace)

    %{session: session, workspace: workspace, token: token}
  end

  describe "open/3" do
    test "returns {:ok, %{turn_id: id}} on success", ctx do
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "hello"}
      assert {:ok, %{turn_id: turn_id}} = TurnDriver.open(ctx.session, trigger, ctx())
      assert is_binary(turn_id)
      assert String.length(turn_id) > 0
    end
  end

  describe "open/3 -> compose/4 -> settle/3" do
    test "bot reply settles to customer-visible in CustomerFeed", ctx do
      # Feed starts empty.
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(ctx.session, ctx.token)

      # Open a degenerate turn.
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "i need help"}
      assert {:ok, %{turn_id: turn_id}} = TurnDriver.open(ctx.session, trigger, ctx())
      assert is_binary(turn_id)

      # Compose a result_ref — turn moves to :composing.
      assert {:ok, %{status: :composing}} =
               TurnDriver.compose(ctx.session, turn_id, "here is your answer", ctx())

      # Settle — Settlement commits asynchronously → CustomerFeed shows the reply.
      assert {:ok, %{status: :settled}} = TurnDriver.settle(ctx.session, turn_id, ctx())

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

  describe "claim/4" do
    test "claim moves turn to :awaiting_human (operator holds the draft)", ctx do
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "take over"}
      assert {:ok, %{turn_id: turn_id}} = TurnDriver.open(ctx.session, trigger, ctx())

      operator_uri =
        Ezagent.URI.entity(:team_alpha, :user, "operator-#{System.unique_integer([:positive])}")

      # compose first — claim transitions from :composing only.
      assert {:ok, %{status: :composing}} =
               TurnDriver.compose(ctx.session, turn_id, "operator draft", ctx())

      assert {:ok, %{status: :awaiting_human}} =
               TurnDriver.claim(ctx.session, turn_id, operator_uri, ctx())

      # The composed message is held operator_only — customer feed is still empty.
      assert {:ok, %{messages: []}} = CustomerFeed.snapshot(ctx.session, ctx.token)
    end

    test "settle after claim flips draft to customer-visible", ctx do
      trigger = %{message_id: "m-#{System.unique_integer([:positive])}", text: "help"}
      assert {:ok, %{turn_id: turn_id}} = TurnDriver.open(ctx.session, trigger, ctx())

      operator_uri =
        Ezagent.URI.entity(:team_alpha, :user, "op-#{System.unique_integer([:positive])}")

      assert {:ok, %{status: :composing}} =
               TurnDriver.compose(ctx.session, turn_id, "operator reply", ctx())

      assert {:ok, %{status: :awaiting_human}} =
               TurnDriver.claim(ctx.session, turn_id, operator_uri, ctx())

      # Settle — Settlement commits the held draft as customer_visible.
      assert {:ok, %{status: :settled}} = TurnDriver.settle(ctx.session, turn_id, ctx())

      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(ctx.session, ctx.token)
          Enum.any?(snap.messages, &message_text?(&1, "operator reply"))
        end,
        100
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(ctx.session, ctx.token)
      assert Enum.any?(snapshot.messages, &message_text?(&1, "operator reply"))
    end
  end
end

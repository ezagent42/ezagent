defmodule EzagentPluginAutoservice.SocialwareCSTakeoverTest do
  @moduledoc """
  Task 6 — operator takeover (claim -> operator_only -> edit -> settle).

  The CS turn adapter (Task 5) drives a degenerate single-bot turn so the
  customer sees the bot reply through the visibility-gated `CustomerFeed`. Task 6
  adds the *operator takeover* path on the SAME adapter module: an operator can
  step into an open turn, compose their own (edited) reply as the in-flight
  draft, then **claim** it — which moves the turn to `:awaiting_human`, sets mode
  `:copilot`, and **holds visibility** so the draft is `:operator_only` and the
  customer does NOT see it. When the operator **settles**, `Settlement`
  flips visibility to `:customer_visible` and the customer now sees the operator's
  version via `CustomerFeed.snapshot/2`.

  State-machine facts this exercises (see `Ezagent.Behavior.Turn`):

    * `turn.claim` only transitions from `:composing` -> `:awaiting_human` (so the
      operator's reply must be COMPOSED before claim). On claim, `hold_visibility`
      marks the composed `message_ids` `:operator_only`.
    * `turn.settle` transitions `:composing | :awaiting_human` -> `:settled`, drives
      `Settlement.begin/1` + `flip_visibility/1` -> `:customer_visible`, then the
      async commit emits `{:customer_delivery, _}` and the feed shows the reply.

  No live cc agent: the test drives the adapter's functional core directly and
  asserts the `:operator_only` -> `:customer_visible` flip via `CustomerFeed`.
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

  defp operator_uri do
    Ezagent.URI.entity(:team_alpha, :user, "operator-#{System.unique_integer([:positive])}")
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
        "cs-takeover-#{System.unique_integer([:positive])}"
      )

    workspace = Ezagent.Capability.workspace_of(session)
    {:ok, _pid} = Ezagent.Kind.spawn(SocialwareSession, %{uri: session})
    :ok = Ezagent.WorkspaceRegistry.bind(session, workspace)
    token = CustomerAuth.issue_token(session, workspace)

    %{session: session, workspace: workspace, token: token}
  end

  describe "operator takeover: claim -> operator_only -> settle" do
    test "operator claim holds the draft operator-only; settle flips it customer-visible",
         ctx do
      # Customer opens the exchange.
      assert {:ok, turn} = Adapter.customer_message(ctx.session, "i need a human", ctx())
      assert is_binary(turn.turn_id)

      # The operator takes over: composes their edited reply, then claims the turn.
      # claim -> :awaiting_human, mode :copilot, draft held :operator_only.
      assert {:ok, claimed} =
               Adapter.operator_claim(
                 ctx.session,
                 turn,
                 "let me personally help you with that",
                 operator_uri(),
                 ctx()
               )

      assert claimed.turn_id == turn.turn_id

      # While awaiting human, the operator's draft must NOT be visible to the
      # customer (operator_only).
      assert {:ok, held} = CustomerFeed.snapshot(ctx.session, ctx.token)

      refute Enum.any?(
               held.messages,
               &message_text?(&1, "let me personally help you with that")
             )

      # The operator settles -> visibility flips to :customer_visible.
      assert :ok = Adapter.operator_settle(ctx.session, claimed, ctx())

      # Settlement commit is async; wait for the operator's reply to surface.
      wait_until(
        fn ->
          {:ok, snap} = CustomerFeed.snapshot(ctx.session, ctx.token)
          Enum.any?(snap.messages, &message_text?(&1, "let me personally help you with that"))
        end,
        100
      )

      assert {:ok, snapshot} = CustomerFeed.snapshot(ctx.session, ctx.token)

      assert Enum.any?(
               snapshot.messages,
               &message_text?(&1, "let me personally help you with that")
             )
    end
  end
end

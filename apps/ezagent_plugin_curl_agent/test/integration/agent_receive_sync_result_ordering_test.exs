defmodule EzagentPluginCurlAgent.Integration.AgentReceiveSyncResultOrderingTest do
  @moduledoc """
  codex round-2 P2 — DOCUMENTED known-limitation for the `:in_process_sync`
  `:sync_result` ordering edge (the curl fold's async-persist seam).

  ## The concurrency edge this pins

  `agent.receive` (`Ezagent.ActionSet.Agent.Receive`) runs the curl HTTP
  round-trip SYNCHRONOUSLY but persists the conversation via a SEPARATE
  re-dispatched `:sync_result` `:cast`. That `:cast` is a post-commit DEFERRED
  dispatch (`Kind.DeferredDispatch` → `send(self(), {:ezagent_run_deferred, …})`),
  so it lands at the BACK of the agent's mailbox. If two `:receive` casts are
  queued for the SAME curl agent, the persist for message#1 sits BEHIND
  message#2 — so message#2's adapter assembles its prompt from a conversation
  snapshot that does NOT yet include message#1's turns.

  This file is the DOCUMENTED known-limitation per the PR-6 round-2 DEFER VALVE.
  It (1) exhibits the STRUCTURAL root deterministically and (2) carries a
  `@tag :known_limitation` reproduction of the stale-snapshot read. The
  synchronous-ordering fix is blocked by the single-slice commit model
  (`agent.receive` owns `:session`; the conversation lives in `:curl_agent`),
  documented in `Ezagent.ActionSet.Agent.Receive`'s "KNOWN LIMITATION" moduledoc
  section with the three redesign options. When a follow-up lands one of those,
  the `@tag :known_limitation` reproduction flips to a passing invariant.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Kind, KindRegistry, SnapshotStore}
  alias Ezagent.ActionSet.Agent.Receive, as: AgentReceive
  alias EzagentPluginCurlAgent.BridgeAdapter
  alias Ezagent.AgentBridge.Payload
  alias Ezagent.Message

  # A2.2 — supply the runtime-preloaded member-cap the handler authorizes against
  # (see curl_flavor_on_agent_test.exs for the full rationale). Behavior axis is
  # `:any` (MemberReceive matches kind/action/instance/provenance only).
  defp with_member_cap(ctx) do
    caller = Map.fetch!(ctx, :caller)
    holder = Map.fetch!(ctx, :self_uri)

    cap =
      Ezagent.Test.CapHelper.signed_fixture_cap!(
        caller,
        :session,
        :any,
        :receive,
        holder
      )

    Map.put(ctx, :siblings, %{identity: %{caps: MapSet.new([cap])}})
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp spawn_curl_agent(tag) do
    uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/curl_#{tag}-#{System.unique_integer([:positive])}"
      )

    {:ok, _pid} =
      Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: Ezagent.Entity.Agent.curl_behaviors(),
        provider: "deepseek"
      })

    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)
    :ok = Ezagent.AgentFlavorAttributes.put(uri, "curl")
    on_exit(fn -> Ezagent.AgentFlavorAttributes.delete(uri) end)
    uri
  end

  # The adapter's request assembly is purely snapshot-driven. Drive `deliver/2`
  # the way `agent.receive` → `AgentBridge.deliver` does and read back the
  # conversation it WOULD send (the no-key path short-circuits, so we assert on
  # the SNAPSHOT the adapter reads rather than on a captured HTTP body — the
  # snapshot IS the input that determines the prompt).
  defp adapter_sees_conversation(uri) do
    case SnapshotStore.latest(uri) do
      {:ok, %{state: %{curl_agent: %{conversation: conv}}}} -> conv
      _ -> []
    end
  end

  describe "STRUCTURAL root — agent.receive cannot persist :curl_agent in its own dispatch" do
    test "agent.receive pins :session, NOT :curl_agent (so it can't {:set, :conversation, …})" do
      # The conversation slice is owned by Behavior.CurlAgent (:curl_agent).
      # agent.receive is flavor-blind and pins :session — the runtime commits
      # ONLY the dispatched behavior's own slice, so agent.receive can never
      # emit a {:set, :conversation, …} into :curl_agent within its own cycle.
      # This is the precise blocker for a same-dispatch synchronous persist.
      assert AgentReceive.state_slice() == :session
      assert Ezagent.ActionSet.CurlAgent.state_slice() == :curl_agent
      refute AgentReceive.state_slice() == Ezagent.ActionSet.CurlAgent.state_slice()
    end

    test "the curl :in_process_sync persist is an ASYNC re-dispatched :sync_result :cast" do
      uri = spawn_curl_agent("structroot")
      session_uri = Ezagent.URI.new!("session://team-alpha/default/main")
      sender = Ezagent.URI.new!("entity://team-alpha/user/alice")

      msg = Message.new(sender, %{text: "first", attachments: []})

      ctx =
        with_member_cap(%{self_uri: uri, kind_module: Ezagent.Entity.Agent, caller: session_uri})

      assert {:ok, %{}, effects} = AgentReceive.handle_receive(%{message: msg}, ctx)

      # The persist is NOT a {:set, …} in THIS dispatch — it is a separate
      # {:dispatch, %Cmd{action: :sync_result}} (which becomes a deferred
      # post-commit :cast). That async hop is the ordering hazard.
      refute Enum.any?(effects, &match?({:set, :conversation, _}, &1))
      assert [{:dispatch, cmd}] = Enum.filter(effects, &match?({:dispatch, _}, &1))
      assert cmd.action == :sync_result

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end
  end

  describe "the stale-snapshot read (the observable consequence)" do
    @tag :known_limitation
    test "a 2nd receive whose persist#1 has not committed assembles from a STALE conversation" do
      uri = spawn_curl_agent("staleread")
      sender = Ezagent.URI.new!("entity://team-alpha/user/alice")

      # State the snapshot at "message#1 received, persist#1 STILL PENDING in the
      # mailbox" — i.e. the conversation has NOT yet gained message#1's turns.
      # This is exactly the window where message#2's adapter assembly runs.
      stale_conv = adapter_sees_conversation(uri)

      assert stale_conv == [],
             "precondition: a fresh curl agent starts with an empty conversation"

      # message#2's adapter assembly reads the snapshot. Because persist#1 is
      # still queued behind this receive, the adapter sees the EMPTY conversation
      # — message#1's user + assistant turns are INVISIBLE to prompt#2.
      payload = %Payload{
        message_id: "msg-2",
        session_uri: Ezagent.URI.new!("session://team-alpha/default/main"),
        sender_uri: sender,
        text: "second",
        event_type: :chat_send,
        meta: %{"agent_uri" => URI.to_string(uri)}
      }

      # No api key seeded → deliver short-circuits before HTTP, but it has
      # ALREADY assembled `request_conv` from the (stale) snapshot conversation.
      assert {:error, {:no_api_key, "deepseek"}} = BridgeAdapter.deliver(payload, nil)

      # The CORE assertion of the limitation: the conversation the adapter read
      # for message#2 still excludes message#1's turns. A synchronous-ordering
      # fix (persist#1 committed before message#2 assembles) would make this
      # list non-empty. With the async seam it is stale (empty) — DOCUMENTED.
      assert adapter_sees_conversation(uri) == [],
             "known limitation: message#2 assembles from a conversation snapshot " <>
               "that does not yet include message#1's not-yet-committed turns"

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end
  end
end

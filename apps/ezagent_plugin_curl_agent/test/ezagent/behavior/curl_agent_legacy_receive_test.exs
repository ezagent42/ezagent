defmodule Ezagent.Behavior.CurlAgentLegacyReceiveTest do
  @moduledoc """
  codex P1 (PR-6) — a PRE-migration `Ezagent.Entity.CurlAgent` snapshot must
  still respond to `:receive` through the rollback window.

  PR-6 dropped `:receive` from `Ezagent.Behavior.CurlAgent` (NEW curl agents
  receive via `agent.receive` → the `:in_process_sync` adapter). But existing
  `curl_agent` snapshots still resolve to `Entity.CurlAgent`, and session
  delivery dispatches inbound chat as action `:receive`. Without a `:receive`
  binding on the legacy Kind, such an agent would hit
  `{:unknown_action, :receive}` and go mute.

  These tests FAIL if the legacy `:receive` regresses: if the registry stops
  routing `{Entity.CurlAgent, :receive}`, or if a live legacy agent can no
  longer process an inbound message (the durable `:curl_agent` slice mutation
  the old inline-completion `:receive` produced).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Kind, KindRegistry, Message}
  alias Ezagent.Behavior.CurlAgentLegacyReceive

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

  describe "registry routing (legacy Kind only)" do
    test "{Entity.CurlAgent, :receive} → CurlAgentLegacyReceive" do
      assert {:ok, CurlAgentLegacyReceive} =
               Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.CurlAgent, :receive)
    end

    test ":receive is NOT bound on the unified Entity.Agent via the legacy module" do
      # The unified Agent Kind receives via `agent.receive` (Behavior.Agent.Receive),
      # NOT the legacy curl module — no double-registration.
      assert {:ok, mod} = Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :receive)
      refute mod == CurlAgentLegacyReceive
    end
  end

  describe "a live legacy Entity.CurlAgent still responds to :receive" do
    test "an inbound :receive is handled (not :unknown_action) and mutates the durable slice" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_legacyrecv-#{System.unique_integer([:positive])}"
        )

      sender = Ezagent.URI.new!("entity://team-alpha/user/alice")

      {:ok, _pid} =
        Kind.spawn(Ezagent.Entity.CurlAgent, %{uri: uri, provider: "deepseek"})

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # No api key seeded → the inline-completion path short-circuits on the
      # no-key branch WITHOUT a network call, appends the user turn, and sets
      # last_error. This proves :receive is routed + handled end-to-end.
      msg = Message.new(sender, %{text: "hello legacy curl", attachments: []})
      target = Ezagent.URI.with_action(uri, :curl_agent, :receive)

      # :receive is a :cast — dispatch and then observe the durable mutation.
      # `caller: :system` is the trusted bootstrap principal (default_holds_cap?
      # → true), mirroring the production chat-router delivery's authority for
      # this internal :receive dispatch. The no-key branch short-circuits before
      # any reply, so the system caller is sufficient to prove :receive routes
      # + mutates the durable slice (the point of this regression).
      :ok =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: target,
          mode: :cast,
          args: %{message: msg},
          ctx: %{caller: :system, caps: :system, reply: :ignore}
        })

      # The slice gets the user turn + the no-key error — proof the legacy
      # handler ran (a {:unknown_action, :receive} would leave it untouched).
      wait_until(fn ->
        case Kind.get_slice(uri, :curl_agent) do
          {:ok, %{last_error: {:no_api_key, "deepseek"}}} -> true
          _ -> false
        end
      end)

      assert {:ok, slice} = Kind.get_slice(uri, :curl_agent)
      assert slice.last_error == {:no_api_key, "deepseek"}
      assert slice.conversation == [%{role: "user", content: "hello legacy curl"}]

      Kind.terminate(uri)
      wait_until(fn -> KindRegistry.lookup(URI.to_string(uri)) == :error end)
    end

    test "a self-message is ignored (loop guard preserved from pre-fold)" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/curl_legacyself-#{System.unique_integer([:positive])}"
        )

      ctx = %{self_uri: uri, caller: uri, read: fn _k, d -> d end, siblings: %{}}
      self_msg = Message.new(uri, %{text: "my own reply", attachments: []})

      assert {:ok, %{ignored: :self_message}, []} =
               CurlAgentLegacyReceive.handle_receive(%{message: self_msg}, ctx)
    end
  end

  describe "contract surface" do
    test "owns ONLY the :receive action on the legacy :curl_agent slice" do
      assert CurlAgentLegacyReceive.actions() == [:receive]
      assert CurlAgentLegacyReceive.state_slice() == :curl_agent
      assert CurlAgentLegacyReceive.reads_siblings() == [:api_keys]
    end
  end
end

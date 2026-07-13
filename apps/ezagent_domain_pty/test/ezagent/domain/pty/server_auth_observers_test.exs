defmodule Ezagent.Domain.Pty.Server.AuthObserversTest do
  @moduledoc """
  #17 PR-C — the PTY auth-failure OBSERVERS: emit-only (telemetry + `auth_failed_topic`
  broadcast), never send to stdin, fire-once per signal. Surfaces an expired/missing
  login instead of a silent mute.
  """
  use ExUnit.Case, async: false

  alias Ezagent.AnsiStrip
  alias Ezagent.Domain.Pty.Server, as: PtyServer

  defp agent_uri,
    do:
      Ezagent.URI.new!(
        "entity://team-alpha/agent/cc_authobs-#{System.unique_integer([:positive])}"
      )

  test "matches? catches a real claude 403 / login-needed buffer" do
    buf = AnsiStrip.strip("\e[1CAPI Error: 403\r\r\nPlease run /login to continue")
    assert PtyServer.matches?("API Error: 403", buf)
    assert PtyServer.matches?(~r/Please run \/login/, buf)
  end

  test "an auth_observer match broadcasts {:pty_auth_failed, …} once (emit-only, fire-once)" do
    uri = agent_uri()
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.auth_failed_topic(uri))

    {:ok, pid} =
      PtyServer.start_link(%{
        agent_uri: uri,
        test_mode: true,
        auth_observers: [%{name: :test_403, match: "API Error: 403"}]
      })

    # feed a chunk carrying the auth-failure signal
    send(pid, {:stdout, 12_345, "some output\nAPI Error: 403\nmore"})
    assert_receive {:pty_auth_failed, ^uri, :test_403}, 1_000

    # fire-once: a second matching chunk must NOT re-broadcast
    send(pid, {:stdout, 12_345, "again API Error: 403 again"})
    refute_receive {:pty_auth_failed, ^uri, :test_403}, 300

    GenServer.stop(pid)
  end

  test "no auth_observers → no broadcast on a 403 chunk" do
    uri = agent_uri()
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.auth_failed_topic(uri))

    {:ok, pid} = PtyServer.start_link(%{agent_uri: uri, test_mode: true})
    send(pid, {:stdout, 1, "API Error: 403"})
    refute_receive {:pty_auth_failed, ^uri, _}, 300

    GenServer.stop(pid)
  end
end

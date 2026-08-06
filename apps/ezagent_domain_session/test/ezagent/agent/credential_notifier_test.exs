defmodule Ezagent.Agent.CredentialNotifierTest do
  @moduledoc """
  #17 PR-C2 — a PTY auth-failure signal becomes an owner notification with a clickable
  terminal URL (no silent mute). The notifier is supervised in the app; this drives the
  shared `pty:auth_failed` topic and asserts the owner's notification stream.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Ezagent.Agent.CredentialNotifier
  alias Ezagent.Domain.Pty.Server, as: PtyServer

  defp agent_uri,
    do:
      Ezagent.URI.new!(
        "entity://team-alpha/agent/cc_crednotif-#{System.unique_integer([:positive])}"
      )

  describe "terminal_url/1 (D2)" do
    test "builds the deployment-host Phoenix terminal route with a URL-encoded agent URI" do
      uri = Ezagent.URI.new!("entity://team-alpha/agent/cc_foo")
      url = CredentialNotifier.terminal_url(uri)

      assert url =~ ~r{^https://[^/]+/identities/agents/.+/terminal$}
      # the agent URI is URL-encoded into the path segment
      assert url =~ URI.encode_www_form("entity://team-alpha/agent/cc_foo")
      # default deployment host when EZAGENT_PUBLIC_HOST is unset
      assert url =~ System.get_env("EZAGENT_PUBLIC_HOST", "app.ezagent.chat")
    end

    test "honors EZAGENT_PUBLIC_SCHEME / _HOST / _PORT (dev/Tailscale http+port) — codex P2" do
      prev =
        {System.get_env("EZAGENT_PUBLIC_SCHEME"), System.get_env("EZAGENT_PUBLIC_HOST"),
         System.get_env("EZAGENT_PUBLIC_PORT")}

      System.put_env("EZAGENT_PUBLIC_SCHEME", "http")
      System.put_env("EZAGENT_PUBLIC_HOST", "100.64.0.27")
      System.put_env("EZAGENT_PUBLIC_PORT", "10042")

      on_exit(fn ->
        {s, h, p} = prev

        for {k, v} <- [
              {"EZAGENT_PUBLIC_SCHEME", s},
              {"EZAGENT_PUBLIC_HOST", h},
              {"EZAGENT_PUBLIC_PORT", p}
            ] do
          if v, do: System.put_env(k, v), else: System.delete_env(k)
        end
      end)

      url = CredentialNotifier.terminal_url(Ezagent.URI.new!("entity://team-alpha/agent/cc_foo"))
      assert String.starts_with?(url, "http://100.64.0.27:10042/identities/agents/")
    end
  end

  describe "build_notification/2" do
    test "carries the type, agent URI, and the clickable terminal URL" do
      uri = agent_uri()
      n = CredentialNotifier.build_notification(uri, :cc_auth_failure_0)

      assert n.type == :agent_auth_failed
      assert n.source == CredentialNotifier
      assert n.body.agent_uri == uri
      assert n.body.terminal_url == CredentialNotifier.terminal_url(uri)
      assert n.body.text =~ "/login"
    end
  end

  describe "wiring: shared topic → owner notification" do
    test "an auth-failure for an agent notifies its owner (creator) to re-/login" do
      uri = agent_uri()
      owner = Ezagent.Entity.User.admin_uri()

      # data_owner resolves via AgentLineage (ETS) when the api_keys slice is absent —
      # record the agent's creator without needing a live Agent Kind or the DB.
      :ets.insert(Ezagent.AgentLineage.table(), {URI.to_string(uri), URI.to_string(owner)})

      :ok = Ezagent.Notifications.subscribe(owner)

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        PtyServer.auth_failed_all_topic(),
        {:pty_auth_failed, uri, :cc_auth_failure_0}
      )

      assert_receive {:notification, ^owner, %{type: :agent_auth_failed, body: body}}, 2_000
      assert body.agent_uri == uri
      assert body.terminal_url =~ "/terminal"
    end

    test "resolves a non-user lineage owner up the creation chain to the human user (codex P2)" do
      # worker agent whose lineage owner is the ORCHESTRATOR (an agent), whose owner is
      # the human admin. Notifications only accepts users → must walk to admin.
      worker = agent_uri()

      orch =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/cc_orch-#{System.unique_integer([:positive])}"
        )

      owner = Ezagent.Entity.User.admin_uri()

      :ets.insert(Ezagent.AgentLineage.table(), {URI.to_string(worker), URI.to_string(orch)})
      :ets.insert(Ezagent.AgentLineage.table(), {URI.to_string(orch), URI.to_string(owner)})

      :ok = Ezagent.Notifications.subscribe(owner)

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        PtyServer.auth_failed_all_topic(),
        {:pty_auth_failed, worker, :cc_auth_failure_0}
      )

      assert_receive {:notification, ^owner,
                      %{type: :agent_auth_failed, body: %{agent_uri: ^worker}}},
                     2_000
    end
  end

  describe "joined admission reconciliation" do
    test "reconciles the failed agent before continuing notification handling" do
      test_pid = self()

      {:ok, notifier} =
        start_supervised(
          {CredentialNotifier,
           name: nil,
           reconcile_fun: fn agent_uri ->
             send(test_pid, {:admission_reconciled, agent_uri})
             :ok
           end}
        )

      uri = agent_uri()
      send(notifier, {:pty_auth_failed, uri, :cc_auth_failure_0})

      assert_receive {:admission_reconciled, ^uri}, 1_000
      assert Process.alive?(notifier)
    end

    test "logs reconciliation failures without crashing the notifier" do
      test_pid = self()
      reason = {:forced_reconciliation_failure, System.unique_integer([:positive])}

      {:ok, notifier} =
        start_supervised(
          {CredentialNotifier,
           name: nil,
           reconcile_fun: fn agent_uri ->
             send(test_pid, {:reconciliation_attempted, agent_uri})
             {:error, reason}
           end}
        )

      uri = agent_uri()

      log =
        capture_log(fn ->
          send(notifier, {:pty_auth_failed, uri, :cc_auth_failure_0})
          assert_receive {:reconciliation_attempted, ^uri}, 1_000
          Process.sleep(20)
        end)

      assert log =~ "admission reconciliation"
      assert log =~ inspect(reason)
      assert Process.alive?(notifier)
    end
  end
end

defmodule Ezagent.Agent.CredentialNotifierTest do
  @moduledoc """
  #17 PR-C2 — a PTY auth-failure signal becomes an owner notification with a clickable
  terminal URL (no silent mute). The notifier is supervised in the app; this drives the
  shared `pty:auth_failed` topic and asserts the owner's notification stream.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Agent.CredentialNotifier
  alias Ezagent.Domain.Pty.Server, as: PtyServer

  defp agent_uri, do: Ezagent.URI.new!("entity://agent/team-alpha/cc_crednotif-#{System.unique_integer([:positive])}")

  describe "terminal_url/1 (D2)" do
    test "builds the deployment-host Phoenix terminal route with a URL-encoded agent URI" do
      uri = Ezagent.URI.new!("entity://agent/team-alpha/cc_foo")
      url = CredentialNotifier.terminal_url(uri)

      assert url =~ ~r{^https://[^/]+/identities/agents/.+/terminal$}
      # the agent URI is URL-encoded into the path segment
      assert url =~ URI.encode_www_form("entity://agent/team-alpha/cc_foo")
      # default deployment host when EZAGENT_PUBLIC_HOST is unset
      assert url =~ System.get_env("EZAGENT_PUBLIC_HOST", "app.ezagent.chat")
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

      :ok = Ezagent.Notifications.subscribe(owner, %{caps: :system})

      Phoenix.PubSub.broadcast(
        EzagentCore.PubSub,
        PtyServer.auth_failed_all_topic(),
        {:pty_auth_failed, uri, :cc_auth_failure_0}
      )

      assert_receive {:notification, ^owner, %{type: :agent_auth_failed, body: body}}, 2_000
      assert body.agent_uri == uri
      assert body.terminal_url =~ "/terminal"
    end
  end
end
